// lliu_core.sv — Parameterized single inference core for LLIU v2.0
//
// Wraps weight_mem + dot_product_engine + output_buffer with a 4-state
// sequencer that serialises the VEC_LEN-element feature vector one element
// per clock into the pipelined dot-product engine.
//
// Sequencer FSM (mirrors the v1 lliu_top sequencer, with WAIT state added):
//
//   SEQ_IDLE    : wait for features_valid; latch feature vector; assert
//                 dp_start (clears DPE accumulator, DPE enters COMPUTE next
//                 cycle); go to SEQ_PRELOAD.
//   SEQ_PRELOAD : dp_start visible at DPE; wgt_rd_addr = 0 (combinatorial),
//                 so weight_mem latches weight[0] this posedge → rd_data =
//                 weight[0] in the first SEQ_FEED cycle.  1-cycle hold.
//   SEQ_FEED    : drive (dp_feature_in, dp_feature_valid) as registered
//                 signals; present one element per cycle.
//                 Aligned timing: both registered signals and wgt_rd_data use
//                 seq_idx from the *previous* cycle, so DPE always receives
//                 feat_latch[N] and weight[N] simultaneously.
//   SEQ_WAIT    : hold after the last feed cycle until dp_result_valid fires
//                 (DPE drains its pipeline).  Prevents a rapid new features_
//                 valid from issuing dp_start mid-drain and corrupting the
//                 accumulator.
//
// Timing (VEC_LEN = 32):
//   IDLE(1) + PRELOAD(1) + FEED(32) + WAIT(drain) → result_valid
//   DPE drain = 6 cycles; DONE = 1 cycle → total ≈ 41 cycles per inference.
//
// Parameters:
//   VEC_LEN — feature vector length  (default FEAT_VEC_LEN_V2 = 32)
//   HIDDEN  — weight memory depth    (default HIDDEN_LAYER     = 32)
//   Must satisfy VEC_LEN == HIDDEN for a valid dot product.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module lliu_core #(
    parameter int VEC_LEN = FEAT_VEC_LEN_V2,  // 32
    parameter int HIDDEN  = HIDDEN_LAYER       // 32
)(
    input  logic      clk,
    input  logic      rst,

    // Feature vector from feature_extractor_v2 (broadcast to all 8 cores)
    input  bfloat16_t features    [VEC_LEN],
    input  logic      features_valid,

    // Weight write port (per-core, from AXI4-Lite weight loader)
    input  logic [$clog2(HIDDEN)-1:0] wgt_wr_addr,
    input  bfloat16_t                 wgt_wr_data,
    input  logic                      wgt_wr_en,

    // Inference result — 1-cycle pulse; aligned with result_valid
    output float32_t  result,
    output logic      result_valid,

    // Stable AXI4-Lite readout (latched by output_buffer)
    output float32_t  result_out,
    output logic      result_ready
);

    // ------------------------------------------------------------------
    // Feature vector latch
    // ------------------------------------------------------------------
    bfloat16_t feat_latch [VEC_LEN];

    // ------------------------------------------------------------------
    // Sequencer FSM
    // ------------------------------------------------------------------
    typedef enum logic [1:0] {
        SEQ_IDLE    = 2'b00,
        SEQ_PRELOAD = 2'b01,
        SEQ_FEED    = 2'b10,
        SEQ_WAIT    = 2'b11
    } seq_state_t;

    seq_state_t seq_state;

    // seq_idx counts 0..VEC_LEN-1.  Use clog2(VEC_LEN+1) for the same
    // extra-bit headroom as the v1 sequencer so the terminal comparison
    // never wraps before the condition fires.
    logic [$clog2(VEC_LEN+1)-1:0] seq_idx;

    // Narrow alias used for weight_mem rd_addr and feat_latch indexing
    // (lower $clog2(VEC_LEN) bits; safe because seq_idx never exceeds
    // VEC_LEN-1 in SEQ_FEED).
    logic [$clog2(HIDDEN)-1:0] seq_idx_narrow;
    assign seq_idx_narrow = seq_idx[$clog2(HIDDEN)-1:0];

    // ------------------------------------------------------------------
    // Registered DPE control signals (same approach as v1 lliu_top)
    // ------------------------------------------------------------------
    logic      dp_start;
    logic      dp_feature_valid;
    bfloat16_t dp_feature_in;

    // DPE and weight_mem outputs
    bfloat16_t wgt_rd_data;
    float32_t  dp_result;
    logic      dp_result_valid;

    // ------------------------------------------------------------------
    // Sequencer always_ff
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            seq_state        <= SEQ_IDLE;
            seq_idx          <= '0;
            dp_start         <= 1'b0;
            dp_feature_valid <= 1'b0;
            dp_feature_in    <= '0;
            for (int i = 0; i < VEC_LEN; i++) feat_latch[i] <= '0;
        end else begin
            dp_start         <= 1'b0;   // default deassert
            dp_feature_valid <= 1'b0;   // default deassert

            case (seq_state)

                // --------------------------------------------------------
                SEQ_IDLE: begin
                    if (features_valid) begin
                        // Latch the full feature vector
                        for (int i = 0; i < VEC_LEN; i++)
                            feat_latch[i] <= features[i];
                        // Kick dp_start (appears in SEQ_PRELOAD)
                        dp_start  <= 1'b1;
                        seq_idx   <= '0;
                        seq_state <= SEQ_PRELOAD;
                    end
                end

                // --------------------------------------------------------
                SEQ_PRELOAD: begin
                    // dp_start is visible at DPE this cycle; DPE clears its
                    // accumulator and transitions to COMPUTE at this posedge.
                    // wgt_rd_addr = seq_idx_narrow = 0 (combinatorial), so
                    // weight_mem latches weight[0] at this posedge →
                    // rd_data = weight[0] in SEQ_FEED cycle 0.
                    seq_state <= SEQ_FEED;
                end

                // --------------------------------------------------------
                SEQ_FEED: begin
                    // Register the current element; both dp_feature_in and
                    // wgt_rd_data (weight[seq_idx_narrow]) appear at DPE in
                    // the *next* cycle, aligned by construction.
                    dp_feature_in    <= feat_latch[seq_idx_narrow];
                    dp_feature_valid <= 1'b1;

                    if (seq_idx == ($clog2(VEC_LEN+1))'(VEC_LEN - 1)) begin
                        seq_idx   <= '0;
                        seq_state <= SEQ_WAIT;
                    end else begin
                        seq_idx <= seq_idx + 1;
                    end
                end

                // --------------------------------------------------------
                SEQ_WAIT: begin
                    // Features[VEC_LEN-1] appears at DPE this cycle
                    // (registered from last SEQ_FEED posedge).  DPE will
                    // count that element and begin draining.  Wait here until
                    // dp_result_valid fires before accepting new features.
                    if (dp_result_valid)
                        seq_state <= SEQ_IDLE;
                end

                /* verilator coverage_off */
                default: seq_state <= SEQ_IDLE;
                /* verilator coverage_on */

            endcase
        end
    end

    // ------------------------------------------------------------------
    // Weight memory read address: combinatorial from seq_idx so that
    // weight_mem latches weight[seq_idx] at each posedge, yielding
    // rd_data = weight[seq_idx_prev] one cycle later — exactly aligned
    // with dp_feature_in registered from the same seq_idx value.
    // ------------------------------------------------------------------
    logic [$clog2(HIDDEN)-1:0] wgt_rd_addr_r;
    assign wgt_rd_addr_r = seq_idx_narrow;

    // ------------------------------------------------------------------
    // weight_mem — one per core; AXI4-Lite writable, DPE readable
    // ------------------------------------------------------------------
    weight_mem #(
        .DEPTH (HIDDEN)
    ) u_weight_mem (
        .clk     (clk),
        .rst     (rst),
        .wr_addr (wgt_wr_addr),
        .wr_data (wgt_wr_data),
        .wr_en   (wgt_wr_en),
        .rd_addr (wgt_rd_addr_r),
        .rd_data (wgt_rd_data)
    );

    // ------------------------------------------------------------------
    // dot_product_engine — parameterised to VEC_LEN
    // ------------------------------------------------------------------
    dot_product_engine #(
        .VEC_LEN (VEC_LEN)
    ) u_dpe (
        .clk           (clk),
        .rst           (rst),
        .feature_in    (dp_feature_in),
        .feature_valid (dp_feature_valid),
        .weight_in     (wgt_rd_data),
        .start         (dp_start),
        .result        (dp_result),
        .result_valid  (dp_result_valid)
    );

    // ------------------------------------------------------------------
    // Inference result outputs
    // result / result_valid are the 1-cycle pulse from DPE (combinational
    // in DPE's S_DONE state) and are consumed by strategy_arbiter.
    // ------------------------------------------------------------------
    assign result       = dp_result;
    assign result_valid = dp_result_valid;

    // ------------------------------------------------------------------
    // output_buffer — stable latch for AXI4-Lite result readout
    // ------------------------------------------------------------------
    output_buffer u_out_buf (
        .clk          (clk),
        .rst          (rst),
        .result_in    (dp_result),
        .result_valid (dp_result_valid),
        .result_out   (result_out),
        .result_ready (result_ready)
    );

endmodule
