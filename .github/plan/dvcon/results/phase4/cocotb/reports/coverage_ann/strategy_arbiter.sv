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
        
 8665973     always_comb begin
 69327784         for (int i = 0; i < NUM_CORES; i++)
 69327784             gated_valid[i] = core_valids[i] && (core_scores[i] > score_thresh);
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
 34656997         for (g = 0; g < 4; g++) begin : gen_lv0
 34663892             always_comb begin
 34656997                 if (!gated_valid[g*2] && !gated_valid[g*2+1]) begin
 34656997                     lv0_score[g] = core_scores[g*2];
 34656997                     lv0_id[g]    = 3'(g*2);
 34656997                     lv0_valid[g] = 1'b0;
 34656997                     lv0_side[g]  = core_sides[g*2];
 000090                 end else if (!gated_valid[g*2]) begin
 000090                     lv0_score[g] = core_scores[g*2+1];
 000090                     lv0_id[g]    = 3'(g*2+1);
 000090                     lv0_valid[g] = 1'b1;
 000090                     lv0_side[g]  = core_sides[g*2+1];
 006720                 end else if (!gated_valid[g*2+1]) begin
 000085                     lv0_score[g] = core_scores[g*2];
 000085                     lv0_id[g]    = 3'(g*2);
 000085                     lv0_valid[g] = 1'b1;
 000085                     lv0_side[g]  = core_sides[g*2];
 006720                 end else begin
 006575                     if (core_scores[g*2] >= core_scores[g*2+1]) begin
 006575                         lv0_score[g] = core_scores[g*2];
 006575                         lv0_id[g]    = 3'(g*2);
 006575                         lv0_valid[g] = 1'b1;
 006575                         lv0_side[g]  = core_sides[g*2];
 000145                     end else begin
 000145                         lv0_score[g] = core_scores[g*2+1];
 000145                         lv0_id[g]    = 3'(g*2+1);
 000145                         lv0_valid[g] = 1'b1;
 000145                         lv0_side[g]  = core_sides[g*2+1];
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
        
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 011288             for (int i = 0; i < 4; i++) begin
 011288                 lv0_score_r[i] <= '0;
 011288                 lv0_id_r[i]    <= '0;
 011288                 lv0_valid_r[i] <= 1'b0;
 011288                 lv0_side_r[i]  <= 1'b0;
                    end
 1715919         end else begin
 6863676             for (int i = 0; i < 4; i++) begin
 6863676                 lv0_score_r[i] <= lv0_score[i];
 6863676                 lv0_id_r[i]    <= lv0_id[i];
 6863676                 lv0_valid_r[i] <= lv0_valid[i];
 6863676                 lv0_side_r[i]  <= lv0_side[i];
                    end
                end
            end
        
            // ------------------------------------------------------------------
            // Level 1: compare lv0_r pairs (0,1) and (2,3) — all combinational
            // ------------------------------------------------------------------
 8665973     always_comb begin
 17331946         for (int i = 0; i < 2; i++) begin
 17328491             if (!lv0_valid_r[i*2] && !lv0_valid_r[i*2+1]) begin
 17328491                 lv1_score[i] = lv0_score_r[i*2];
 17328491                 lv1_id[i]    = lv0_id_r[i*2];
 17328491                 lv1_valid[i] = 1'b0;
 17328491                 lv1_side[i]  = lv0_side_r[i*2];
 000010             end else if (!lv0_valid_r[i*2]) begin
 000010                 lv1_score[i] = lv0_score_r[i*2+1];
 000010                 lv1_id[i]    = lv0_id_r[i*2+1];
 000010                 lv1_valid[i] = 1'b1;
 000010                 lv1_side[i]  = lv0_side_r[i*2+1];
 003440             end else if (!lv0_valid_r[i*2+1]) begin
 000005                 lv1_score[i] = lv0_score_r[i*2];
 000005                 lv1_id[i]    = lv0_id_r[i*2];
 000005                 lv1_valid[i] = 1'b1;
 000005                 lv1_side[i]  = lv0_side_r[i*2];
 003440             end else begin
 003340                 if (lv0_score_r[i*2] >= lv0_score_r[i*2+1]) begin
 003340                     lv1_score[i] = lv0_score_r[i*2];
 003340                     lv1_id[i]    = lv0_id_r[i*2];
 003340                     lv1_valid[i] = 1'b1;
 003340                     lv1_side[i]  = lv0_side_r[i*2];
 000100                 end else begin
 000100                     lv1_score[i] = lv0_score_r[i*2+1];
 000100                     lv1_id[i]    = lv0_id_r[i*2+1];
 000100                     lv1_valid[i] = 1'b1;
 000100                     lv1_side[i]  = lv0_side_r[i*2+1];
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
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 005644             for (int i = 0; i < 2; i++) begin
 005644                 lv1_score_r[i] <= '0;
 005644                 lv1_id_r[i]    <= '0;
 005644                 lv1_valid_r[i] <= 1'b0;
 005644                 lv1_side_r[i]  <= 1'b0;
                    end
 1715919         end else begin
 3431838             for (int i = 0; i < 2; i++) begin
 3431838                 lv1_score_r[i] <= lv1_score[i];
 3431838                 lv1_id_r[i]    <= lv1_id[i];
 3431838                 lv1_valid_r[i] <= lv1_valid[i];
 3431838                 lv1_side_r[i]  <= lv1_side[i];
                    end
                end
            end
        
            // ------------------------------------------------------------------
            // Level 2: grand final — reads from lv1_r (registered Level 1 outputs)
            // ------------------------------------------------------------------
 8665973     always_comb begin
 8664233         if (!lv1_valid_r[0] && !lv1_valid_r[1]) begin
 8664233             lv2_score = lv1_score_r[0];
 8664233             lv2_id    = lv1_id_r[0];
 8664233             lv2_valid = 1'b0;
 8664233             lv2_side  = lv1_side_r[0];
 000010         end else if (!lv1_valid_r[0]) begin
 000010             lv2_score = lv1_score_r[1];
 000010             lv2_id    = lv1_id_r[1];
 000010             lv2_valid = 1'b1;
 000010             lv2_side  = lv1_side_r[1];
 001715         end else if (!lv1_valid_r[1]) begin
 000015             lv2_score = lv1_score_r[0];
 000015             lv2_id    = lv1_id_r[0];
 000015             lv2_valid = 1'b1;
 000015             lv2_side  = lv1_side_r[0];
 001715         end else begin
 001710             if (lv1_score_r[0] >= lv1_score_r[1]) begin
 001710                 lv2_score = lv1_score_r[0];
 001710                 lv2_id    = lv1_id_r[0];
 001710                 lv2_valid = 1'b1;
 001710                 lv2_side  = lv1_side_r[0];
 000005             end else begin
 000005                 lv2_score = lv1_score_r[1];
 000005                 lv2_id    = lv1_id_r[1];
 000005                 lv2_valid = 1'b1;
 000005                 lv2_side  = lv1_side_r[1];
                    end
                end
            end
        
            // ------------------------------------------------------------------
            // Single output register — 1-cycle latency from core_valids
            // ------------------------------------------------------------------
 1718741     always_ff @(posedge clk) begin
 1715919         if (rst) begin
 002822             best_score   <= '0;
 002822             best_core_id <= '0;
 002822             best_valid   <= 1'b0;
 002822             best_side    <= 1'b0;
 1715919         end else begin
 1715919             best_score   <= lv2_score;
 1715919             best_core_id <= lv2_id;
 1715919             best_valid   <= lv2_valid;
 1715919             best_side    <= lv2_side;
                end
            end
        
        endmodule
        
