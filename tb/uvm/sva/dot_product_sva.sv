// dot_product_sva.sv — Dot-product engine FSM and computation assertions
//
// Bound into dot_product_engine to verify FSM safety and result validity.

module dot_product_sva (
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

    // ── D1: FSM must only be in valid states ────────────────────────
    property p_valid_state;
        @(posedge clk) disable iff (rst)
        (state == S_IDLE) || (state == S_COMPUTE) || (state == S_DONE);
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

endmodule
