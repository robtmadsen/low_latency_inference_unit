// axi4_stream_sva.sv — AXI4-Stream protocol compliance assertions
//
// Bound into the DUT at the AXI4-Stream slave interface.
// Checks AXI4-Stream handshake rules per ARM IHI 0051B.

module axi4_stream_sva (
    input logic        clk,
    input logic        rst,
    input logic [63:0] tdata,
    input logic        tvalid,
    input logic        tready,
    input logic        tlast
);

    // ── A1: tvalid must not deassert without handshake ──────────────
    // Once asserted, tvalid must remain high until tready completes
    // the transfer.  Exception: tvalid may deassert the cycle immediately
    // after a completed handshake (tvalid && tready) — the slave may
    // briefly deassert tready (e.g. S_EMIT state) on that same cycle.
    property p_tvalid_stable;
        @(posedge clk) disable iff (rst)
        (tvalid && !tready && !$past(tvalid && tready)) |=> tvalid;
    endproperty
    assert property (p_tvalid_stable)
        else $error("SVA: tvalid deasserted without tready handshake");

    // ── A2: tdata must be stable while tvalid && !tready ────────────
    property p_tdata_stable;
        @(posedge clk) disable iff (rst)
        (tvalid && !tready && !$past(tvalid && tready)) |=> ($stable(tdata));
    endproperty
    assert property (p_tdata_stable)
        else $error("SVA: tdata changed while tvalid held without tready");

    // ── A3: tlast must be stable while tvalid && !tready ────────────
    property p_tlast_stable;
        @(posedge clk) disable iff (rst)
        (tvalid && !tready && !$past(tvalid && tready)) |=> ($stable(tlast));
    endproperty
    assert property (p_tlast_stable)
        else $error("SVA: tlast changed while tvalid held without tready");

endmodule
