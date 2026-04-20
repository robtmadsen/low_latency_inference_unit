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

    // Match output: combinational from the registered lookup stage
    output logic        watchlist_hit,

    // AXI4-Lite write interface (from axi4_lite_slave CAM register bank)
    input  logic [SYM_FILTER_IDX_W:0] cam_wr_index, // entry index 0..SYM_FILTER_ENTRIES-1
    input  logic [63:0] cam_wr_data,    // key to write
    input  logic        cam_wr_valid,   // write-enable
    input  logic        cam_wr_en_bit   // 1 = valid entry, 0 = invalidate
);

    // ---------------------------------------------------------------
    // CAM storage: SYM_FILTER_ENTRIES key registers + valid bits
    // ---------------------------------------------------------------
    logic [63:0] cam_entry [0:SYM_FILTER_ENTRIES-1];
    logic        cam_valid [0:SYM_FILTER_ENTRIES-1];

    genvar gi;
    generate
        for (gi = 0; gi < SYM_FILTER_ENTRIES; gi++) begin : g_cam_init
            // Initialise all entries as invalid on reset
            always_ff @(posedge clk) begin
                if (rst) begin
                    cam_entry[gi] <= 64'b0;
                    cam_valid[gi] <= 1'b0;
                end else if (cam_wr_valid && (cam_wr_index == (SYM_FILTER_IDX_W+1)'(gi))) begin
                    cam_entry[gi] <= cam_wr_data;
                    cam_valid[gi] <= cam_wr_en_bit;
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------
    // Run 33 fix: pipeline register on stock/stock_valid to break the
    // cross-region high-fanout route from u_parser/stock_reg (fo=64).
    // (* max_fanout = 8 *) forces synthesis to replicate each stock_q bit
    // so all 64 comparison LUTs route locally within the pblock rather than
    // receiving a long cross-region fan-out from u_parser.
    // NOTE: this adds 1 cycle to watchlist_hit; lliu_top_v2.sv compensates
    // by adding a second delay stage (_d2) for the aligned parser fields.
    // ---------------------------------------------------------------
    (* max_fanout = 4 *) logic [63:0] stock_q;
    logic stock_valid_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            stock_q       <= 64'b0;
            stock_valid_q <= 1'b0;
        end else begin
            stock_q       <= stock;
            stock_valid_q <= stock_valid;
        end
    end

    // ---------------------------------------------------------------
    // Match tree: combinational compare all 64 entries in parallel
    // ---------------------------------------------------------------
    logic [SYM_FILTER_ENTRIES-1:0] match_vec;

    genvar mi;
    generate
        for (mi = 0; mi < SYM_FILTER_ENTRIES; mi++) begin : g_match
            assign match_vec[mi] = cam_valid[mi] & (stock_q == cam_entry[mi]);
        end
    endgenerate

    // ---------------------------------------------------------------
    // Stage 2 pipeline: registered partial ORs (8 groups of 8 entries).
    //
    // Vivado's opt_design (RuntimeOptimized) flattens combinational OR
    // trees and re-maps them to CARRY4 chains.  The 6-stage CARRY4 chain
    // terminates at SLICE_X46Y16 but lookup_match_q_reg sits at X35Y28 —
    // a 0.854 ns cross-region routing hop that closes timing at −0.176 ns.
    //
    // Registering the 8 partial ORs (match_partial_r) breaks the chain:
    //   Stage 2: stock_q → 64 comparisons → 8 group ORs → match_partial_r
    //            (Path: ~1.3 ns — comfortably within 3.200 ns budget)
    //   Stage 3: match_partial_r → 8-input OR (1 LUT6, ~0.05 ns) → lookup_match_q
    //            (Path: ~0.5 ns — trivially met)
    //
    // Cost: +1 cycle on watchlist_hit.  lliu_top_v2 compensates with _d3
    // alignment (was _d2 before this change).
    // ---------------------------------------------------------------
    logic [7:0] match_partial_r;
    logic       stock_valid_qq;    // extra valid delay for Stage 2→3 alignment

    genvar oi;
    generate
        for (oi = 0; oi < 8; oi++) begin : g_or_tree
            always_ff @(posedge clk) begin
                if (rst) match_partial_r[oi] <= 1'b0;
                else     match_partial_r[oi] <= |match_vec[oi*8 +: 8];
            end
        end
    endgenerate

    always_ff @(posedge clk) begin
        if (rst) stock_valid_qq <= 1'b0;
        else     stock_valid_qq <= stock_valid_q;
    end

    logic match_comb;
    assign match_comb = |match_partial_r;   // 8-input OR → 1 LUT6
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
    // Stage 3: capture partial-OR result + aligned valid.
    // watchlist_hit arrives 3 cycles after stock_valid input;
    // lliu_top_v2 uses fields_valid_d3 alignment.
    // ---------------------------------------------------------------
    assign watchlist_hit = lookup_valid_q & lookup_match_q;

    always_ff @(posedge clk) begin
        if (rst) begin
            lookup_valid_q <= 1'b0;
            lookup_match_q <= 1'b0;
        end else begin
            lookup_valid_q <= stock_valid_qq;   // was stock_valid_q (pre-stage-2)
            lookup_match_q <= match_comb;
        end
    end

endmodule
