// symbol_filter.sv — 64-entry LUT-CAM symbol watchlist filter
//
// Compares the 8-character ASCII Stock field from itch_field_extract
// against a 64-entry configurable watchlist.  Asserts watchlist_hit
// one cycle after stock_valid.
//
// Implementation: distributed-RAM / FF-based CAM.
//   64 entries × 64-bit key register + 64 valid bits.
//   Match tree is fully combinational (one LUT level compares key equality
//   across all 64 entries in parallel).  The OR-reduction and the final
//   register fit within the 1-cycle latency budget at 300 MHz.
//
// AXI4-Lite write port (from kc705_top / axi4_lite_slave):
//   cam_wr_index [7:0]  — target entry (0–63)
//   cam_wr_data  [63:0] — ticker key (8-byte ASCII, zero-padded right)
//   cam_wr_valid        — write-enable strobe (1 cycle)
//   cam_wr_en_bit       — 1 = mark entry valid, 0 = invalidate entry
//
// Resource estimate (xc7k160t):
//   64 × 64-bit key registers = 4,096 FFs
//   64 × 1-bit valid registers = 64 FFs
//   Comparison tree ≈ 512 LUTs (64 × 8 XNOR gates collapsed to 64 × 1 LUT)
//   Well within 101,440 LUT / 202,880 FF budget.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module symbol_filter (
    input  logic        clk,
    input  logic        rst,

    // Stock field from itch_field_extract (8-byte ASCII ticker)
    input  logic [63:0] stock,
    input  logic        stock_valid,

    // Registered match output: 1 cycle after stock_valid
    output logic        watchlist_hit,

    // AXI4-Lite write interface (from axi4_lite_slave CAM register bank)
    input  logic [7:0]  cam_wr_index,   // entry index 0–63
    input  logic [63:0] cam_wr_data,    // key to write
    input  logic        cam_wr_valid,   // write-enable
    input  logic        cam_wr_en_bit   // 1 = valid entry, 0 = invalidate
);

    // ---------------------------------------------------------------
    // CAM storage: 64 key registers + 64 valid bits
    // ---------------------------------------------------------------
    logic [63:0] cam_entry [0:63];
    logic        cam_valid [0:63];

    genvar gi;
    generate
        for (gi = 0; gi < 64; gi++) begin : g_cam_init
            // Initialise all entries as invalid on reset
            always_ff @(posedge clk) begin
                if (rst) begin
                    cam_entry[gi] <= 64'b0;
                    cam_valid[gi] <= 1'b0;
                end else if (cam_wr_valid && (cam_wr_index == 8'(gi))) begin
                    cam_entry[gi] <= cam_wr_data;
                    cam_valid[gi] <= cam_wr_en_bit;
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------
    // Match tree: combinational compare all 64 entries in parallel
    // ---------------------------------------------------------------
    logic [63:0] match_vec;

    genvar mi;
    generate
        for (mi = 0; mi < 64; mi++) begin : g_match
            assign match_vec[mi] = cam_valid[mi] & (stock == cam_entry[mi]);
        end
    endgenerate

    logic match_comb;
    assign match_comb = |match_vec;

    // ---------------------------------------------------------------
    // Output register: 1-cycle latency from stock_valid
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst)
            watchlist_hit <= 1'b0;
        else
            watchlist_hit <= stock_valid & match_comb;
    end

endmodule
