// dot_product_engine.sv — Pipelined MAC for small feature vectors
//
// Sequencing FSM: IDLE → COMPUTE (iterate over elements) → DRAIN → DONE
//
// Pipeline stages added for Kintex-7 300 MHz timing closure:
//   bfloat16_mul: 1 registered output cycle (P-register)
//   fp32_acc:     2-stage accumulator with forwarding mux
//
// Because bfloat16_mul has 1-cycle latency, acc_en is driven by
// feature_valid_d1 (1-cycle delayed from feature_valid).  After all
// VEC_LEN elements have been consumed, the FSM enters S_DRAIN for 2
// cycles to flush the remaining pipeline stages before asserting
// result_valid.  Total latency from first feature_valid to result_valid
// is 6 cycles at VEC_LEN = 4.

import lliu_pkg::*;

module dot_product_engine #(
    parameter int VEC_LEN = FEATURE_VEC_LEN
)(
    input  logic      clk,
    input  logic      rst,

    // Feature input (one element per cycle during COMPUTE)
    input  bfloat16_t feature_in,
    input  logic      feature_valid,

    // Weight input (one element per cycle from weight_mem)
    input  bfloat16_t weight_in,

    // Control
    input  logic      start,

    // Result
    output float32_t  result,
    output logic      result_valid
);

    // FSM states
    typedef enum logic [1:0] {
        S_IDLE    = 2'b00,
        S_COMPUTE = 2'b01,
        S_DRAIN   = 2'b10,
        S_DONE    = 2'b11
    } state_t;

    state_t state, state_next;
    logic [$clog2(VEC_LEN+1)-1:0] elem_cnt, elem_cnt_next;
    logic drain_cnt, drain_cnt_next; // 1-bit: counts 0 → 1 (2 DRAIN cycles)

    // feature_valid delayed by 1 cycle: used to assert acc_en after mul pipeline
    logic feature_valid_d1;

    // bfloat16_mul instance signals
    bfloat16_t mul_a, mul_b;
    float32_t  mul_result;

    bfloat16_mul u_mul (
        .clk    (clk),
        .rst    (rst),
        .a      (mul_a),
        .b      (mul_b),
        .result (mul_result)
    );

    // fp32_acc instance signals
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

    // Combinational datapath
    assign mul_a      = feature_in;
    assign mul_b      = weight_in;
    assign acc_addend = mul_result;

    // FSM next state — acc_en drives fp32_acc 1 cycle after feature_valid
    always_comb begin
        state_next     = state;
        elem_cnt_next  = elem_cnt;
        drain_cnt_next = drain_cnt;
        acc_en         = 1'b0;
        acc_clear      = 1'b0;
        result_valid   = 1'b0;

        case (state)
            S_IDLE: begin
                if (start) begin
                    state_next     = S_COMPUTE;
                    elem_cnt_next  = '0;
                    drain_cnt_next = 1'b0;
                    acc_clear      = 1'b1;
                end
            end

            S_COMPUTE: begin
                // acc_en fires on delayed feature_valid (1 cycle after mul input)
                if (feature_valid_d1) begin
                    acc_en = 1'b1;
                end
                // elem_cnt advances on the raw feature_valid
                if (feature_valid) begin
                    elem_cnt_next = elem_cnt + 1;
                    if (elem_cnt == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1) begin
                        state_next     = S_DRAIN;
                        drain_cnt_next = 1'b0;
                    end
                end
            end

            S_DRAIN: begin
                // drain_cnt=0: fire acc_en for the last element's mul output
                // (feature_valid_d1 is still 1 from the last COMPUTE cycle)
                if (drain_cnt == 1'b0) begin
                    if (feature_valid_d1) begin
                        acc_en = 1'b1;
                    end
                    drain_cnt_next = 1'b1;
                end else begin
                    // drain_cnt=1: Stage 2 of fp32_acc captures final sum this cycle;
                    // result will be stable in acc_reg when we enter S_DONE.
                    state_next = S_DONE;
                end
            end

            S_DONE: begin
                result_valid = 1'b1;
                state_next   = S_IDLE;
            end

            /* verilator coverage_off */
            default: begin
                state_next = S_IDLE;
            end
            /* verilator coverage_on */
        endcase
    end

    // FSM registers
    always_ff @(posedge clk) begin
        if (rst) begin
            state             <= S_IDLE;
            elem_cnt          <= '0;
            drain_cnt         <= 1'b0;
            feature_valid_d1  <= 1'b0;
        end else begin
            state    <= state_next;
            elem_cnt <= elem_cnt_next;
            drain_cnt <= drain_cnt_next;
            // feature_valid_d1: register feature_valid when in COMPUTE state so
            // acc_en fires one cycle after the mul input is presented
            feature_valid_d1 <= (state == S_COMPUTE) && feature_valid;
        end
    end

    assign result = acc_out;

endmodule
