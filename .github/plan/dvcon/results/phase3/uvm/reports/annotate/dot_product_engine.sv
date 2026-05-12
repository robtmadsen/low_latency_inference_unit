//      // verilator_coverage annotation
        // dot_product_engine.sv --- Pipelined MAC for small feature vectors
        //
        // Five-accumulator round-robin design (replaces BUG-001 7-cycle slot workaround).
        // Streaming: features are fed directly to the MAC pipeline as they arrive,
        // eliminating the separate buffer-then-replay (COLLECT + MAC) phases.
        //
        // FSM: IDLE -> STREAM (VEC_LEN+6 cycles minimum) -> DRAIN -> DONE
        //
        // Timing (feature_valid=1 every cycle, no stalls):
        //   STREAM: VEC_LEN feed cycles + 6 mac_drain cycles = VEC_LEN+6 cycles.
        //   DRAIN : NUM_ACCS_USED merge pulses at 4-cycle intervals.
        //           Last merge_en at DRAIN_LAST_EN = (NUM-1)*4.
        //           Exit at drain_cnt == DRAIN_EXIT_VAL = DRAIN_LAST_EN + 4.
        //           (acc_en_d4 fires at DRAIN_EXIT_VAL; acc_reg written on that edge)
        //   DONE  : result_valid COMBINATIONAL (state==S_DONE), 1 clock wide.
        //
        //   DPE cycles from start to result_valid (no stalls):
        //     VEC_LEN=4  (NUM=4): (4+6)+(12+4)=26 cycles.
        //     VEC_LEN=32 (NUM=5): (32+6)+(16+4)=58 cycles.
        //
        // Pipeline overview:
        //   bfloat16_mul : 2-cycle latency. Inputs combinational from feature_in/weight_in.
        //   fp32_acc     : 5-stage pipeline; forwarding mux makes 4-cycle spacing safe.
        //
        // Round-robin accumulation (5 accs):
        //   Element i -> acc[i%5]. Consecutive products for any acc are VEC_LEN/5
        //   cycles apart (>=4 for VEC_LEN>=4), no RAW hazard.
        //
        // Merge (u_merge, 6th fp32_acc):
        //   merge_clear pulsed in IDLE so u_merge starts at 0.
        //   merge_en (COMBINATIONAL) at drain_cnt 0,4,8,12,(NUM>=5)?16.
        //   4-cycle spacing uses fp32_acc forwarding mux (acc_en_d4->partial_sum_r).
        //   acc_en_d4 fires at DRAIN_EXIT_VAL; acc_reg written at the clock-edge
        //   that transitions to S_DONE, so merge_out is valid during S_DONE.
        
        /* verilator lint_off IMPORTSTAR */
        import lliu_pkg::*;
        /* verilator lint_on IMPORTSTAR */
        
        module dot_product_engine #(
            parameter int VEC_LEN = FEATURE_VEC_LEN
        )(
            input  logic      clk,
            input  logic      rst,
        
            // Feature input (streamed, one element per feature_valid pulse)
            input  bfloat16_t feature_in,
            input  logic      feature_valid,
        
            // Weight input (aligned with feature_in during STREAM)
            input  bfloat16_t weight_in,
        
            // Control
            input  logic      start,
        
            // Result
            output float32_t  result,
            output logic      result_valid
        );
        
            // -----------------------------------------------------------------------
            // FSM states
            // -----------------------------------------------------------------------
            typedef enum logic [1:0] {
                S_IDLE   = 2'b00,
                S_STREAM = 2'b01,
                S_DRAIN  = 2'b10,
                S_DONE   = 2'b11
            } state_t;
        
            state_t state;
        
            // -----------------------------------------------------------------------
            // Merge timing parameters
            // -----------------------------------------------------------------------
            localparam int NUM_ACCS_USED   = (VEC_LEN >= 5) ? 5 : VEC_LEN;
            localparam int MERGE_STEP      = 4;
            localparam int DRAIN_LAST_EN   = (NUM_ACCS_USED - 1) * MERGE_STEP;
            // DRAIN_EXIT_VAL: drain_cnt at which S_DRAIN->S_DONE.
            // merge_en_r (registered, +1 cycle) fires its last pulse at DRAIN_LAST_EN+1.
            // fp32_acc then needs 4 more cycles for acc_en_d4 to fire and write acc_reg.
            // So DRAIN_EXIT_VAL = DRAIN_LAST_EN + 1 + 4 = DRAIN_LAST_EN + 5.
            localparam logic [4:0] DRAIN_EXIT_VAL = DRAIN_LAST_EN[4:0] + 5'd4;
        
            // -----------------------------------------------------------------------
            // Control registers
            // -----------------------------------------------------------------------
            logic [$clog2(VEC_LEN+1)-1:0] mac_elem;
            logic [2:0]                    mac_drain;
            logic                          mac_last_fed;
            logic [4:0]                    drain_cnt;
        
            // -----------------------------------------------------------------------
            // bfloat16_mul -- single multiplier, 2-cycle latency
            // -----------------------------------------------------------------------
            bfloat16_t mul_a, mul_b;
            float32_t  mul_result;
        
            bfloat16_mul u_mul (
                .clk    (clk),
                .rst    (rst),
                .a      (mul_a),
                .b      (mul_b),
                .result (mul_result)
            );
        
            // Combinational inputs: feed feature_in/weight_in when dispatching.
 001890     always_comb begin
 001863         if (state == S_STREAM && !mac_last_fed && feature_valid) begin
 000027             mul_a = feature_in;
 000027             mul_b = weight_in;
 001863         end else begin
 001863             mul_a = 16'h0000;
 001863             mul_b = 16'h0000;
                end
            end
        
            // -----------------------------------------------------------------------
            // 5 parallel fp32_acc instances (round-robin)
            // -----------------------------------------------------------------------
            float32_t acc_addend [0:4];
            logic     acc_en_r   [0:4];
            logic     acc_clear;
            float32_t acc_out    [0:4];
        
            fp32_acc u_acc0 (.clk(clk),.rst(rst),.addend(acc_addend[0]),.acc_en(acc_en_r[0]),.acc_clear(acc_clear),.acc_out(acc_out[0]));
            fp32_acc u_acc1 (.clk(clk),.rst(rst),.addend(acc_addend[1]),.acc_en(acc_en_r[1]),.acc_clear(acc_clear),.acc_out(acc_out[1]));
            fp32_acc u_acc2 (.clk(clk),.rst(rst),.addend(acc_addend[2]),.acc_en(acc_en_r[2]),.acc_clear(acc_clear),.acc_out(acc_out[2]));
            fp32_acc u_acc3 (.clk(clk),.rst(rst),.addend(acc_addend[3]),.acc_en(acc_en_r[3]),.acc_clear(acc_clear),.acc_out(acc_out[3]));
            fp32_acc u_acc4 (.clk(clk),.rst(rst),.addend(acc_addend[4]),.acc_en(acc_en_r[4]),.acc_clear(acc_clear),.acc_out(acc_out[4]));
        
            // 3-stage shift register: routes mul_result to the correct acc[i].
            logic [$clog2(VEC_LEN+1)-1:0] mac_pipe_elem  [0:1];
            logic                          mac_pipe_valid [0:1];
        
%000001     always_comb begin
%000005         for (int i = 0; i < 5; i++) begin
%000005             acc_addend[i] = mul_result;
%000005             acc_en_r[i]   = mac_pipe_valid[1] && (int'(mac_pipe_elem[1]) % 5 == i);
                end
            end
        
            // -----------------------------------------------------------------------
            // Merge accumulator (6th fp32_acc)
            // -----------------------------------------------------------------------
            float32_t merge_addend;
            float32_t merge_addend_r;  // registered MUX output — eliminates 2 LUT levels
                                        // from the acc_out[3] → u_merge/addend routing
                                        // path (Run 27: was u_merge_i_42 + u_merge_i_8
                                        // adding 0.647 ns route + LUT delay before u_merge
                                        // Stage A0 combinational).  merge_en_r is delayed
                                        // by 1 cycle to stay aligned.
            logic     merge_en;    // COMBINATIONAL
            logic     merge_en_r;  // 1-cycle delayed (aligned with merge_addend_r)
            logic     merge_clear;
            float32_t merge_out;
        
            fp32_acc u_merge (
                .clk       (clk),
                .rst       (rst),
                .addend    (merge_addend_r),
                .acc_en    (merge_en_r),
                .acc_clear (merge_clear),
                .acc_out   (merge_out)
            );
        
 001890     always_comb begin
 001890         merge_addend = 32'h0000_0000;
 001816         if (drain_cnt == 5'd0)  merge_addend = acc_out[0];
~001887         if (drain_cnt == 5'd4)  merge_addend = acc_out[1];
~001887         if (drain_cnt == 5'd8)  merge_addend = acc_out[2];
~001887         if (drain_cnt == 5'd12) merge_addend = acc_out[3];
~001890         if (NUM_ACCS_USED >= 5 && drain_cnt == 5'd16) merge_addend = acc_out[4];
            end
        
            assign merge_en = (state == S_DRAIN) &&
                              (drain_cnt == 5'd0  || drain_cnt == 5'd4  ||
                               drain_cnt == 5'd8  || drain_cnt == 5'd12 ||
                               (NUM_ACCS_USED >= 5 && drain_cnt == 5'd16));
        
 001889     always_ff @(posedge clk) begin
 001809         if (rst) begin
 000080             merge_addend_r <= 32'h0000_0000;
 000080             merge_en_r     <= 1'b0;
 001809         end else begin
 001809             merge_addend_r <= merge_addend;
 001809             merge_en_r     <= merge_en;
                end
            end
        
            // -----------------------------------------------------------------------
            // Outputs -- combinational
            // -----------------------------------------------------------------------
            assign result_valid = (state == S_DONE);
            assign result       = merge_out;
        
            // -----------------------------------------------------------------------
            // FSM
            // -----------------------------------------------------------------------
 001889     always_ff @(posedge clk) begin
 001809         if (rst) begin
 000080             state              <= S_IDLE;
 000080             mac_elem           <= '0;
 000080             mac_drain          <= 3'd0;
 000080             mac_last_fed       <= 1'b0;
 000080             drain_cnt          <= 5'd0;
 000080             acc_clear          <= 1'b0;
 000080             merge_clear        <= 1'b0;
 000080             mac_pipe_elem[0]   <= '0;
 000080             mac_pipe_elem[1]   <= '0;
 000080             mac_pipe_valid[0]  <= 1'b0;
 000080             mac_pipe_valid[1]  <= 1'b0;
 001809         end else begin
 001809             acc_clear   <= 1'b0;
 001809             merge_clear <= 1'b0;
        
                    // Advance mul pipeline every cycle
 001809             mac_pipe_elem[1]  <= mac_pipe_elem[0];
 001809             mac_pipe_valid[1] <= mac_pipe_valid[0];
 001809             mac_pipe_elem[0]  <= '0;
 001809             mac_pipe_valid[0] <= 1'b0;
        
 001809             case (state)
        
 000140                 S_IDLE: begin
 000140                     mac_last_fed <= 1'b0;
~000132                     if (start) begin
%000008                         mac_elem    <= '0;
%000008                         mac_drain   <= 3'd0;
%000008                         acc_clear   <= 1'b1;
%000008                         state       <= S_STREAM;
                            end
                        end
        
                        // Feed feature_in/weight_in directly to mul each feature_valid.
                        // Stall (bubble) when !feature_valid.
                        // After last element (mac_elem==VEC_LEN-1), drain 6 cycles.
 001615                 S_STREAM: begin
 001597                     if (!mac_last_fed) begin
 001570                         if (feature_valid) begin
 000027                             mac_pipe_elem[0]  <= mac_elem;
 000027                             mac_pipe_valid[0] <= 1'b1;
~000024                             if (mac_elem == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1) begin
%000003                                 mac_last_fed <= 1'b1;
%000003                                 mac_drain    <= 3'd0;
 000024                             end else begin
 000024                                 mac_elem <= mac_elem + 1;
                                    end
                                end
                                // feature_valid=0: stall; pipe gets bubble via defaults above
 000018                     end else begin
~000015                         if (mac_drain == 3'd5) begin
%000003                             drain_cnt <= 5'd0;
%000003                             state     <= S_DRAIN;
 000015                         end else begin
 000015                             mac_drain <= mac_drain + 1;
                                end
                            end
                        end
        
                        // Merge acc_out[0..NUM_ACCS_USED-1] through u_merge.
                        // merge_en (comb) at drain_cnt 0,4,8,12,(NUM>=5)?16.
                        // Exit at DRAIN_EXIT_VAL when last acc_en_d4 fires.
 000051                 S_DRAIN: begin
 000051                     drain_cnt <= drain_cnt + 1;
~000048                     if (drain_cnt == DRAIN_EXIT_VAL) begin
%000003                         state <= S_DONE;
                            end
                        end
        
                        // result_valid=1 (combinational). Return to IDLE.
%000003                 S_DONE: begin
%000003                     state <= S_IDLE;
                        end
        
                        /* verilator coverage_off */
                        default: state <= S_IDLE;
                        /* verilator coverage_on */
        
                    endcase
                end
            end
        
        endmodule
        
