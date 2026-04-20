// snapshot_mux.sv — BBO shadow buffer and snapshot streamer for pcie_dma_engine
//
// Maintains a OB_NUM_SYMBOLS-entry shadow BRAM copy of all symbol BBOs.  Each entry
// is updated on every order_book bbo_valid pulse — with a 1-cycle delay to
// let the order_book registered read path (bbo_bid_price_r → bbo_bid_price)
// settle after the write.
//
// A snapshot is streamed out on snap_req as 2×OB_NUM_SYMBOLS × 64-bit beats:
//   beat 2k+0 : {bid_price[31:0],  8'h00, bid_size[23:0]}  (symbol k, bid)
//   beat 2k+1 : {ask_price[31:0],  8'h00, ask_size[23:0]}  (symbol k, ask)
//   k = 0 … OB_NUM_SYMBOLS-1
//
// snap_valid and snap_data are COMBINATIONAL outputs derived from the state
// register and the BRAM read pipeline registers.  snap_ready may be tied
// high by pcie_dma_engine when the staging buffer can always accept data.
//
// Resources (xc7k160tffg676-2):
//   bid_bram : 512 × 64 b → 1 RAMB36E1
//   ask_bram : 512 × 64 b → 1 RAMB36E1
//   Total: 2 RAMB36E1 (< 1% of 325 available)
//
// Throughput: PREFETCH(1) + SEND_BID(1) + SEND_ASK(1) = 3 cyc/symbol,
//   1 500 cycles = 4.8 µs @ 312.5 MHz — well within the 10 ms DMA period.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

/* verilator lint_off MULTITOP */
module snapshot_mux (
    input  logic        clk,
    input  logic        rst,

    // ── Live BBO updates from order_book (sys_clk domain) ────────────────
    // bbo_bid_price / ask_price / bid_size / ask_size are the REGISTERED
    // outputs of bbo_*_r[bbo_query_sym].  They reflect the write performed at
    // the same cycle as bbo_valid but are available one cycle later (registered
    // read path).  snapshot_mux delays bbo_valid by one cycle internally so
    // the BRAM write captures the fresh, settled BBO value.
    input  logic        bbo_valid,
    input  logic [OB_SYM_ID_W-1:0] bbo_sym_id,
    input  logic [31:0] bbo_bid_price,
    input  logic [31:0] bbo_ask_price,
    input  logic [23:0] bbo_bid_size,
    input  logic [23:0] bbo_ask_size,

    // ── Snapshot stream to pcie_dma_engine (sys_clk domain) ──────────────
    input  logic        snap_req,    // one-cycle pulse: start a new snapshot
    output logic [63:0] snap_data,   // combinational — valid when snap_valid=1
    output logic        snap_valid,  // combinational from state register
    input  logic        snap_ready,  // consumer ready (may be combinational)
    output logic        snap_done    // registered one-cycle pulse after last beat
);

    // ------------------------------------------------------------------
    // Shadow BRAMs: OB_NUM_SYMBOLS × 64-bit each
    // ------------------------------------------------------------------
    (* ram_style = "block" *) logic [63:0] bid_bram [0:OB_NUM_SYMBOLS-1];
    (* ram_style = "block" *) logic [63:0] ask_bram [0:OB_NUM_SYMBOLS-1];

    // Bit-layout per entry:
    //   [63:32] = price[31:0]
    //   [31:24] = 8'h00  (pad: fills to 4-byte DWORD boundary for PCIe)
    //   [23: 0] = size[23:0]

    // ------------------------------------------------------------------
    // 1-cycle pipeline delay on bbo_valid so the BRAM write captures the
    // settled registered-read value from order_book.
    // ------------------------------------------------------------------
    logic        bbo_valid_d1;
    logic [OB_SYM_ID_W-1:0] bbo_sym_id_d1;

    always_ff @(posedge clk) begin
        if (rst) begin
            bbo_valid_d1  <= 1'b0;
            bbo_sym_id_d1 <= '0;
        end else begin
            bbo_valid_d1  <= bbo_valid;
            bbo_sym_id_d1 <= bbo_sym_id;
        end
    end

    // BRAM write port (sys_clk domain – one writer, order-book BBO updates)
    always_ff @(posedge clk) begin
        if (bbo_valid_d1) begin
            bid_bram[bbo_sym_id_d1] <= {bbo_bid_price, 8'h00, bbo_bid_size};
            ask_bram[bbo_sym_id_d1] <= {bbo_ask_price, 8'h00, bbo_ask_size};
        end
    end

    // BRAM read port: registered, 1-cycle latency
    logic [OB_SYM_ID_W-1:0] rd_addr;
    logic [63:0] rd_bid_r;
    logic [63:0] rd_ask_r;

    always_ff @(posedge clk) begin
        rd_bid_r <= bid_bram[rd_addr];
        rd_ask_r <= ask_bram[rd_addr];
    end

    // ------------------------------------------------------------------
    // Streaming FSM
    //
    //  S_IDLE     : wait for snap_req; latch rd_addr = 0
    //  S_PREFETCH : rd_addr stable; BRAM registered read latches bid+ask
    //  S_SEND_BID : output bid beat; advance on snap_ready
    //  S_SEND_ASK : output ask beat; advance rd_addr or done on snap_ready
    //
    // snap_valid and snap_data are COMBINATIONAL from the state register and
    // the BRAM read pipeline registers.  This avoids stale-valid bugs that
    // arise when snap_ready is pre-asserted before snap_valid goes high.
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        S_IDLE     = 2'b00,
        S_PREFETCH = 2'b01,
        S_SEND_BID = 2'b10,
        S_SEND_ASK = 2'b11
    } snap_state_t;

    snap_state_t state;

    always_ff @(posedge clk) begin
        if (rst) begin
            state     <= S_IDLE;
            rd_addr   <= '0;
            snap_done <= 1'b0;
        end else begin
            snap_done <= 1'b0;  // default: deassert

            case (state)
                S_IDLE: begin
                    if (snap_req) begin
                        rd_addr <= '0;
                        state   <= S_PREFETCH;
                    end
                end

                S_PREFETCH: begin
                    // rd_addr is stable.  BRAM registered read fires at this
                    // posedge → rd_bid_r / rd_ask_r are valid after this cycle.
                    state <= S_SEND_BID;
                end

                S_SEND_BID: begin
                    if (snap_ready)
                        state <= S_SEND_ASK;
                end

                S_SEND_ASK: begin
                    if (snap_ready) begin
                        if (rd_addr == OB_SYM_ID_W'(OB_NUM_SYMBOLS - 1)) begin
                            snap_done <= 1'b1;
                            state     <= S_IDLE;
                        end else begin
                            rd_addr <= rd_addr + OB_SYM_ID_W'(1);
                            state   <= S_PREFETCH;
                        end
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Combinational outputs
    assign snap_valid = (state == S_SEND_BID) | (state == S_SEND_ASK);
    assign snap_data  = (state == S_SEND_BID) ? rd_bid_r : rd_ask_r;

endmodule
