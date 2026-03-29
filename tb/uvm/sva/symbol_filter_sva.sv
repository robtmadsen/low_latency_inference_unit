// symbol_filter_sva.sv — Protocol assertions for symbol_filter
//
// Bound into symbol_filter via tb_top.sv (inside `ifdef SYMFILTER_DUT).
// Spec ref: .github/arch/kintex-7/Kintex-7_MAS.md §2.2
//
// Performance contract: stock_valid → watchlist_hit = exactly 1 cycle.
//
// Note: P3 (pipeline_throughput) references expected_hit_delayed_1, which
// is a locally tracked shadow variable.  P4 (write_isolation) references
// cam_entry_match — an internal DUT signal.  Both require coordination:
// P3's expected_hit is computed locally in this module from a shadow model;
// P4 uses cam_entry_match which requires (* keep = "true" *) in RTL.

`timescale 1ns/1ps

module symbol_filter_sva (
    input logic        clk,
    input logic        rst,

    // DUT ports (all directly available as they are module I/O)
    input logic        stock_valid,
    input logic [63:0] stock,
    input logic        watchlist_hit,

    // CAM write ports (also DUT I/O — used to mirror the CAM in this module)
    input logic [5:0]  cam_wr_index,
    input logic [63:0] cam_wr_data,
    input logic        cam_wr_valid,
    input logic        cam_wr_en_bit,

    // Internal RTL signal (requires (* keep = "true" *)):
    //   cam_entry_match — the combinational match signal before registering
    // Tied to 1'b0 (stub) in bind statement until RTL coordinates the annotation.
    input logic        cam_entry_match  // 0 = stub
);

    // ── Shadow CAM model (mirrors the DUT's 64-entry lookup table) ──
    // Used to compute expected_hit in simulation time for property checking.
    logic [63:0] shadow_cam_key [0:63];
    logic        shadow_cam_en  [0:63];
    logic        expected_hit;       // combinational expected result
    logic        expected_hit_r;     // registered (1 cycle delayed)

    initial begin
        for (int i = 0; i < 64; i++) begin
            shadow_cam_key[i] = 64'd0;
            shadow_cam_en[i]  = 1'b0;
        end
    end

    // Update shadow CAM on write
    always_ff @(posedge clk) begin
        if (cam_wr_valid) begin
            shadow_cam_key[cam_wr_index] <= cam_wr_data;
            shadow_cam_en[cam_wr_index]  <= cam_wr_en_bit;
        end
    end

    // Compute combinational expected_hit (any enabled entry matches stock?)
    always_comb begin
        expected_hit = 1'b0;
        for (int i = 0; i < 64; i++) begin
            if (shadow_cam_en[i] && (shadow_cam_key[i] == stock))
                expected_hit = 1'b1;
        end
    end

    // Delayed expected_hit (registered to align with DUT's 1-cycle pipeline)
    always_ff @(posedge clk) begin
        if (rst)
            expected_hit_r <= 1'b0;
        else
            expected_hit_r <= (stock_valid ? expected_hit : 1'b0);
    end

    // ── S1: watchlist_hit is exactly 1 cycle after stock_valid ─────
    // (MAS §2.2 — 1-cycle registered output)
    property p_hit_latency;
        @(posedge clk) disable iff (rst)
        $rose(stock_valid) |=> (watchlist_hit === expected_hit_r);
    endproperty
    assert property (p_hit_latency)
        else $error("SVA [SYMFILTER]: watchlist_hit != expected value 1 cycle after stock_valid");

    // ── S2: no spurious hit without stock_valid on previous cycle ───
    property p_no_spurious_hit;
        @(posedge clk) disable iff (rst)
        (!$past(stock_valid)) |-> !watchlist_hit;
    endproperty
    assert property (p_no_spurious_hit)
        else $error("SVA [SYMFILTER]: watchlist_hit asserted without preceding stock_valid");

    // ── S3: back-to-back throughput — hit follows 1 cycle every time
    // expected_hit_r already provides the 1-cycle-delayed expected value.
    property p_pipeline_throughput;
        @(posedge clk) disable iff (rst)
        (stock_valid) |=> (watchlist_hit === expected_hit_r);
    endproperty
    assert property (p_pipeline_throughput)
        else $error("SVA [SYMFILTER]: watchlist_hit wrong value in back-to-back mode");

    // ── S4: CAM write does not corrupt registered output mid-lookup ─
    // When cam_wr_valid and stock_valid occur on the same cycle, the
    // registered output 1 cycle later must reflect the pre-write CAM state.
    // Depends on internal cam_entry_match (stub when tied to 0).
    property p_write_isolation;
        @(posedge clk) disable iff (rst)
        (cam_wr_valid && stock_valid) |=> (watchlist_hit == $past(cam_entry_match));
    endproperty
    assert property (p_write_isolation)
        else $error("SVA [SYMFILTER]: write-during-lookup corrupted registered output");

endmodule
