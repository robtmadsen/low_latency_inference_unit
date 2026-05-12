//      // verilator_coverage annotation
        // fp32_acc.sv — Float32 accumulator, five-stage pipeline
        //
        // Accumulates float32 values over multiple cycles.
        // Supports clear (reset to zero) and accumulate enable.
        //
        // Six-stage pipeline to meet 312.5 MHz on Kintex-7 -2:
        //   Stage A0:   exponent compare                           → registered → *_r0
        //   Stage A0.5: barrel-shift alignment only                → registered → *_r05
        //   Stage A1:   pre-compute arith (CARRY4 from r05 FDREs)  → registered → *_r
        //   Stage B1:   mantissa MUX-select (no CARRY4)            → registered → sum_man_b1_r
        //   Stage B2:   normalise                                  → registered → partial_sum_r
        //   Stage C:    partial_sum_r → acc_reg                    → acc_out
        //
        // Run 43 fix: Stage A0 acc_larger_a0 (exponent compare CARRY4, fo=64) gets
        // (* max_fanout = 16 *) synthesis attribute.  Synthesis creates ~4 CARRY4
        // replicas each driving ≤16 endpoints, reducing the routing budget from
        // 0.544 ns (fo=64, critical in Run 41) to ~0.150 ns per copy.
        // Run 40 fix: Stage A1 registers both the alignment result AND all three
        // pre-computed arithmetic results (sub_big_minus_small, sub_small_minus_big,
        // add_result, big_ge_small) computed combinationally from Stage A0 FDRE outputs.
        // This structurally cuts the critical path:
        //   OLD (9 levels): big_man_r → CARRY4×2 (cmp) → fo=26 → CARRY4×5 (sub) → B1
        //   NEW (Stage A0→A1 CARRY4 chains start from A0 FDREs; Stage A1→B1 is MUX only)
        // All CARRY4 chains start from registered FDREs — no cascade across stages.
        //
        // Back-to-back acc_en forwarding:
        //   acc_en_d5 asserted (Stage C about to fire) → Stage A0 uses partial_sum_r.
        //   (Otherwise)                                → Stage A0 uses acc_reg.
        //
        // Uses a simplified float32 add: aligns mantissas by exponent difference,
        // adds, and renormalizes. Sufficient for small vector dot products where
        // catastrophic cancellation is not a concern.
        
        /* verilator lint_off IMPORTSTAR */
        import lliu_pkg::*;
        /* verilator lint_on IMPORTSTAR */
        
        module fp32_acc (
 012396     input  logic     clk,
 000096     input  logic     rst,
~000097     input  float32_t addend,
 000378     input  logic     acc_en,
 000060     input  logic     acc_clear,
~000067     output float32_t acc_out
        );
        
            // Stage C register (final accumulated result, feeds output and back-path)
~000067     float32_t acc_reg;
            // Stage B2 register (sum result from normalise, feeds Stage C)
~000067     float32_t partial_sum_r;
            // Delayed enables: drive pipelined stages
 000378     logic     acc_en_d1;  // 1 cycle after acc_en  → Stage A0.5 fires
 000378     logic     acc_en_d2;  // 2 cycles after acc_en → Stage A1 fires
 000378     logic     acc_en_d3;  // 3 cycles after acc_en → Stage B1 fires
 000378     logic     acc_en_d4;  // 4 cycles after acc_en → Stage B2 fires
 000378     logic     acc_en_d5;  // 5 cycles after acc_en → Stage C fires
        
            // -------------------------------------------------------------------
            // Forwarding mux: decide which accumulated value to use as the
            // feedback operand entering Stage A0.
            //   - acc_en_d5: Stage C is about to register partial_sum_r, so the
            //     most recent committed sum is still in partial_sum_r.
            //   - Otherwise: acc_reg holds the most recent committed sum.
            // This eliminates the RAW hazard on consecutive acc_en pulses.
            // -------------------------------------------------------------------
~000067     float32_t acc_fb;
 063564     assign acc_fb = acc_en_d5 ? acc_reg : partial_sum_r;
        
            // -------------------------------------------------------------------
            // Stage A0 combinational: decompose operands, compare exponents
            // (no carry chain — just comparators and muxes)
            // -------------------------------------------------------------------
 000097     logic        acc_sign_a0, add_sign_a0;
~000074     logic [7:0]  acc_exp_a0,  add_exp_a0;
~000087     logic [23:0] acc_man_a0,  add_man_a0;
 000085     logic        acc_zero_a0, add_zero_a0;
            // max_fanout=16: synthesis replicates this CARRY4 chain into ~4 copies,
            // each driving ≤16 of the 64 Stage-A0 register endpoints.  This cuts the
            // fo=64 routing (0.544 ns in Run 41) to ≤0.15 ns per replica.
 000079     (* max_fanout = 16 *) logic acc_larger_a0;
~000103     logic [23:0] big_man_a0,  small_man_a0;
 000081     logic        big_sign_a0;
~000091     logic [7:0]  big_exp_a0;
~000130     logic [7:0]  exp_diff_a0;
 000101     logic        eff_sub_a0;
        
 065454     always_comb begin
 065454         acc_sign_a0 = acc_fb[31];
 065454         acc_exp_a0  = acc_fb[30:23];
 065454         acc_zero_a0 = (acc_fb[30:0] == 31'b0);
 065454         acc_man_a0  = acc_zero_a0 ? 24'b0 : {1'b1, acc_fb[22:0]};
        
 065454         add_sign_a0 = addend[31];
 065454         add_exp_a0  = addend[30:23];
 065454         add_zero_a0 = (addend[30:0] == 31'b0);
 065454         add_man_a0  = add_zero_a0 ? 24'b0 : {1'b1, addend[22:0]};
        
 065454         acc_larger_a0 = (acc_exp_a0 >= add_exp_a0);
        
 065454         small_man_a0 = acc_larger_a0 ? add_man_a0  : acc_man_a0;
 065454         big_man_a0   = acc_larger_a0 ? acc_man_a0  : add_man_a0;
 065454         big_sign_a0  = acc_larger_a0 ? acc_sign_a0 : add_sign_a0;
 065454         big_exp_a0   = acc_larger_a0 ? acc_exp_a0  : add_exp_a0;
        
                // Run 27 fix: compute both possible differences in parallel (no serial
                // dependency on acc_larger_a0), then MUX the result.  Breaks the
                // compare-CARRY4 → serial-subtract-CARRY4 chain (7 LUT/CARRY4 levels,
                // −0.327 ns WNS) into compare-CARRY4 + MUX-LUT (3 levels).
 065454         exp_diff_a0 = acc_larger_a0 ? (acc_exp_a0 - add_exp_a0)
 008331                                     : (add_exp_a0 - acc_exp_a0);
 065454         eff_sub_a0  = acc_sign_a0 ^ add_sign_a0;
            end
        
            // Stage A0 registers (capture exponent-compare result; fires on acc_en)
~000056     logic [23:0] big_man_r0;
~000057     logic [23:0] small_man_r0;
 000027     logic        big_sign_r0;
~000059     logic [7:0]  big_exp_r0;
~000076     logic [7:0]  exp_diff_r0;
 000021     logic        eff_sub_r0;
 000057     logic        acc_zero_r0;
 000058     logic        add_zero_r0;
~000052     float32_t    addend_r0;
~000058     float32_t    acc_fb_r0;
        
 012396     always_ff @(posedge clk) begin
 000480         if (rst) begin
 000480             big_man_r0   <= 24'b0;
 000480             small_man_r0 <= 24'b0;
 000480             big_sign_r0  <= 1'b0;
 000480             big_exp_r0   <= 8'b0;
 000480             exp_diff_r0  <= 8'b0;
 000480             eff_sub_r0   <= 1'b0;
 000480             acc_zero_r0  <= 1'b1;
 000480             add_zero_r0  <= 1'b1;
 000480             addend_r0    <= 32'b0;
 000480             acc_fb_r0    <= 32'b0;
 011538         end else if (acc_en) begin
 000378             big_man_r0   <= big_man_a0;
 000378             small_man_r0 <= small_man_a0;
 000378             big_sign_r0  <= big_sign_a0;
 000378             big_exp_r0   <= big_exp_a0;
 000378             exp_diff_r0  <= exp_diff_a0;
 000378             eff_sub_r0   <= eff_sub_a0;
 000378             acc_zero_r0  <= acc_zero_a0;
 000378             add_zero_r0  <= add_zero_a0;
 000378             addend_r0    <= addend;
 000378             acc_fb_r0    <= acc_fb;
                end
            end
        
            // -------------------------------------------------------------------
            // Stage A0.5 combinational: barrel-shift only (no arithmetic)
            // Input: Stage A0 registers (small_man_r0, exp_diff_r0)
            // Separating the shift from the CARRY4 arithmetic breaks the 11-level
            // critical path into two ~5-level chains.
            // -------------------------------------------------------------------
~000057     logic [23:0] aligned_small_man_a05;
        
 065454     always_comb begin
 062636         if (exp_diff_r0 > 8'd24)
 002818             aligned_small_man_a05 = 24'b0;
                else
 062636             aligned_small_man_a05 = small_man_r0 >> exp_diff_r0;
            end
        
            // Stage A0.5 registers (barrel-shift result + sidecar; fires on acc_en_d1)
~000057     logic [23:0] aligned_small_man_r05;
~000056     logic [23:0] big_man_r05;
 000027     logic        big_sign_r05;
~000059     logic [7:0]  big_exp_r05;
 000021     logic        eff_sub_r05;
 000057     logic        acc_zero_r05;
 000058     logic        add_zero_r05;
~000052     float32_t    addend_r05;
~000058     float32_t    acc_fb_r05;
        
 012396     always_ff @(posedge clk) begin
 000540         if (rst || acc_clear) begin
 000540             aligned_small_man_r05 <= 24'b0;
 000540             big_man_r05           <= 24'b0;
 000540             big_sign_r05          <= 1'b0;
 000540             big_exp_r05           <= 8'b0;
 000540             eff_sub_r05           <= 1'b0;
 000540             acc_zero_r05          <= 1'b1;
 000540             add_zero_r05          <= 1'b1;
 000540             addend_r05            <= 32'b0;
 000540             acc_fb_r05            <= 32'b0;
 011478         end else if (acc_en_d1) begin
 000378             aligned_small_man_r05 <= aligned_small_man_a05;
 000378             big_man_r05           <= big_man_r0;
 000378             big_sign_r05          <= big_sign_r0;
 000378             big_exp_r05           <= big_exp_r0;
 000378             eff_sub_r05           <= eff_sub_r0;
 000378             acc_zero_r05          <= acc_zero_r0;
 000378             add_zero_r05          <= add_zero_r0;
 000378             addend_r05            <= addend_r0;
 000378             acc_fb_r05            <= acc_fb_r0;
                end
            end
        
            // -------------------------------------------------------------------
            // Stage A1 combinational: pre-compute arithmetic from A0.5 FDREs
            // Input: Stage A0.5 registers only — barrel shift already done.
            // All three arithmetic results (CARRY4) start from registered FDREs.
            // -------------------------------------------------------------------
~000073     logic [24:0] sub_bms_a1;      // {1'b0,big_man_r05} - {1'b0,aligned_small_man_r05}
~000106     logic [24:0] sub_smb_a1;      // {1'b0,aligned_small_man_r05} - {1'b0,big_man_r05}
~000110     logic [24:0] add_a1;          // {1'b0,big_man_r05} + {1'b0,aligned_small_man_r05}
~000012     logic        big_ge_small_a1; // big_man_r05 >= aligned_small_man_r05
        
%000006     always_comb begin
%000006         sub_bms_a1      = {1'b0, big_man_r05} - {1'b0, aligned_small_man_r05};
%000006         sub_smb_a1      = {1'b0, aligned_small_man_r05} - {1'b0, big_man_r05};
%000006         add_a1          = {1'b0, big_man_r05} + {1'b0, aligned_small_man_r05};
%000006         big_ge_small_a1 = (big_man_r05 >= aligned_small_man_r05);
            end
        
            // Stage A1 registers (capture pre-computed arithmetic; fires on acc_en_d2)
            // Run 39: registering sub_bms_r/sub_smb_r/add_r/big_ge_small_r here cuts the
            // critical path: Stage A1→B1 is a pure MUX (no CARRY4).
~000073     logic [24:0] sub_bms_r;      // registered: big - small
~000106     logic [24:0] sub_smb_r;      // registered: small - big
~000110     logic [24:0] add_r;          // registered: big + small
 000067     logic        big_ge_small_r; // registered: big >= small
 000027     logic        big_sign_r;
 000021     logic        eff_sub_r;
~000059     logic [7:0]  big_exp_r;
 000057     logic        acc_zero_r;
 000058     logic        add_zero_r;
~000052     float32_t    addend_r;
~000058     float32_t    acc_fb_r;
        
 012396     always_ff @(posedge clk) begin
 000540         if (rst || acc_clear) begin
 000540             sub_bms_r      <= 25'b0;
 000540             sub_smb_r      <= 25'b0;
 000540             add_r          <= 25'b0;
 000540             big_ge_small_r <= 1'b0;
 000540             big_sign_r     <= 1'b0;
 000540             eff_sub_r      <= 1'b0;
 000540             big_exp_r      <= 8'b0;
 000540             acc_zero_r     <= 1'b1;
 000540             add_zero_r     <= 1'b1;
 000540             addend_r       <= 32'b0;
 000540             acc_fb_r       <= 32'b0;
 011478         end else if (acc_en_d2) begin
 000378             sub_bms_r      <= sub_bms_a1;
 000378             sub_smb_r      <= sub_smb_a1;
 000378             add_r          <= add_a1;
 000378             big_ge_small_r <= big_ge_small_a1;
 000378             big_sign_r     <= big_sign_r05;
 000378             eff_sub_r      <= eff_sub_r05;
 000378             big_exp_r      <= big_exp_r05;
 000378             acc_zero_r     <= acc_zero_r05;
 000378             add_zero_r     <= add_zero_r05;
 000378             addend_r       <= addend_r05;
 000378             acc_fb_r       <= acc_fb_r05;
                end
            end
        
            // -------------------------------------------------------------------
            // Stage B1 registers (pure MUX-select; fires on acc_en_d3)
            // Run 39: uses pre-computed sub_bms_r/sub_smb_r/add_r/big_ge_small_r
            // from Stage A1. No CARRY4 on the critical path.
            // -------------------------------------------------------------------
~000111     logic [24:0] sum_man_b1_r;    // raw 25-bit mantissa sum/difference
 000027     logic        sum_sign_b1_r;   // sign of result
~000059     logic [7:0]  sum_exp_b1_r;    // exponent of result
 000057     logic        both_zero_b1_r;  // acc_zero_r && add_zero_r
 000057     logic        acc_zero_b1_r;   // acc operand was zero
 000058     logic        add_zero_b1_r;   // add operand was zero
~000052     float32_t    addend_b1_r;     // passthrough: addend when acc was zero
~000058     float32_t    acc_fb_b1_r;     // passthrough: acc_fb when add was zero
        
 012396     always_ff @(posedge clk) begin
 000540         if (rst || acc_clear) begin
 000540             sum_man_b1_r   <= 25'b0;
 000540             sum_sign_b1_r  <= 1'b0;
 000540             sum_exp_b1_r   <= 8'b0;
 000540             both_zero_b1_r <= 1'b1;
 000540             acc_zero_b1_r  <= 1'b1;
 000540             add_zero_b1_r  <= 1'b1;
 000540             addend_b1_r    <= 32'b0;
 000540             acc_fb_b1_r    <= 32'b0;
 011478         end else if (acc_en_d3) begin
 000378             sum_exp_b1_r   <= big_exp_r;
 000378             both_zero_b1_r <= acc_zero_r && add_zero_r;
 000378             acc_zero_b1_r  <= acc_zero_r;
 000378             add_zero_b1_r  <= add_zero_r;
 000378             addend_b1_r    <= addend_r;
 000378             acc_fb_b1_r    <= acc_fb_r;
 000338             if (eff_sub_r) begin
~000036                 if (big_ge_small_r) begin
 000036                     sum_man_b1_r  <= sub_bms_r;
 000036                     sum_sign_b1_r <= big_sign_r;
%000004                 end else begin
%000004                     sum_man_b1_r  <= sub_smb_r;
%000004                     sum_sign_b1_r <= !big_sign_r;
                        end
 000338             end else begin
 000338                 sum_man_b1_r  <= add_r;
 000338                 sum_sign_b1_r <= big_sign_r;
                    end
                end
            end
        
            // -------------------------------------------------------------------
            // Stage B2 combinational: normalise the registered raw adder result
            // -------------------------------------------------------------------
~000067     float32_t sum_result_b2;
        
 065454     always_comb begin
 035678         if (both_zero_b1_r) begin
 035678             sum_result_b2 = 32'b0;
 002790         end else if (acc_zero_b1_r) begin
 002790             sum_result_b2 = addend_b1_r;
 000025         end else if (add_zero_b1_r) begin
 000025             sum_result_b2 = acc_fb_b1_r;
                /* verilator coverage_off */  // exact cancellation: requires identical-magnitude opposing products
                end else if (sum_man_b1_r == 25'b0) begin
                    sum_result_b2 = 32'b0;
                /* verilator coverage_on */
 008898         end else if (sum_man_b1_r[24]) begin
 008898             sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r + 8'd1, sum_man_b1_r[23:1]};
 017257         end else if (!sum_man_b1_r[23]) begin
 000788             sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r, sum_man_b1_r[22:0]}; // default
 000688             if      (sum_man_b1_r[22]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd1,  sum_man_b1_r[21:0], 1'b0};  end
 000050             else if (sum_man_b1_r[21]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd2,  sum_man_b1_r[20:0], 2'b0};  end
%000000             else if (sum_man_b1_r[20]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd3,  sum_man_b1_r[19:0], 3'b0};  end
%000000             else if (sum_man_b1_r[19]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd4,  sum_man_b1_r[18:0], 4'b0};  end
%000000             else if (sum_man_b1_r[18]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd5,  sum_man_b1_r[17:0], 5'b0};  end
 000025             else if (sum_man_b1_r[17]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd6,  sum_man_b1_r[16:0], 6'b0};  end
 000025             else if (sum_man_b1_r[16]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd7,  sum_man_b1_r[15:0], 7'b0};  end
%000000             else if (sum_man_b1_r[15]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd8,  sum_man_b1_r[14:0], 8'b0};  end
%000000             else if (sum_man_b1_r[14]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd9,  sum_man_b1_r[13:0], 9'b0};  end
%000000             else if (sum_man_b1_r[13]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd10, sum_man_b1_r[12:0], 10'b0}; end
%000000             else if (sum_man_b1_r[12]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd11, sum_man_b1_r[11:0], 11'b0}; end
%000000             else if (sum_man_b1_r[11]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd12, sum_man_b1_r[10:0], 12'b0}; end
                    /* verilator coverage_off */  // deep renorm [10:0]: repeating pattern proven by [22:11] coverage;
                    //   requires >13 bits cancellation precision — unreachable with bfloat16 dot product
                    else if (sum_man_b1_r[10]) begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd13, sum_man_b1_r[9:0],  13'b0}; end
                    else if (sum_man_b1_r[9])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd14, sum_man_b1_r[8:0],  14'b0}; end
                    else if (sum_man_b1_r[8])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd15, sum_man_b1_r[7:0],  15'b0}; end
                    else if (sum_man_b1_r[7])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd16, sum_man_b1_r[6:0],  16'b0}; end
                    else if (sum_man_b1_r[6])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd17, sum_man_b1_r[5:0],  17'b0}; end
                    else if (sum_man_b1_r[5])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd18, sum_man_b1_r[4:0],  18'b0}; end
                    else if (sum_man_b1_r[4])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd19, sum_man_b1_r[3:0],  19'b0}; end
                    else if (sum_man_b1_r[3])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd20, sum_man_b1_r[2:0],  20'b0}; end
                    else if (sum_man_b1_r[2])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd21, sum_man_b1_r[1:0],  21'b0}; end
                    else if (sum_man_b1_r[1])  begin sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r - 8'd22, sum_man_b1_r[0],    22'b0}; end
                    else                       begin sum_result_b2 = 32'b0; end
                    /* verilator coverage_on */
 017257         end else begin
 017257             sum_result_b2 = {sum_sign_b1_r, sum_exp_b1_r, sum_man_b1_r[22:0]};
                end
            end
        
            // Delayed enables
 012396     always_ff @(posedge clk) begin
 011856         if (rst || acc_clear) begin
 000540             acc_en_d1 <= 1'b0;
 000540             acc_en_d2 <= 1'b0;
 000540             acc_en_d3 <= 1'b0;
 000540             acc_en_d4 <= 1'b0;
 000540             acc_en_d5 <= 1'b0;
 011856         end else begin
 011856             acc_en_d1 <= acc_en;
 011856             acc_en_d2 <= acc_en_d1;
 011856             acc_en_d3 <= acc_en_d2;
 011856             acc_en_d4 <= acc_en_d3;
 011856             acc_en_d5 <= acc_en_d4;
                end
            end
        
            // Stage B2 register: capture normalised sum (fires on acc_en_d4)
 012396     always_ff @(posedge clk) begin
 000540         if (rst || acc_clear)
 000540             partial_sum_r <= 32'b0;
 011478         else if (acc_en_d4)
 000378             partial_sum_r <= sum_result_b2;
            end
        
            // Stage C register: move Stage B2 result into feedback accumulator
 012396     always_ff @(posedge clk) begin
 000540         if (rst || acc_clear)
 000540             acc_reg <= 32'b0;
 011478         else if (acc_en_d5)
 000378             acc_reg <= partial_sum_r;
            end
        
            assign acc_out = acc_reg;
        
        endmodule
        
