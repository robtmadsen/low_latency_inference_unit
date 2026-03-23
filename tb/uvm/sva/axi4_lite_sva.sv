// axi4_lite_sva.sv — AXI4-Lite protocol compliance assertions
//
// Bound into the DUT at the AXI4-Lite slave interface.
// Checks handshake stability per ARM IHI 0022E.

module axi4_lite_sva (
    input logic        clk,
    input logic        rst,

    // Write Address channel
    input logic [7:0]  awaddr,
    input logic        awvalid,
    input logic        awready,

    // Write Data channel
    input logic [31:0] wdata,
    input logic [3:0]  wstrb,
    input logic        wvalid,
    input logic        wready,

    // Write Response channel
    input logic [1:0]  bresp,
    input logic        bvalid,
    input logic        bready,

    // Read Address channel
    input logic [7:0]  araddr,
    input logic        arvalid,
    input logic        arready,

    // Read Data channel
    input logic [31:0] rdata,
    input logic [1:0]  rresp,
    input logic        rvalid,
    input logic        rready
);

    // ── Write Address channel stability ─────────────────────────────
    property p_awvalid_stable;
        @(posedge clk) disable iff (rst)
        (awvalid && !awready) |=> awvalid;
    endproperty
    assert property (p_awvalid_stable)
        else $error("SVA: awvalid deasserted without awready");

    property p_awaddr_stable;
        @(posedge clk) disable iff (rst)
        (awvalid && !awready) |=> ($stable(awaddr));
    endproperty
    assert property (p_awaddr_stable)
        else $error("SVA: awaddr changed while awvalid held without awready");

    // ── Write Data channel stability ────────────────────────────────
    property p_wvalid_stable;
        @(posedge clk) disable iff (rst)
        (wvalid && !wready) |=> wvalid;
    endproperty
    assert property (p_wvalid_stable)
        else $error("SVA: wvalid deasserted without wready");

    property p_wdata_stable;
        @(posedge clk) disable iff (rst)
        (wvalid && !wready) |=> ($stable(wdata));
    endproperty
    assert property (p_wdata_stable)
        else $error("SVA: wdata changed while wvalid held without wready");

    // ── Write Response channel stability ────────────────────────────
    property p_bvalid_stable;
        @(posedge clk) disable iff (rst)
        (bvalid && !bready) |=> bvalid;
    endproperty
    assert property (p_bvalid_stable)
        else $error("SVA: bvalid deasserted without bready");

    // ── Read Address channel stability ──────────────────────────────
    property p_arvalid_stable;
        @(posedge clk) disable iff (rst)
        (arvalid && !arready) |=> arvalid;
    endproperty
    assert property (p_arvalid_stable)
        else $error("SVA: arvalid deasserted without arready");

    property p_araddr_stable;
        @(posedge clk) disable iff (rst)
        (arvalid && !arready) |=> ($stable(araddr));
    endproperty
    assert property (p_araddr_stable)
        else $error("SVA: araddr changed while arvalid held without arready");

    // ── Read Data channel stability ─────────────────────────────────
    property p_rvalid_stable;
        @(posedge clk) disable iff (rst)
        (rvalid && !rready) |=> rvalid;
    endproperty
    assert property (p_rvalid_stable)
        else $error("SVA: rvalid deasserted without rready");

endmodule
