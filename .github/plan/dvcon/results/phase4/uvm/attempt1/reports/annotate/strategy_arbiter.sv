//      // verilator_coverage annotation
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
        
%000001     always_comb begin
%000008         for (int i = 0; i < NUM_CORES; i++)
%000008             gated_valid[i] = core_valids[i] && (core_scores[i] > score_thresh);
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
~127564         for (g = 0; g < 4; g++) begin : gen_lv0
 127844             always_comb begin
 127564                 if (!gated_valid[g*2] && !gated_valid[g*2+1]) begin
 127564                     lv0_score[g] = core_scores[g*2];
 127564                     lv0_id[g]    = 3'(g*2);
 127564                     lv0_valid[g] = 1'b0;
 127564                     lv0_side[g]  = core_sides[g*2];
%000001                 end else if (!gated_valid[g*2]) begin
%000001                     lv0_score[g] = core_scores[g*2+1];
%000001                     lv0_id[g]    = 3'(g*2+1);
%000001                     lv0_valid[g] = 1'b1;
%000001                     lv0_side[g]  = core_sides[g*2+1];
~000276                 end else if (!gated_valid[g*2+1]) begin
%000003                     lv0_score[g] = core_scores[g*2];
%000003                     lv0_id[g]    = 3'(g*2);
%000003                     lv0_valid[g] = 1'b1;
%000003                     lv0_side[g]  = core_sides[g*2];
 000276                 end else begin
 000228                     if (core_scores[g*2] >= core_scores[g*2+1]) begin
 000228                         lv0_score[g] = core_scores[g*2];
 000228                         lv0_id[g]    = 3'(g*2);
 000228                         lv0_valid[g] = 1'b1;
 000228                         lv0_side[g]  = core_sides[g*2];
 000048                     end else begin
 000048                         lv0_score[g] = core_scores[g*2+1];
 000048                         lv0_id[g]    = 3'(g*2+1);
 000048                         lv0_valid[g] = 1'b1;
 000048                         lv0_side[g]  = core_sides[g*2+1];
                            end
                        end
                    end
                end
            endgenerate
        
            // ------------------------------------------------------------------
            // Level 0 → Level 1 pipeline registers
            // Breaks the 16-level combinational path (score_thresh→gated_valid→lv0→lv1→
            // lv2→best_core_id_reg, WNS -2.007 ns at 312.5 MHz) into two ≈8-level halves.
            // Increases best_* output latency from 1 cycle to 2 cycles.
            // ------------------------------------------------------------------
            (* DONT_TOUCH = "TRUE" *) float32_t  lv0_score_r [0:3];
            (* DONT_TOUCH = "TRUE" *) logic [2:0] lv0_id_r   [0:3];
            (* DONT_TOUCH = "TRUE" *) logic       lv0_valid_r [0:3];
            (* DONT_TOUCH = "TRUE" *) logic       lv0_side_r  [0:3];
        
            // Level 1 → Level 2 pipeline registers (DONT_TOUCH prevents phys_opt retiming)
            (* DONT_TOUCH = "TRUE" *) float32_t  lv1_score_r [0:1];
            (* DONT_TOUCH = "TRUE" *) logic [2:0] lv1_id_r   [0:1];
            (* DONT_TOUCH = "TRUE" *) logic       lv1_valid_r [0:1];
            (* DONT_TOUCH = "TRUE" *) logic       lv1_side_r  [0:1];
        
 031960     always_ff @(posedge clk) begin
 031928         if (rst) begin
 000128             for (int i = 0; i < 4; i++) begin
 000128                 lv0_score_r[i] <= '0;
 000128                 lv0_id_r[i]    <= '0;
 000128                 lv0_valid_r[i] <= 1'b0;
 000128                 lv0_side_r[i]  <= 1'b0;
                    end
 031928         end else begin
 127712             for (int i = 0; i < 4; i++) begin
 127712                 lv0_score_r[i] <= lv0_score[i];
 127712                 lv0_id_r[i]    <= lv0_id[i];
 127712                 lv0_valid_r[i] <= lv0_valid[i];
 127712                 lv0_side_r[i]  <= lv0_side[i];
                    end
                end
            end
        
            // ------------------------------------------------------------------
            // Level 1: compare lv0_r pairs (0,1) and (2,3) — all combinational
            // ------------------------------------------------------------------
 031961     always_comb begin
 063922         for (int i = 0; i < 2; i++) begin
 063780             if (!lv0_valid_r[i*2] && !lv0_valid_r[i*2+1]) begin
 063780                 lv1_score[i] = lv0_score_r[i*2];
 063780                 lv1_id[i]    = lv0_id_r[i*2];
 063780                 lv1_valid[i] = 1'b0;
 063780                 lv1_side[i]  = lv0_side_r[i*2];
%000001             end else if (!lv0_valid_r[i*2]) begin
%000001                 lv1_score[i] = lv0_score_r[i*2+1];
%000001                 lv1_id[i]    = lv0_id_r[i*2+1];
%000001                 lv1_valid[i] = 1'b1;
%000001                 lv1_side[i]  = lv0_side_r[i*2+1];
~000138             end else if (!lv0_valid_r[i*2+1]) begin
%000003                 lv1_score[i] = lv0_score_r[i*2];
%000003                 lv1_id[i]    = lv0_id_r[i*2];
%000003                 lv1_valid[i] = 1'b1;
%000003                 lv1_side[i]  = lv0_side_r[i*2];
 000138             end else begin
 000090                 if (lv0_score_r[i*2] >= lv0_score_r[i*2+1]) begin
 000090                     lv1_score[i] = lv0_score_r[i*2];
 000090                     lv1_id[i]    = lv0_id_r[i*2];
 000090                     lv1_valid[i] = 1'b1;
 000090                     lv1_side[i]  = lv0_side_r[i*2];
 000048                 end else begin
 000048                     lv1_score[i] = lv0_score_r[i*2+1];
 000048                     lv1_id[i]    = lv0_id_r[i*2+1];
 000048                     lv1_valid[i] = 1'b1;
 000048                     lv1_side[i]  = lv0_side_r[i*2+1];
                        end
                    end
                end
            end
        
            // ------------------------------------------------------------------
            // Level 1 → Level 2 pipeline registers
            // Breaks the second half of the 16-level path (lv0→lv1→lv2→best_reg)
            // into two ≤6-level halves. Increases best_* latency from 2 to 3 cycles.
            // DONT_TOUCH prevents phys_opt from retiming these away.
            // ------------------------------------------------------------------
 031960     always_ff @(posedge clk) begin
 031928         if (rst) begin
 000064             for (int i = 0; i < 2; i++) begin
 000064                 lv1_score_r[i] <= '0;
 000064                 lv1_id_r[i]    <= '0;
 000064                 lv1_valid_r[i] <= 1'b0;
 000064                 lv1_side_r[i]  <= 1'b0;
                    end
 031928         end else begin
 063856             for (int i = 0; i < 2; i++) begin
 063856                 lv1_score_r[i] <= lv1_score[i];
 063856                 lv1_id_r[i]    <= lv1_id[i];
 063856                 lv1_valid_r[i] <= lv1_valid[i];
 063856                 lv1_side_r[i]  <= lv1_side[i];
                    end
                end
            end
        
            // ------------------------------------------------------------------
            // Level 2: grand final — reads from lv1_r (registered Level 1 outputs)
            // ------------------------------------------------------------------
 031961     always_comb begin
 031888         if (!lv1_valid_r[0] && !lv1_valid_r[1]) begin
 031888             lv2_score = lv1_score_r[0];
 031888             lv2_id    = lv1_id_r[0];
 031888             lv2_valid = 1'b0;
 031888             lv2_side  = lv1_side_r[0];
%000001         end else if (!lv1_valid_r[0]) begin
%000001             lv2_score = lv1_score_r[1];
%000001             lv2_id    = lv1_id_r[1];
%000001             lv2_valid = 1'b1;
%000001             lv2_side  = lv1_side_r[1];
~000069         end else if (!lv1_valid_r[1]) begin
%000003             lv2_score = lv1_score_r[0];
%000003             lv2_id    = lv1_id_r[0];
%000003             lv2_valid = 1'b1;
%000003             lv2_side  = lv1_side_r[0];
 000069         end else begin
 000048             if (lv1_score_r[0] >= lv1_score_r[1]) begin
 000021                 lv2_score = lv1_score_r[0];
 000021                 lv2_id    = lv1_id_r[0];
 000021                 lv2_valid = 1'b1;
 000021                 lv2_side  = lv1_side_r[0];
 000048             end else begin
 000048                 lv2_score = lv1_score_r[1];
 000048                 lv2_id    = lv1_id_r[1];
 000048                 lv2_valid = 1'b1;
 000048                 lv2_side  = lv1_side_r[1];
                    end
                end
            end
        
            // ------------------------------------------------------------------
            // Single output register — 1-cycle latency from core_valids
            // ------------------------------------------------------------------
 031960     always_ff @(posedge clk) begin
 031928         if (rst) begin
 000032             best_score   <= '0;
 000032             best_core_id <= '0;
 000032             best_valid   <= 1'b0;
 000032             best_side    <= 1'b0;
 031928         end else begin
 031928             best_score   <= lv2_score;
 031928             best_core_id <= lv2_id;
 031928             best_valid   <= lv2_valid;
 031928             best_side    <= lv2_side;
                end
            end
        
        endmodule
        
