// axi4_lite_if.sv — AXI4-Lite interface for UVM testbench
//
// 8-bit address, 32-bit data, matching lliu_top control plane.

interface axi4_lite_if #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
)(
    input logic clk,
    input logic rst
);

    // Write Address channel
    logic [ADDR_WIDTH-1:0]   awaddr;
    logic                    awvalid;
    logic                    awready;

    // Write Data channel
    logic [DATA_WIDTH-1:0]   wdata;
    logic [DATA_WIDTH/8-1:0] wstrb;
    logic                    wvalid;
    logic                    wready;

    // Write Response channel
    logic [1:0]              bresp;
    logic                    bvalid;
    logic                    bready;

    // Read Address channel
    logic [ADDR_WIDTH-1:0]   araddr;
    logic                    arvalid;
    logic                    arready;

    // Read Data channel
    logic [DATA_WIDTH-1:0]   rdata;
    logic [1:0]              rresp;
    logic                    rvalid;
    logic                    rready;

    // Driver clocking block
    clocking driver_cb @(posedge clk);
        default input #1step output #0;
        // Write Address
        output awaddr;
        output awvalid;
        input  awready;
        // Write Data
        output wdata;
        output wstrb;
        output wvalid;
        input  wready;
        // Write Response
        input  bresp;
        input  bvalid;
        output bready;
        // Read Address
        output araddr;
        output arvalid;
        input  arready;
        // Read Data
        input  rdata;
        input  rresp;
        input  rvalid;
        output rready;
    endclocking

    // Monitor clocking block
    clocking monitor_cb @(posedge clk);
        default input #1step;
        input awaddr;
        input awvalid;
        input awready;
        input wdata;
        input wstrb;
        input wvalid;
        input wready;
        input bresp;
        input bvalid;
        input bready;
        input araddr;
        input arvalid;
        input arready;
        input rdata;
        input rresp;
        input rvalid;
        input rready;
    endclocking

    // Modports
    modport DRIVER (
        clocking driver_cb,
        input    rst
    );

    modport MONITOR (
        clocking monitor_cb,
        input    rst
    );

    modport DUT (
        input  awaddr, awvalid,
        output awready,
        input  wdata, wstrb, wvalid,
        output wready,
        output bresp, bvalid,
        input  bready,
        input  araddr, arvalid,
        output arready,
        output rdata, rresp, rvalid,
        input  rready
    );

endinterface
