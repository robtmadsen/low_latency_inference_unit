// tb_top.sv — Top-level testbench for itch_field_extract UVM environment
`include "uvm_macros.svh"

module tb_top;
    import uvm_pkg::*;
    import itch_tb_pkg::*;

    // Clock generation: 10 ns period (100 MHz)
    logic clk = 0;
    initial forever #5 clk = ~clk;

    // Interface — signals default to 0 via --x-initial 0; the UVM driver is
    // the single writer of all stimulus signals to avoid Verilator
    // multi-driver issues.
    itch_if vif (.clk(clk));

    // DUT
    itch_field_extract dut (
        .clk          (clk),
        .rst          (vif.rst),
        .msg_data     (vif.msg_data),
        .msg_valid    (vif.msg_valid),
        .message_type (vif.message_type),
        .order_ref    (vif.order_ref),
        .side         (vif.side),
        .price        (vif.price),
        .stock        (vif.stock),
        .fields_valid (vif.fields_valid)
    );

    initial begin
        uvm_config_db #(virtual itch_if)::set(null, "*", "vif", vif);
        run_test();
    end

    // Watchdog
    initial begin
        #100000;  // 10 us — plenty for any of the small tests
        `uvm_fatal("TB_TOP", "Watchdog: simulation hung")
    end
endmodule
