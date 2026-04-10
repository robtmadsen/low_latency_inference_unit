// dot_product_engine.sv — Pipelined MAC for small feature vectors
//
// Sequencing FSM: IDLE → COLLECT (buffer VEC_LEN elements) → MAC → DRAIN → DONE
//
// Pipeline stages:
//   bfloat16_mul: 2-cycle latency (Stage 1: DSP48E1 multiply, Stage 2: normalize)
//   fp32_acc:     5-stage pipeline (A0 → A1 → B1 → B2 → C); acc_reg updated 4 cycles
//                 after acc_en. Forwarding mux: acc_fb = acc_en_d4 ? partial_sum_r : acc_reg
//
// BUG-001 fix: sequential per-element MAC with 7-cycle slot per element.
//   For each element k: assert mul_en (present to bfloat16_mul) on cycle k*7 of the MAC
//   phase. acc_en fires 2 cycles later (cycle k*7+2). fp32_acc propagates result through
//   all 5 stages by cycle k*7+6 (acc_reg holds sum[0..k]).  Element k+1 enters Stage A0
//   on cycle (k+1)*7+2 at which point acc_en_d4 = 0 and acc_reg is fully settled.
//   This avoids the RAW hazard: every element correctly reads acc_reg, not partial_sum_r.
//
//   Total latency from first feature_valid: COLLECT (VEC_LEN cycles) + MAC
//   (VEC_LEN * 7 cycles) + DRAIN (5 cycles) = 4 + 28 + 5 = 37 cycles for VEC_LEN = 4.
//   Throughput: one dp_result per 37 cycles (still 1 message/burst; no throughput loss
//   because upstream issues one burst per ITCH message, not back-to-back continuous).

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module dot_product_engine #(
    parameter int VEC_LEN = FEATURE_VEC_LEN
)(
    input  logic      clk,
    input  logic      rst,

    // Feature input (one element per cycle during COLLECT)
    input  bfloat16_t feature_in,
    input  logic      feature_valid,

    // Weight input (one element per cycle from weight_mem, aligned with feature_in)
    input  bfloat16_t weight_in,

    // Control
    input  logic      start,

    // Result
    output float32_t  result,
    output logic      result_valid
);

    // FSM states
    typedef enum logic [2:0] {
        S_IDLE    = 3'b000,
        S_COLLECT = 3'b001,   // buffer all VEC_LEN (feature, weight) pairs
        S_MAC     = 3'b010,   // sequential per-element multiply-accumulate
        S_DRAIN   = 3'b011,   // flush last element through fp32_acc pipeline
        S_DONE    = 3'b100
    } state_t;

    state_t state;

    // ----------------------------------------------------------------------
    // Input buffers — hold all VEC_LEN elements during COLLECT
    // ----------------------------------------------------------------------
    bfloat16_t feat_buf  [0:VEC_LEN-1];
    bfloat16_t wt_buf    [0:VEC_LEN-1];
    logic [$clog2(VEC_LEN+1)-1:0] collect_cnt; // counts received elements
    logic [$clog2(VEC_LEN+1)-1:0] mac_elem;    // current element index in MAC phase
    logic [2:0] slot_cnt;  // 7-cycle slot counter within each element (0-6)
    logic [2:0] drain_cnt; // 5-cycle drain counter (0-4)

    // ----------------------------------------------------------------------
    // bfloat16_mul instance
    // ----------------------------------------------------------------------
    bfloat16_t mul_a, mul_b;
    float32_t  mul_result;

    bfloat16_mul u_mul (
        .clk    (clk),
        .rst    (rst),
        .a      (mul_a),
        .b      (mul_b),
        .result (mul_result)
    );

    // ----------------------------------------------------------------------
    // fp32_acc instance
    // ----------------------------------------------------------------------
    float32_t acc_addend;
    logic     acc_en;
    logic     acc_clear;
    float32_t acc_out;

    fp32_acc u_acc (
        .clk       (clk),
        .rst       (rst),
        .addend    (acc_addend),
        .acc_en    (acc_en),
        .acc_clear (acc_clear),
        .acc_out   (acc_out)
    );

    // In S_MAC, slot_cnt == 0: drive this element to bfloat16_mul.
    // bfloat16_mul result is available 2 cycles later (slot_cnt == 2).
    // Present the buffered element at the mul inputs continuously so it is
    // registered at the right time.
    always_comb begin
        mul_a = (state == S_MAC) ? feat_buf[mac_elem[$clog2(VEC_LEN)-1:0]] : 16'h0000;
        mul_b = (state == S_MAC) ? wt_buf[mac_elem[$clog2(VEC_LEN)-1:0]]   : 16'h0000;
    end

    assign acc_addend = mul_result;

    // ----------------------------------------------------------------------
    // FSM
    // ----------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            state        <= S_IDLE;
            collect_cnt  <= '0;
            mac_elem     <= '0;
            slot_cnt     <= 3'd0;
            drain_cnt    <= 3'd0;
            acc_en       <= 1'b0;
            acc_clear    <= 1'b0;
            result_valid <= 1'b0;
        end else begin
            // Default deasserts (registered outputs)
            acc_en       <= 1'b0;
            acc_clear    <= 1'b0;
            result_valid <= 1'b0;

            case (state)

                // ----------------------------------------------------------------
                S_IDLE: begin
                    if (start) begin
                        collect_cnt <= '0;
                        acc_clear   <= 1'b1;
                        state       <= S_COLLECT;
                    end
                end

                // ----------------------------------------------------------------
                // S_COLLECT: accept VEC_LEN (feature, weight) pairs on
                // consecutive feature_valid cycles and store them in buffers.
                // ----------------------------------------------------------------
                S_COLLECT: begin
                    if (feature_valid) begin
                        feat_buf[collect_cnt[$clog2(VEC_LEN)-1:0]] <= feature_in;
                        wt_buf[collect_cnt[$clog2(VEC_LEN)-1:0]]   <= weight_in;
                        if (collect_cnt == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1) begin
                            collect_cnt <= '0;
                            mac_elem    <= '0;
                            slot_cnt    <= 3'd0;
                            state       <= S_MAC;
                        end else begin
                            collect_cnt <= collect_cnt + 1;
                        end
                    end
                end

                // ----------------------------------------------------------------
                // S_MAC: sequentially process each buffered element.
                //
                // 7-cycle slot per element:
                //   slot 0: mul_a/mul_b driven (bfloat16_mul Stage 1 samples inputs)
                //   slot 1: bfloat16_mul Stage 2 (normalize)
                //   slot 2: acc_en pulse (mul_result ready → fp32_acc Stage A0)
                //   slot 3: fp32_acc Stage A1 (alignment)
                //   slot 4: fp32_acc Stage B1 (adder)
                //   slot 5: fp32_acc Stage B2 (normalise → partial_sum_r)
                //   slot 6: fp32_acc Stage C  (partial_sum_r → acc_reg)
                //   → acc_reg holds cumulative sum[0..mac_elem] after slot 6.
                //
                // The forwarding mux (acc_fb = acc_en_d4 ? partial_sum_r : acc_reg)
                // is irrelevant here because the next acc_en fires at the start of the
                // next 7-cycle slot (acc_en_d4 from step k is 0 at the time step k+1
                // enters Stage A0; acc_reg is fully settled).
                // ----------------------------------------------------------------
                S_MAC: begin
                    case (slot_cnt)
                        3'd0: begin
                            // mul inputs already muxed combinatorially for mac_elem
                            slot_cnt <= 3'd1;
                        end
                        3'd1: begin
                            slot_cnt <= 3'd2;
                        end
                        3'd2: begin
                            // mul_result is valid; feed fp32_acc
                            acc_en   <= 1'b1;
                            slot_cnt <= 3'd3;
                        end
                        3'd3: slot_cnt <= 3'd4;
                        3'd4: slot_cnt <= 3'd5;
                        3'd5: slot_cnt <= 3'd6;
                        3'd6: begin
                            // acc_reg now holds sum[0..mac_elem]
                            if (mac_elem == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1) begin
                                // Last element committed — fp32_acc Stage C already fired.
                                // No additional drain needed: result is in acc_reg.
                                state <= S_DONE;
                            end else begin
                                mac_elem <= mac_elem + 1;
                                slot_cnt <= 3'd0;
                            end
                        end
                        /* verilator coverage_off */
                        default: slot_cnt <= 3'd0;
                        /* verilator coverage_on */
                    endcase
                end

                // ----------------------------------------------------------------
                S_DRAIN: begin
                    // Unused with the sequential MAC approach (kept for completeness).
                    if (drain_cnt == 3'd4) begin
                        state     <= S_DONE;
                        drain_cnt <= 3'd0;
                    end else begin
                        drain_cnt <= drain_cnt + 1;
                    end
                end

                // ----------------------------------------------------------------
                S_DONE: begin
                    result_valid <= 1'b1;
                    state        <= S_IDLE;
                end

                /* verilator coverage_off */
                default: state <= S_IDLE;
                /* verilator coverage_on */

            endcase
        end
    end

    assign result = acc_out;

endmodule
