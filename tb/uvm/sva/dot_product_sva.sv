// dot_product_sva.sv — Dot-product engine FSM and computation assertions
//
// Bound into dot_product_engine to verify FSM safety and result validity.
//
// VEC_LEN must match the RTL parameter of the same name.  The timing property
// p_result_timing uses VEC_LEN+6 to account for:
//   • VEC_LEN multiply-accumulate cycles
//   • 1 cycle registered bfloat16_mul output (pipeline stage added by RTL plan)
//   • 1 cycle registered fp32_acc stage 1 (partial_sum_r)
//   • 1 cycle registered fp32_acc stage 2 (acc_reg)
//   • 2 cycles FSM overhead (DONE + DRAIN)
//   • 1 cycle slack

module dot_product_sva #(
    parameter int VEC_LEN = 8
) (
    input logic       clk,
    input logic       rst,
    input logic [1:0] state,
    input logic       start,
    input logic       result_valid,
    input logic       feature_valid,
    input logic       acc_clear
);

    // FSM state encoding (mirrors dot_product_engine.sv)
    localparam logic [1:0] S_IDLE    = 2'b00;
    localparam logic [1:0] S_COMPUTE = 2'b01;
    localparam logic [1:0] S_DONE    = 2'b10;
    localparam logic [1:0] S_DRAIN   = 2'b11;  // 5-cycle drain (drain_cnt 0→1→2→3→4)

    // ── D1: FSM must only be in valid states ────────────────────────
    property p_valid_state;
        @(posedge clk) disable iff (rst)
        (state == S_IDLE) || (state == S_COMPUTE) ||
        (state == S_DONE) || (state == S_DRAIN);
    endproperty
    assert property (p_valid_state)
        else $error("SVA: dot_product FSM in illegal state %0b", state);

    // ── D2: result_valid only in DONE state ─────────────────────────
    property p_result_in_done;
        @(posedge clk) disable iff (rst)
        result_valid |-> (state == S_DONE);
    endproperty
    assert property (p_result_in_done)
        else $error("SVA: result_valid asserted outside DONE state");

    // ── D3: DONE state lasts exactly one cycle ──────────────────────
    property p_done_one_cycle;
        @(posedge clk) disable iff (rst)
        (state == S_DONE) |=> (state != S_DONE);
    endproperty
    assert property (p_done_one_cycle)
        else $error("SVA: dot_product stuck in DONE state");

    // ── D4: Accumulator clears on start ─────────────────────────────
    property p_acc_clear_on_start;
        @(posedge clk) disable iff (rst)
        (start && state == S_IDLE) |-> acc_clear;
    endproperty
    assert property (p_acc_clear_on_start)
        else $error("SVA: accumulator not cleared on start");

    // ── D5: No result_valid without preceding start ─────────────────
    // COMPUTE must follow IDLE (which requires start)
    property p_compute_after_idle;
        @(posedge clk) disable iff (rst)
        (state == S_COMPUTE) |-> $past(state == S_IDLE || state == S_COMPUTE);
    endproperty
    assert property (p_compute_after_idle)
        else $error("SVA: COMPUTE entered from non-IDLE/COMPUTE state");

    // ── D6: Timing — start to result_valid ≤ VEC_LEN + 10 cycles ───
    // D6: VEC_LEN + 10
    //   VEC_LEN iterations (one element per cycle)
    //   + 2-cycle bfloat16_mul (Stage 1: DSP48E1 multiply, Stage 2: normalize)
    //   + 5-cycle drain: A0 (acc_en for penultimate), A1 (acc_en for last),
    //     A1→B (fp32_acc align), B→C (fp32_acc add/norm), C commit
    //   + 1 extra cycle for 2-stage feature_extractor pipeline
    // Guarded: Verilator 5.x does not support non-literal ##[N:M] range bounds.
    // This property is checked by VCS and Questa only.
`ifndef VERILATOR
    localparam int unsigned RESULT_TIMEOUT = VEC_LEN + 10;
    property p_result_timing;
        @(posedge clk) disable iff (rst)
        $rose(start) |-> ##[1:RESULT_TIMEOUT] result_valid;
    endproperty
    assert property (p_result_timing)
        else $error("SVA: result_valid did not assert within VEC_LEN+10 cycles of start");
`endif

endmodule
