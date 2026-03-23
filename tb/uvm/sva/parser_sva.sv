// parser_sva.sv — ITCH parser FSM safety assertions
//
// Bound into itch_parser to verify FSM integrity and bounded latency.

module parser_sva (
    input logic        clk,
    input logic        rst,
    input logic [1:0]  state,
    input logic        s_axis_tvalid,
    input logic        s_axis_tready,
    input logic        msg_valid,
    input logic        fields_valid
);

    // FSM state encoding (mirrors itch_parser.sv)
    localparam logic [1:0] S_IDLE       = 2'b00;
    localparam logic [1:0] S_ACCUMULATE = 2'b01;
    localparam logic [1:0] S_EMIT       = 2'b10;

    // ── P1: FSM must only be in valid states ────────────────────────
    property p_valid_state;
        @(posedge clk) disable iff (rst)
        (state == S_IDLE) || (state == S_ACCUMULATE) || (state == S_EMIT);
    endproperty
    assert property (p_valid_state)
        else $error("SVA: parser FSM in illegal state %0b", state);

    // ── P2: EMIT state lasts exactly one cycle ──────────────────────
    property p_emit_one_cycle;
        @(posedge clk) disable iff (rst)
        (state == S_EMIT) |=> (state != S_EMIT);
    endproperty
    assert property (p_emit_one_cycle)
        else $error("SVA: parser stuck in EMIT state");

    // ── P3: No stuck in ACCUMULATE — bounded cycles ─────────────────
    // Parser must leave ACCUMULATE within 20 cycles (max msg ~128 bytes / 8 = 16 beats)
    // Note: ##[1:N] range delay is VCS/Questa-only. For open-source sim,
    // use a counter-based watchdog instead.
    int unsigned accum_cnt;
    always_ff @(posedge clk) begin
        if (rst || state != S_ACCUMULATE)
            accum_cnt <= 0;
        else
            accum_cnt <= accum_cnt + 1;
    end

    property p_accumulate_bounded;
        @(posedge clk) disable iff (rst)
        (state == S_ACCUMULATE) |-> (accum_cnt <= 20);
    endproperty
    assert property (p_accumulate_bounded)
        else $error("SVA: parser stuck in ACCUMULATE > 20 cycles");

    // ── P4: msg_valid only in EMIT state ────────────────────────────
    property p_msg_valid_in_emit;
        @(posedge clk) disable iff (rst)
        msg_valid |-> (state == S_EMIT);
    endproperty
    assert property (p_msg_valid_in_emit)
        else $error("SVA: msg_valid asserted outside EMIT state");

endmodule
