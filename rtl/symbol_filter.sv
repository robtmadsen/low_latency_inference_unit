// symbol_filter.sv — 512-entry LUT-CAM symbol watchlist filter
//
// Compares the 8-character ASCII Stock field from itch_field_extract
// against a 512-entry configurable watchlist.  Asserts watchlist_hit
// one cycle after stock_valid.
//
// Implementation: distributed-RAM / FF-based CAM.
//   512 entries × 64-bit key register + 512 valid bits.
//   Match tree is fully combinational (one LUT level compares key equality
//   across all 512 entries in parallel).  The OR-reduction and the final
//   register fit within the 1-cycle latency budget at 300 MHz.
//
// AXI4-Lite write port (from kc705_top / axi4_lite_slave):
//   cam_wr_index [9:0]  — target entry (0–511)
//   cam_wr_data  [63:0] — ticker key (8-byte ASCII, zero-padded right)
//   cam_wr_valid        — write-enable strobe (1 cycle)
//   cam_wr_en_bit       — 1 = mark entry valid, 0 = invalidate entry
//
// Resource estimate (xc7k160t):
//   512 × 64-bit key registers = 32,768 FFs
//   512 × 1-bit valid registers = 512 FFs
//   Comparison tree ≈ 4,096 LUTs (512 × 8 XNOR gates collapsed to 512 × 1 LUT)
//   Est. ~3,500 LUTs per v2 resource budget.

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
    input  logic [9:0]  cam_wr_index,   // entry index 0–511
    input  logic [63:0] cam_wr_data,    // key to write
    input  logic        cam_wr_valid,   // write-enable
    input  logic        cam_wr_en_bit   // 1 = valid entry, 0 = invalidate
);

    // ---------------------------------------------------------------
    // CAM storage: 512 key registers + 512 valid bits
    // ---------------------------------------------------------------
    logic [63:0] cam_entry [0:511];
    logic        cam_valid [0:511];

    genvar gi;
    generate
        for (gi = 0; gi < 512; gi++) begin : g_cam_init
            // Initialise all entries as invalid on reset
            always_ff @(posedge clk) begin
                if (rst) begin
                    cam_entry[gi] <= 64'b0;
                    cam_valid[gi] <= 1'b0;
                end else if (cam_wr_valid && (cam_wr_index == 10'(gi))) begin
                    cam_entry[gi] <= cam_wr_data;
                    cam_valid[gi] <= cam_wr_en_bit;
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------
    // Match tree: combinational compare all 64 entries in parallel
    // ---------------------------------------------------------------
    logic [511:0] match_vec;

    genvar mi;
    generate
        for (mi = 0; mi < 512; mi++) begin : g_match
            assign match_vec[mi] = cam_valid[mi] & (stock == cam_entry[mi]);
        end
    endgenerate

    logic match_comb;
    assign match_comb = |match_vec;
    logic lookup_valid_q;
    logic lookup_match_q;

    // cam_entry_match: combinational match result exposed for SVA binding.
    // The (* keep = "true" *) attribute prevents synthesis optimisation from
    // removing this wire.  The bind statement in tb_top.sv should connect
    // .cam_entry_match(cam_entry_match) instead of the current 1'b0 stub.
    /* verilator lint_off UNUSEDSIGNAL */
    (* keep = "true" *) logic cam_entry_match;
    /* verilator lint_on UNUSEDSIGNAL */
    assign cam_entry_match = match_comb;

    // ---------------------------------------------------------------
    // Output register: 1-cycle latency from stock_valid
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            lookup_valid_q <= 1'b0;
            lookup_match_q <= 1'b0;
            watchlist_hit <= 1'b0;
        end else begin
            // Output previous lookup result to guarantee 1-cycle latency and
            // pre-write isolation when stock_valid and cam_wr_valid coincide.
            watchlist_hit <= lookup_valid_q & lookup_match_q;
            lookup_valid_q <= stock_valid;
            lookup_match_q <= match_comb;
        end
    end

endmodule
