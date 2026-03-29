// drop_on_full_sva.sv — Protocol assertions for eth_axis_rx_wrap
//
// Bound into eth_axis_rx_wrap via tb_top.sv (inside `ifdef DROPFULL_DUT).
// Spec ref: .github/arch/kintex-7/Kintex-7_MAS.md §4.1
//
// Critical invariant: mac_rx_tready must NEVER deassert (MAC back-pressure
// is forbidden; eth_axis_rx_wrap always accepts and drops whole frames when
// the downstream FIFO is full).
//
// Properties that reference internal RTL signals (drop_current, frame_active)
// require (* keep = "true" *) annotations in RTL.  Those inputs are tied to
// stubs (1'b0) in the bind statement until RTL coordination is complete.

`timescale 1ns/1ps

module drop_on_full_sva (
    input logic        clk,
    input logic        rst,

    // DUT I/O (all module-level ports — always available in bind context)
    input logic        mac_rx_tvalid,
    input logic        mac_rx_tlast,
    input logic        mac_rx_tready,   // DUT output — must always be 1

    input logic        eth_payload_tvalid,
    input logic        fifo_almost_full,

    input logic [31:0] dropped_frames,

    // Internal RTL signals (requires (* keep = "true" *)):
    //   drop_current   — frame is being discarded this cycle
    //   frame_active   — DUT is inside a frame (between sof and eof)
    // Tied to 1'b0 in bind statement until RTL coordinates annotation.
    input logic        drop_current,    // 0 = stub
    input logic        frame_active     // 0 = stub
);

    // ── D1: MAC can never be stalled ───────────────────────────────
    // mac_rx_tready must be constantly asserted — the DUT drops frames
    // instead of applying back-pressure to the MAC.
    property p_mac_tready_never_low;
        @(posedge clk) disable iff (rst)
        mac_rx_tready === 1'b1;
    endproperty
    assert property (p_mac_tready_never_low)
        else $error("SVA [DROPFULL]: mac_rx_tready deasserted — MAC must never be stalled");

    // ── D2: frame drop is atomic — no partial frames on output ─────
    // If DUT is dropping the current frame, eth_payload_tvalid must be 0.
    // Depends on internal drop_current signal (stub = no-op).
    property p_no_partial_frame;
        @(posedge clk) disable iff (rst)
        drop_current |-> !eth_payload_tvalid;
    endproperty
    assert property (p_no_partial_frame)
        else $error("SVA [DROPFULL]: eth_payload_tvalid during frame drop");

    // ── D3: drop decision is frame-granular ─────────────────────────
    // Once a frame begins being dropped, drop_current stays asserted
    // until mac_rx_tlast (EOF) is seen.
    // Depends on internal frame_active and drop_current signals.
    property p_drop_stable_mid_frame;
        @(posedge clk) disable iff (rst)
        (frame_active && drop_current) |=> (drop_current || mac_rx_tlast);
    endproperty
    assert property (p_drop_stable_mid_frame)
        else $error("SVA [DROPFULL]: drop_current changed mid-frame");

    // ── D4: dropped_frames counter is monotonically non-decreasing ─
    property p_counter_monotonic;
        @(posedge clk) disable iff (rst)
        dropped_frames >= $past(dropped_frames);
    endproperty
    assert property (p_counter_monotonic)
        else $error("SVA [DROPFULL]: dropped_frames counter decreased (rollback)");

    // ── D5: counter increments by exactly 1 per dropped frame ──────
    // On the cycle of each dropped frame's EOF, the counter increments
    // by 1 (or saturates at 32'hFFFF_FFFF).
    property p_counter_increment;
        @(posedge clk) disable iff (rst)
        ($rose(mac_rx_tlast) && drop_current) |=>
            (dropped_frames == $past(dropped_frames) + 32'd1 ||
             dropped_frames == 32'hFFFF_FFFF);
    endproperty
    assert property (p_counter_increment)
        else $error("SVA [DROPFULL]: dropped_frames did not increment by 1 on frame drop");

endmodule
