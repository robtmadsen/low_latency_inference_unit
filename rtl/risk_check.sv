// risk_check.sv — Pre-trade risk enforcement, 2-cycle registered output
//
// Three parallel risk checks (spec §4.6) resolved in a 2-stage pipeline:
//
//   Stage 0 → 1 (posedge 1):
//     • Price-band comparison done combinatorially, result registered.
//     • Fat-finger comparison done combinatorially (proposed_shares > max_qty
//       AXI4-Lite register, no BRAM needed — matches AXI4-Lite map 0x404).
//     • Position BRAM read address driven; data arrives at posedge 1.
//
//   Stage 1 → 2 (posedge 2):
//     • Position-limit check done combinatorially from BRAM read data.
//     • All three check results AND'd; risk_pass / risk_blocked registered.
//
// Kill switch and tx_overflow are registered into stage-1 pipeline and act
// as hard gates on pass_c1 (suppress risk_pass without a reason code).
//
// Position BRAM (512 × 24-bit signed, infers one RAMB18E1):
//   Stores cumulative net_shares per symbol.  Updated 1 cycle after risk_pass
//   via pos_wr_* writeback registers.
//
//   Writeback hazard: a read for symbol S at cycle N sees the write for
//   symbol S at cycle N only if that write completed ≥1 cycle earlier.
//   Back-to-back orders for the same symbol within 2 cycles will observe
//   stale position data.  Acceptable at 1 unique-symbol message/cycle.
//
// block_reason encoding:
//   2'b00 = no block (or kill_sw / tx_overflow — no reason code assigned)
//   2'b01 = price-band violation
//   2'b10 = fat-finger violation
//   2'b11 = position-limit violation

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module risk_check (
    input  logic        clk,
    input  logic        rst,

    // From strategy_arbiter
    input  logic        score_valid,
    input  logic        side,              // 1 = buy, 0 = sell
    input  logic [31:0] price,
    input  logic [8:0]  symbol_id,         // 0–499; indexes position BRAM
    input  logic [23:0] proposed_shares,   // share quantity to propose

    // TX backpressure auto-kill from ouch_engine (combinational, registered into p1)
    input  logic        tx_overflow,

    // AXI4-Lite configurable thresholds (held stable between AXI writes)
    input  logic [31:0] band_bps,          // price-band width in basis points
    input  logic [31:0] max_qty,           // fat-finger global ceiling (AXI 0x404)
    input  logic [23:0] pos_limit,         // per-symbol net-position ceiling (unsigned shares)
    input  logic        kill_sw,           // write-one-to-set; AXI4-Lite CTRL[2]

    // Reference price (BBO mid, registered 1-cycle externally)
    input  logic [31:0] ref_price,

    // Risk outputs — valid 2 cycles after score_valid
    output logic        risk_pass,
    output logic        risk_blocked,
    output logic [1:0]  block_reason
);

    // ------------------------------------------------------------------
    // Stage-0 combinational: price-band and fat-finger checks
    // ------------------------------------------------------------------
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] band_product;  // bits [63:45] and [12:0] intentionally unused
    /* verilator lint_on UNUSEDSIGNAL */
    logic [31:0] band_thresh;
    logic [31:0] price_diff;
    logic        block_band_c0;
    logic        block_fat_c0;

    always_comb begin
        // Price-band: threshold ≈ ref_price × band_bps / 10000 (>> 13, err < 2.4%)
        band_product  = {32'h0, ref_price} * {32'h0, band_bps};
        band_thresh   = band_product[44:13];
        price_diff    = (price >= ref_price) ? (price - ref_price)
                                             : (ref_price - price);
        block_band_c0 = score_valid && (price_diff > band_thresh);

        // Fat-finger: proposed_shares vs global AXI4-Lite max_qty register
        block_fat_c0  = score_valid && ({8'h0, proposed_shares} > max_qty);
    end

    // ------------------------------------------------------------------
    // Stage-0 → Stage-1 pipeline registers
    // ------------------------------------------------------------------
    logic        score_valid_p1;
    logic        side_p1;
    logic [8:0]  symbol_id_p1;
    logic [23:0] proposed_shares_p1;
    logic        block_band_p1;
    logic        block_fat_p1;
    logic        kill_sw_p1;
    logic        tx_overflow_p1;

    always_ff @(posedge clk) begin
        if (rst) begin
            score_valid_p1     <= 1'b0;
            side_p1            <= 1'b0;
            symbol_id_p1       <= '0;
            proposed_shares_p1 <= '0;
            block_band_p1      <= 1'b0;
            block_fat_p1       <= 1'b0;
            kill_sw_p1         <= 1'b0;
            tx_overflow_p1     <= 1'b0;
        end else begin
            score_valid_p1     <= score_valid;
            side_p1            <= side;
            symbol_id_p1       <= symbol_id;
            proposed_shares_p1 <= proposed_shares;
            block_band_p1      <= block_band_c0;
            block_fat_p1       <= block_fat_c0;
            kill_sw_p1         <= kill_sw;
            tx_overflow_p1     <= tx_overflow;
        end
    end

    // ------------------------------------------------------------------
    // Position BRAM (512 × 24-bit signed, infers RAMB18E1)
    // Read address = symbol_id (cycle 0); rd_data valid at cycle 1.
    // Write port driven by writeback register (1 cycle after risk_pass).
    // ------------------------------------------------------------------
    (* ram_style = "block" *) logic signed [23:0] pos_mem [0:511];
    logic signed [23:0] pos_rd_data;
    logic               pos_wr_en_r;
    logic [8:0]         pos_wr_addr_r;
    logic signed [23:0] pos_wr_data_r;

    always_ff @(posedge clk) begin
        if (pos_wr_en_r)
            pos_mem[pos_wr_addr_r] <= pos_wr_data_r;
        pos_rd_data <= pos_mem[symbol_id];
    end

    // ------------------------------------------------------------------
    // Stage-1 combinational: position-limit check; priority encoder
    // ------------------------------------------------------------------
    logic        block_pos_c1;
    logic        pass_c1;
    logic [1:0]  reason_c1;
    logic signed [24:0] new_net;
    logic [23:0]        new_net_abs;

    always_comb begin
        // New net position after proposed order
        if (side_p1)
            new_net = {pos_rd_data[23], pos_rd_data} + {1'b0, proposed_shares_p1};
        else
            new_net = {pos_rd_data[23], pos_rd_data} - {1'b0, proposed_shares_p1};

        // |new_net| via two's-complement negation of lower 24 bits
        new_net_abs  = new_net[24] ? (~new_net[23:0] + 24'd1) : new_net[23:0];
        block_pos_c1 = score_valid_p1 && (new_net_abs > pos_limit);

        // Priority: kill_sw / tx_overflow > price_band > fat_finger > pos_limit
        if (!score_valid_p1) begin
            pass_c1   = 1'b0;
            reason_c1 = 2'b00;
        end else if (kill_sw_p1 || tx_overflow_p1) begin
            pass_c1   = 1'b0;
            reason_c1 = 2'b00;
        end else if (block_band_p1) begin
            pass_c1   = 1'b0;
            reason_c1 = 2'b01;
        end else if (block_fat_p1) begin
            pass_c1   = 1'b0;
            reason_c1 = 2'b10;
        end else if (block_pos_c1) begin
            pass_c1   = 1'b0;
            reason_c1 = 2'b11;
        end else begin
            pass_c1   = 1'b1;
            reason_c1 = 2'b00;
        end
    end

    // ------------------------------------------------------------------
    // Stage-2 output register (cycle 2)
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            risk_pass    <= 1'b0;
            risk_blocked <= 1'b0;
            block_reason <= 2'b00;
        end else begin
            risk_pass    <= pass_c1;
            risk_blocked <= score_valid_p1 && !pass_c1;
            block_reason <= reason_c1;
        end
    end

    // ------------------------------------------------------------------
    // Position writeback: registered 1 cycle after risk_pass assertion
    // Uses new_net computed in stage-1 always_comb above.
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            pos_wr_en_r   <= 1'b0;
            pos_wr_addr_r <= '0;
            pos_wr_data_r <= '0;
        end else begin
            pos_wr_en_r   <= pass_c1;
            pos_wr_addr_r <= symbol_id_p1;
            pos_wr_data_r <= new_net[23:0];
        end
    end

endmodule
