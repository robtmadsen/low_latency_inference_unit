// moldupp64_sva.sv — Protocol assertions for moldupp64_strip
//
// Bound into moldupp64_strip via tb_top.sv (inside `ifdef MOLDUPP64_DUT).
// Spec ref: .github/arch/kintex-7/Kintex-7_MAS.md §2.3
//
// Properties that reference internal RTL signals (drop_state, header_done)
// require the RTL engineer to annotate those signals with (* keep = "true" *)
// or expose them as named output ports.  Until that coordination is done,
// those port inputs are tied to 0 in the bind statement — the affected
// properties simply never fire (no false failures).

`timescale 1ns/1ps

module moldupp64_sva (
    input logic        clk,
    input logic        rst,

    // DUT output status
    input logic        seq_valid,
    input logic [63:0] expected_seq_num,
    input logic [15:0] msg_count,

    // DUT AXI4-S input side (drive-side monitor)
    input logic        s_tvalid,

    // DUT AXI4-S output side
    input logic [63:0] m_tdata,
    input logic [7:0]  m_tkeep,
    input logic        m_tvalid,
    input logic        m_tlast,
    input logic        m_tready,

    // Internal RTL signals (require (* keep = "true" *) in RTL):
    //   drop_state    — FSM is in the S_DROP state (consuming an out-of-order datagram)
    //   header_done   — generated pulse on the cycle beat 2 is accepted (header parsed)
    // NOTE: RTL coordination with rtl_engineer required before these pins are populated.
    //       The bind statement in tb_top.sv ties them to 1'b0 until then.
    input logic        drop_state,   // 0 = stub; replace with RTL signal when available
    input logic        header_done   // 0 = stub; replace with RTL signal when available
);

    // ── M1: seq_valid is a single-cycle pulse ───────────────────────
    // Each accepted datagram triggers exactly one seq_valid pulse.
    property p_seq_valid_pulse;
        @(posedge clk) disable iff (rst)
        $rose(seq_valid) |=> !seq_valid;
    endproperty
    assert property (p_seq_valid_pulse)
        else $error("SVA [MOLDUPP64]: seq_valid asserted for more than 1 cycle");

    // ── M2: no output beats during drop state ───────────────────────
    // While the DUT is consuming a dropped datagram the output must be quiet.
    // Depends on internal drop_state signal — no-op when tied to 0 (stub).
    property p_no_output_on_drop;
        @(posedge clk) disable iff (rst)
        (drop_state && s_tvalid) |-> !m_tvalid;
    endproperty
    assert property (p_no_output_on_drop)
        else $error("SVA [MOLDUPP64]: m_tvalid asserted during drop state");

    // ── M3: expected_seq_num increments by msg_count after each accept
    // The cycle after seq_valid pulses, expected_seq_num = old + msg_count.
    property p_seq_advance;
        @(posedge clk) disable iff (rst)
        $rose(seq_valid) |=>
            (expected_seq_num == ($past(expected_seq_num) + $past(msg_count)));
    endproperty
    assert property (p_seq_advance)
        else $error("SVA [MOLDUPP64]: expected_seq_num did not advance by msg_count");

    // ── M4: header-to-output latency ≤ 4 cycles ────────────────────
    // From the cycle beat 2 is consumed (header_done pulse) the first
    // m_tvalid must appear within 4 cycles.
    // Depends on internal header_done signal — no-op when tied to 0 (stub).
    // Guarded for Verilator: non-literal ##[N:M] range not supported.
`ifndef VERILATOR
    property p_strip_latency;
        @(posedge clk) disable iff (rst)
        $rose(header_done) |-> ##[1:4] $rose(m_tvalid);
    endproperty
    assert property (p_strip_latency)
        else $error("SVA [MOLDUPP64]: strip latency > 4 cycles (beat-2 → m_tvalid)");
`endif

    // ── M5: AXI4-S output backpressure — no data loss on stall ─────
    // When m_tvalid is asserted but m_tready is deasserted, the DUT must
    // hold m_tdata and m_tkeep stable on the next cycle.
    property p_no_data_loss_on_stall;
        @(posedge clk) disable iff (rst)
        (m_tvalid && !m_tready) |=> (m_tvalid && $stable(m_tdata) && $stable(m_tkeep));
    endproperty
    assert property (p_no_data_loss_on_stall)
        else $error("SVA [MOLDUPP64]: m_tdata/m_tkeep changed while m_tvalid held under backpressure");

endmodule
