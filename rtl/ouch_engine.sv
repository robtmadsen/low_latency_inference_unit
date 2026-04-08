// ouch_engine.sv — OUCH 5.0 Enter Order packet assembler with BRAM template buffer
//
// Template buffer: 4 × 128-entry × 64-bit block RAMs (RAMB18E1 × 4), one per
// static beat slot (beats 2-5).  Per-symbol values (stock name, side indicator,
// firm, display, TIF) are stored in the BRAMs and initialised via AXI4-Lite.
// Hot-patched fields per order: order_token (auto-increment), shares, price.
//
// Template BRAM layout (per 64-bit entry, indexed by symbol_id):
//   tmpl_b2[sym]: bits[31:0] = stock[63:32] (stock name bytes 0-3)
//                 bits[63:32] = placeholder (overwritten by shares at send time)
//   tmpl_b3[sym]: bits[63:32] = stock[31:0] (stock name bytes 4-7)
//                 bits[31:0]  = placeholder (overwritten by price at send time)
//   tmpl_b4[sym]: {TIF[31:0], firm[63:32]}   — time-in-force + firm name bytes 0-3
//   tmpl_b5[sym]: {firm[31:0], display[7:0], reserved[23:0]}
//
// AXI4-Lite write address decode:
//   tmpl_wr_addr[8:2] = symbol_id (0-127)
//   tmpl_wr_addr[1:0] = beat_offset: 0=beat2, 1=beat3, 2=beat4, 3=beat5
//
// FSM: IDLE → FETCH → LOAD → SEND → IDLE
//   IDLE  : wait for risk_pass; latch per-order inputs; → FETCH
//   FETCH : 1-cycle hold; BRAM read (issued from latch_sym_id) completes; → LOAD
//   LOAD  : assemble all 6 beats; output beat 0 on AXI4-S; → SEND
//   SEND  : stream beats 1-5 with backpressure handling
//
// tx_overflow:
//   Asserts after 64 consecutive stalled cycles (m_axis_tready=0 during SEND).
//   Self-clears after 256 consecutive free cycles (m_axis_tready=1).

`default_nettype none

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module ouch_engine (
    input  logic        clk,
    input  logic        rst,

    // From risk_check (carries validated order)
    input  logic        risk_pass,
    input  logic        side,              // 1 = buy, 0 = sell
    input  logic [31:0] price,
    input  logic [6:0]  symbol_id,         // 0-127; indexes template BRAMs
    input  logic [23:0] proposed_shares,   // share quantity (from risk_check)
    /* verilator lint_off UNUSED */
    input  logic [63:0] timestamp,         // PTP tap — reserved, not in OUCH packet
    /* verilator lint_on UNUSED */

    // Template BRAM write port (AXI4-Lite accessible)
    input  logic [8:0]  tmpl_wr_addr,      // [8:2]=symbol_id, [1:0]=beat_offset
    input  logic [63:0] tmpl_wr_data,
    input  logic        tmpl_wr_en,

    // AXI4-Stream master (to 10GbE TX MAC)
    output logic [63:0] m_axis_tdata,
    output logic [7:0]  m_axis_tkeep,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready,

    // Back-pressure watchdog output (→ risk_check auto-kill)
    output logic        tx_overflow
);

    // ------------------------------------------------------------------
    // Packet constants
    // ------------------------------------------------------------------
    localparam logic [7:0] MSG_TYPE  = 8'h4F;           // 'O'
    localparam logic [7:0] SIDE_BUY  = OUCH_SIDE_BUY;
    localparam logic [7:0] SIDE_SELL = OUCH_SIDE_SELL;

    // ------------------------------------------------------------------
    // Template BRAMs (4 × 128-entry × 64-bit, infer RAMB18E1 each)
    // ------------------------------------------------------------------
    (* ram_style = "block" *) logic [31:0] tmpl_b2 [0:127]; // stock name bytes 0-3
    (* ram_style = "block" *) logic [31:0] tmpl_b3 [0:127]; // stock name bytes 4-7
    (* ram_style = "block" *) logic [63:0] tmpl_b4 [0:127]; // {TIF, firm_high}
    (* ram_style = "block" *) logic [63:0] tmpl_b5 [0:127]; // {firm_low, display, rsvd}

    logic [31:0] tmpl_rd_b2, tmpl_rd_b3;
    logic [63:0] tmpl_rd_b4, tmpl_rd_b5;
    logic [6:0]  latch_sym_id;   // registered from symbol_id at S_IDLE

    // Synchronous write + read (simple dual-port pattern, infers block RAM)
    always_ff @(posedge clk) begin
        if (tmpl_wr_en) begin
            case (tmpl_wr_addr[1:0])
                2'b00: tmpl_b2[tmpl_wr_addr[8:2]] <= tmpl_wr_data[31:0];
                2'b01: tmpl_b3[tmpl_wr_addr[8:2]] <= tmpl_wr_data[31:0];
                2'b10: tmpl_b4[tmpl_wr_addr[8:2]] <= tmpl_wr_data;
                2'b11: tmpl_b5[tmpl_wr_addr[8:2]] <= tmpl_wr_data;
            endcase
        end
        // Read address driven by latch_sym_id (valid from S_FETCH onwards)
        tmpl_rd_b2 <= tmpl_b2[latch_sym_id];
        tmpl_rd_b3 <= tmpl_b3[latch_sym_id];
        tmpl_rd_b4 <= tmpl_b4[latch_sym_id];
        tmpl_rd_b5 <= tmpl_b5[latch_sym_id];
    end

    // ------------------------------------------------------------------
    // FSM
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE  = 2'b00,
        S_FETCH = 2'b01,
        S_LOAD  = 2'b10,
        S_SEND  = 2'b11
    } state_t;

    state_t     state;
    logic [2:0] beat_cnt;   // 0..5

    // ------------------------------------------------------------------
    // Order token (64-bit auto-increment counter)
    // ------------------------------------------------------------------
    logic [63:0] order_token;

    // ------------------------------------------------------------------
    // Per-order latched inputs
    // ------------------------------------------------------------------
    logic        latch_side;
    logic [31:0] latch_price;
    logic [23:0] latch_shares;

    // ------------------------------------------------------------------
    // Beat buffer (beats 1-5; beat 0 driven directly from S_LOAD)
    // ------------------------------------------------------------------
    logic [63:0] beat_buf [1:5];

    // ------------------------------------------------------------------
    // Back-pressure watchdog
    // ------------------------------------------------------------------
    logic [5:0] bp_cnt;     // 64-cycle backpressure threshold
    logic [7:0] clr_cnt;    // 256-cycle self-clear counter
    logic       tx_ovf_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            bp_cnt    <= 6'h0;
            clr_cnt   <= 8'h0;
            tx_ovf_r  <= 1'b0;
        end else begin
            if (state == S_SEND && !m_axis_tready) begin
                clr_cnt <= 8'h0;
                if (&bp_cnt) begin          // saturate at 63
                    tx_ovf_r <= 1'b1;
                end else begin
                    bp_cnt <= bp_cnt + 6'h1;
                end
            end else begin
                bp_cnt <= 6'h0;
                if (tx_ovf_r) begin
                    if (&clr_cnt) begin     // 255 consecutive free cycles
                        tx_ovf_r <= 1'b0;
                        clr_cnt  <= 8'h0;
                    end else begin
                        clr_cnt <= clr_cnt + 8'h1;
                    end
                end
            end
        end
    end

    assign tx_overflow = tx_ovf_r;

    // ------------------------------------------------------------------
    // Main FSM
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            beat_cnt      <= 3'h0;
            order_token   <= 64'h0;
            latch_sym_id  <= 7'h0;
            latch_side    <= 1'b0;
            latch_price   <= 32'h0;
            latch_shares  <= 24'h0;
            m_axis_tvalid <= 1'b0;
            m_axis_tlast  <= 1'b0;
            m_axis_tkeep  <= 8'hFF;
            m_axis_tdata  <= 64'h0;
            for (int i = 1; i <= 5; i++) beat_buf[i] <= 64'h0;
        end else begin
            case (state)

                // --------------------------------------------------------
                S_IDLE: begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (risk_pass) begin
                        latch_sym_id  <= symbol_id;
                        latch_side    <= side;
                        latch_price   <= price;
                        latch_shares  <= proposed_shares;
                        // latch_sym_id takes effect next cycle (S_FETCH),
                        // so the BRAM read in S_FETCH uses the correct address.
                        state <= S_FETCH;
                    end
                end

                // --------------------------------------------------------
                S_FETCH: begin
                    // latch_sym_id is now valid → BRAM initiates read this posedge;
                    // tmpl_rd_b* will hold the correct data by S_LOAD.
                    state <= S_LOAD;
                end

                // --------------------------------------------------------
                S_LOAD: begin
                    // BRAM template data (tmpl_rd_b2/b3/b4/b5) is now valid.
                    // Assemble all 6 beats; output beat 0 immediately.

                    // Beat 0: message_type + order_token high 7 bytes
                    m_axis_tdata  <= {MSG_TYPE,
                                      order_token[63:56], order_token[55:48],
                                      order_token[47:40], order_token[39:32],
                                      order_token[31:24], order_token[23:16],
                                      order_token[15:8]};
                    m_axis_tvalid <= 1'b1;
                    m_axis_tlast  <= 1'b0;
                    m_axis_tkeep  <= 8'hFF;

                    // Beat 1: order_token LSB + 6 ASCII-'0' padding + buy/sell indicator
                    beat_buf[1] <= {order_token[7:0],
                                    8'h30, 8'h30, 8'h30, 8'h30, 8'h30, 8'h30,
                                    latch_side ? SIDE_BUY : SIDE_SELL};

                    // Beat 2 hot-patch: shares[31:0] (big-endian) into [63:32];
                    //   stock name bytes 0-3 from 32-bit template
                    beat_buf[2] <= {{8'h0, latch_shares}, tmpl_rd_b2};

                    // Beat 3 hot-patch: stock name bytes 4-7 from 32-bit template;
                    //   price[31:0] (big-endian) hot-patched into [31:0]
                    beat_buf[3] <= {tmpl_rd_b3, latch_price};

                    // Beats 4-5: static from template
                    beat_buf[4] <= tmpl_rd_b4;
                    beat_buf[5] <= tmpl_rd_b5;

                    order_token <= order_token + 64'h1;
                    beat_cnt    <= 3'h0;
                    state       <= S_SEND;
                end

                // --------------------------------------------------------
                S_SEND: begin
                    if (m_axis_tready) begin
                        if (beat_cnt == 3'h5) begin
                            m_axis_tvalid <= 1'b0;
                            m_axis_tlast  <= 1'b0;
                            state         <= S_IDLE;
                        end else begin
                            // Select next beat; cap index to avoid static ARRAYOOB
                            m_axis_tdata  <= beat_buf[beat_cnt < 3'h5
                                                      ? beat_cnt + 3'h1
                                                      : 3'h1];
                            m_axis_tkeep  <= 8'hFF;
                            m_axis_tlast  <= (beat_cnt == 3'h4);
                            beat_cnt      <= beat_cnt + 3'h1;
                        end
                    end
                    // backpressure counted in separate always_ff above
                end

                /* verilator coverage_off */
                default: state <= S_IDLE;
                /* verilator coverage_on */

            endcase
        end
    end

endmodule

`default_nettype wire
