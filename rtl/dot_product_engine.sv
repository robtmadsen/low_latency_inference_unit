// dot_product_engine.sv — Pipelined MAC for small feature vectors
//
// Sequencing FSM: IDLE → COMPUTE (iterate over elements) → DRAIN → DONE
//
// Pipeline stages added for Kintex-7 300 MHz timing closure:
//   bfloat16_mul: 2 registered output cycles (Stage 1: DSP48E1 multiply, Stage 2: normalize)
//   fp32_acc:     4-stage accumulator (Stage A0: exp compare, Stage A1: align, Stage B: add/norm, Stage C: commit)
//
// Because bfloat16_mul has 2-cycle latency, acc_en is driven by
// feature_valid_d2 (2-cycle delayed from feature_valid).  After all
// VEC_LEN elements have been consumed, the FSM enters S_DRAIN for 6
// cycles (drain_cnt 0→5) to flush the 5-stage fp32_acc pipeline before
// asserting result_valid.  Total latency from first feature_valid to
// result_valid is VEC_LEN + 6 cycles at VEC_LEN = 4.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

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
    logic [2:0] drain_cnt, drain_cnt_next; // 3-bit: counts 0 → 1 → 2 → 3 → 4 → 5 (6 DRAIN cycles)

    // feature_valid delayed by 1 and 2 cycles: used to assert acc_en after 2-cycle mul pipeline
    logic feature_valid_d1;
    logic feature_valid_d2;

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
                    drain_cnt_next = 3'd0;
                    acc_clear      = 1'b1;
                end
            end

            S_COMPUTE: begin
                // acc_en fires on delayed feature_valid (2 cycles after mul input)
                if (feature_valid_d2) begin
                    acc_en = 1'b1;
                end
                // elem_cnt advances on the raw feature_valid
                if (feature_valid) begin
                    elem_cnt_next = elem_cnt + 1;
                    if (elem_cnt == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1) begin
                        state_next     = S_DRAIN;
                        drain_cnt_next = 3'd0;
                    end
                end
            end

            S_DRAIN: begin
                // drain_cnt=0: bfloat16_mul Stage 2 still computing (man_product_r → normalize).
                // feature_valid_d2 is 1 here for the penultimate element;
                // acc_en fires to feed the penultimate element into fp32_acc.
                if (drain_cnt == 3'd0) begin
                    if (feature_valid_d2) begin
                        acc_en = 1'b1;
                    end
                    drain_cnt_next = 3'd1;
                end else if (drain_cnt == 3'd1) begin
                    // Last element's bfloat16_mul result arrives; feed into fp32_acc.
                    if (feature_valid_d2) begin
                        acc_en = 1'b1;
                    end
                    drain_cnt_next = 3'd2;
                end else if (drain_cnt == 3'd2) begin
                    // Stage A1 of fp32_acc (alignment) fires this cycle.
                    drain_cnt_next = 3'd3;
                end else if (drain_cnt == 3'd3) begin
                    // Stage B1 of fp32_acc (raw adder sum registered) fires this cycle.
                    drain_cnt_next = 3'd4;
                end else if (drain_cnt == 3'd4) begin
                    // Stage B2 of fp32_acc (normalize → partial_sum_r) fires this cycle.
                    drain_cnt_next = 3'd5;
                end else begin
                    // drain_cnt=5: Stage C of fp32_acc commits final sum;
                    // acc_reg stable on entry to S_DONE.
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
            drain_cnt         <= 3'd0;
            feature_valid_d1  <= 1'b0;
            feature_valid_d2  <= 1'b0;
        end else begin
            state    <= state_next;
            elem_cnt <= elem_cnt_next;
            drain_cnt <= drain_cnt_next;
            // feature_valid_d1/d2: pipeline feature_valid for 2-cycle bfloat16_mul latency
            feature_valid_d1 <= (state == S_COMPUTE) && feature_valid;
            feature_valid_d2 <= feature_valid_d1;
        end
    end

    assign result = acc_out;

endmodule
