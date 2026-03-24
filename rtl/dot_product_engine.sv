// dot_product_engine.sv — Pipelined MAC for small feature vectors
//
// Sequencing FSM: IDLE → COMPUTE (iterate over elements) → DONE
// Instantiates bfloat16_mul and fp32_acc.

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
        S_DONE    = 2'b10
    } state_t;

    state_t state, state_next;
    logic [$clog2(VEC_LEN+1)-1:0] elem_cnt, elem_cnt_next;

    // bfloat16_mul instance signals
    bfloat16_t mul_a, mul_b;
    float32_t  mul_result;

    bfloat16_mul u_mul (
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
    assign mul_a     = feature_in;
    assign mul_b     = weight_in;
    assign acc_addend = mul_result;

    // FSM next state
    always_comb begin
        state_next    = state;
        elem_cnt_next = elem_cnt;
        acc_en        = 1'b0;
        acc_clear     = 1'b0;
        result_valid  = 1'b0;

        case (state)
            S_IDLE: begin
                if (start) begin
                    state_next    = S_COMPUTE;
                    elem_cnt_next = '0;
                    acc_clear     = 1'b1;
                end
            end

            S_COMPUTE: begin
                if (feature_valid) begin
                    acc_en = 1'b1;
                    elem_cnt_next = elem_cnt + 1;
                    if (elem_cnt == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1) begin
                        state_next = S_DONE;
                    end
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
            state    <= S_IDLE;
            elem_cnt <= '0;
        end else begin
            state    <= state_next;
            elem_cnt <= elem_cnt_next;
        end
    end

    assign result = acc_out;

endmodule
