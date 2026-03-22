// axi4_stream_if.sv — AXI4-Stream interface for UVM testbench
//
// 64-bit data bus, big-endian byte order per ITCH market data ingress.
// Clocking blocks provide synchronous access for UVM drivers and monitors.

interface axi4_stream_if (
    input logic clk,
    input logic rst
);

    logic [63:0] tdata;
    logic        tvalid;
    logic        tready;
    logic        tlast;

    // Driver clocking block — drives tdata, tvalid, tlast; samples tready
    clocking driver_cb @(posedge clk);
        default input #1step output #0;
        output tdata;
        output tvalid;
        output tlast;
        input  tready;
    endclocking

    // Monitor clocking block — all inputs
    clocking monitor_cb @(posedge clk);
        default input #1step;
        input tdata;
        input tvalid;
        input tready;
        input tlast;
    endclocking

    // Driver modport
    modport DRIVER (
        clocking driver_cb,
        input    rst
    );

    // Monitor modport
    modport MONITOR (
        clocking monitor_cb,
        input    rst
    );

    // DUT modport (directly connected to DUT ports)
    modport DUT (
        input  tdata,
        input  tvalid,
        output tready,
        input  tlast
    );

endinterface
