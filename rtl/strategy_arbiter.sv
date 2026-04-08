// strategy_arbiter.sv — Tournament-tree winner selection across NUM_CORES inference cores
//
// 3-level all-combinational tournament tree (NUM_CORES = 8):
//   Level 0: 4 × 2-input comparators  (pairs 0-1, 2-3, 4-5, 6-7)
//   Level 1: 2 × 2-input comparators  (lv0 winners: 0-1 vs 2-3, 4-5 vs 6-7)
//   Level 2: 1 × 2-input comparator   (grand final)
//
// score_thresh gate: cores with score < score_thresh are masked before the
// tournament; only above-threshold signals can win.
//
// IEEE 754 positive floats compare correctly as unsigned 32-bit integers
// (scores are always non-negative dot-product magnitudes).
//
// Single output register: best_* signals are stable 1 cycle after core_valids.

`default_nettype none

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module strategy_arbiter (
    input  logic      clk,
    input  logic      rst,

    // Per-core inputs
    input  float32_t  core_scores [NUM_CORES],
    input  logic      core_valids [NUM_CORES],
    input  logic      core_sides  [NUM_CORES],

    // Configurable fire threshold (float32, unsigned 32-bit compare)
    input  float32_t  score_thresh,

    // Winner output (1-cycle registered)
    output float32_t  best_score,
    output logic [2:0] best_core_id,
    output logic      best_valid,
    output logic      best_side
);

    // ------------------------------------------------------------------
    // Threshold gate: mask cores whose score is below score_thresh
    // ------------------------------------------------------------------
    logic gated_valid [NUM_CORES];

    always_comb begin
        for (int i = 0; i < NUM_CORES; i++)
            gated_valid[i] = core_valids[i] && (core_scores[i] >= score_thresh);
    end

    // ------------------------------------------------------------------
    // Tournament node signals
    // Level 0: 4 nodes from 8 gated inputs
    float32_t  lv0_score  [0:3];
    logic [2:0] lv0_id    [0:3];
    logic       lv0_valid [0:3];
    logic       lv0_side  [0:3];

    // Level 1: 2 nodes from 4 level-0 outputs
    float32_t  lv1_score  [0:1];
    logic [2:0] lv1_id    [0:1];
    logic       lv1_valid [0:1];
    logic       lv1_side  [0:1];

    // Level 2: grand winner (combinational)
    float32_t  lv2_score;
    logic [2:0] lv2_id;
    logic       lv2_valid;
    logic       lv2_side;

    // ------------------------------------------------------------------
    // Level 0: compare gated pairs (0,1), (2,3), (4,5), (6,7) — combinational
    // ------------------------------------------------------------------
    genvar g;
    generate
        for (g = 0; g < 4; g++) begin : gen_lv0
            always_comb begin
                if (!gated_valid[g*2] && !gated_valid[g*2+1]) begin
                    lv0_score[g] = core_scores[g*2];
                    lv0_id[g]    = 3'(g*2);
                    lv0_valid[g] = 1'b0;
                    lv0_side[g]  = core_sides[g*2];
                end else if (!gated_valid[g*2]) begin
                    lv0_score[g] = core_scores[g*2+1];
                    lv0_id[g]    = 3'(g*2+1);
                    lv0_valid[g] = 1'b1;
                    lv0_side[g]  = core_sides[g*2+1];
                end else if (!gated_valid[g*2+1]) begin
                    lv0_score[g] = core_scores[g*2];
                    lv0_id[g]    = 3'(g*2);
                    lv0_valid[g] = 1'b1;
                    lv0_side[g]  = core_sides[g*2];
                end else begin
                    if (core_scores[g*2] >= core_scores[g*2+1]) begin
                        lv0_score[g] = core_scores[g*2];
                        lv0_id[g]    = 3'(g*2);
                        lv0_valid[g] = 1'b1;
                        lv0_side[g]  = core_sides[g*2];
                    end else begin
                        lv0_score[g] = core_scores[g*2+1];
                        lv0_id[g]    = 3'(g*2+1);
                        lv0_valid[g] = 1'b1;
                        lv0_side[g]  = core_sides[g*2+1];
                    end
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Level 1: compare lv0 pairs (0,1) and (2,3) — all combinational
    // ------------------------------------------------------------------
    always_comb begin
        for (int i = 0; i < 2; i++) begin
            if (!lv0_valid[i*2] && !lv0_valid[i*2+1]) begin
                lv1_score[i] = lv0_score[i*2];
                lv1_id[i]    = lv0_id[i*2];
                lv1_valid[i] = 1'b0;
                lv1_side[i]  = lv0_side[i*2];
            end else if (!lv0_valid[i*2]) begin
                lv1_score[i] = lv0_score[i*2+1];
                lv1_id[i]    = lv0_id[i*2+1];
                lv1_valid[i] = 1'b1;
                lv1_side[i]  = lv0_side[i*2+1];
            end else if (!lv0_valid[i*2+1]) begin
                lv1_score[i] = lv0_score[i*2];
                lv1_id[i]    = lv0_id[i*2];
                lv1_valid[i] = 1'b1;
                lv1_side[i]  = lv0_side[i*2];
            end else begin
                if (lv0_score[i*2] >= lv0_score[i*2+1]) begin
                    lv1_score[i] = lv0_score[i*2];
                    lv1_id[i]    = lv0_id[i*2];
                    lv1_valid[i] = 1'b1;
                    lv1_side[i]  = lv0_side[i*2];
                end else begin
                    lv1_score[i] = lv0_score[i*2+1];
                    lv1_id[i]    = lv0_id[i*2+1];
                    lv1_valid[i] = 1'b1;
                    lv1_side[i]  = lv0_side[i*2+1];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Level 2: grand final — combinational
    // ------------------------------------------------------------------
    always_comb begin
        if (!lv1_valid[0] && !lv1_valid[1]) begin
            lv2_score = lv1_score[0];
            lv2_id    = lv1_id[0];
            lv2_valid = 1'b0;
            lv2_side  = lv1_side[0];
        end else if (!lv1_valid[0]) begin
            lv2_score = lv1_score[1];
            lv2_id    = lv1_id[1];
            lv2_valid = 1'b1;
            lv2_side  = lv1_side[1];
        end else if (!lv1_valid[1]) begin
            lv2_score = lv1_score[0];
            lv2_id    = lv1_id[0];
            lv2_valid = 1'b1;
            lv2_side  = lv1_side[0];
        end else begin
            if (lv1_score[0] >= lv1_score[1]) begin
                lv2_score = lv1_score[0];
                lv2_id    = lv1_id[0];
                lv2_valid = 1'b1;
                lv2_side  = lv1_side[0];
            end else begin
                lv2_score = lv1_score[1];
                lv2_id    = lv1_id[1];
                lv2_valid = 1'b1;
                lv2_side  = lv1_side[1];
            end
        end
    end

    // ------------------------------------------------------------------
    // Single output register — 1-cycle latency from core_valids
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            best_score   <= '0;
            best_core_id <= '0;
            best_valid   <= 1'b0;
            best_side    <= 1'b0;
        end else begin
            best_score   <= lv2_score;
            best_core_id <= lv2_id;
            best_valid   <= lv2_valid;
            best_side    <= lv2_side;
        end
    end

endmodule

`default_nettype wire
