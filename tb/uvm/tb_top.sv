// tb_top.sv — UVM testbench top-level
//
// Instantiates clock, reset, DUT, interfaces, and launches UVM test.

`timescale 1ns/1ps

// ----------------------------------------------------------------
// $unit-scope imports
// ----------------------------------------------------------------
`include "uvm_macros.svh"
import uvm_pkg::*;
import lliu_pkg::*;
import axi4_stream_agent_pkg::*;
import axi4_lite_agent_pkg::*;
import lliu_env_pkg::*;
import lliu_seq_pkg::*;
import lliu_test_pkg::*;

module tb_top;

    // ----------------------------------------------------------------
    // Clock generation — 300 MHz (3.33 ns period)
    // ----------------------------------------------------------------
    localparam real CLK_PERIOD = 3.33;

    logic clk;
    initial begin
        clk = 1'b0;
        forever #(CLK_PERIOD / 2.0) clk = ~clk;
    end

    // ----------------------------------------------------------------
    // Reset — active-high, held 10 cycles
    // ----------------------------------------------------------------
    logic rst;
    initial begin
        rst = 1'b1;
        repeat (10) @(posedge clk);
        rst = 1'b0;
    end

    // ----------------------------------------------------------------
    // Interface instances
    // ----------------------------------------------------------------
    axi4_stream_if axis_if (.clk(clk), .rst(rst));
    axi4_lite_if   axil_if (.clk(clk), .rst(rst));

    // ----------------------------------------------------------------
    // DUT instantiation
    // ----------------------------------------------------------------
    lliu_top #(
        .VEC_LEN   (FEATURE_VEC_LEN),
        .AXIL_ADDR (8),
        .AXIL_DATA (32)
    ) u_dut (
        .clk              (clk),
        .rst              (rst),

        // AXI4-Stream
        .s_axis_tdata     (axis_if.tdata),
        .s_axis_tvalid    (axis_if.tvalid),
        .s_axis_tready    (axis_if.tready),
        .s_axis_tlast     (axis_if.tlast),

        // AXI4-Lite — Write Address
        .s_axil_awaddr    (axil_if.awaddr),
        .s_axil_awvalid   (axil_if.awvalid),
        .s_axil_awready   (axil_if.awready),

        // AXI4-Lite — Write Data
        .s_axil_wdata     (axil_if.wdata),
        .s_axil_wstrb     (axil_if.wstrb),
        .s_axil_wvalid    (axil_if.wvalid),
        .s_axil_wready    (axil_if.wready),

        // AXI4-Lite — Write Response
        .s_axil_bresp     (axil_if.bresp),
        .s_axil_bvalid    (axil_if.bvalid),
        .s_axil_bready    (axil_if.bready),

        // AXI4-Lite — Read Address
        .s_axil_araddr    (axil_if.araddr),
        .s_axil_arvalid   (axil_if.arvalid),
        .s_axil_arready   (axil_if.arready),

        // AXI4-Lite — Read Data
        .s_axil_rdata     (axil_if.rdata),
        .s_axil_rresp     (axil_if.rresp),
        .s_axil_rvalid    (axil_if.rvalid),
        .s_axil_rready    (axil_if.rready)
    );

    // ----------------------------------------------------------------
    // Default drive for AXI4-Stream (until UVM driver takes over)
    // ----------------------------------------------------------------
    initial begin
        axis_if.tdata  = '0;
        axis_if.tvalid = 1'b0;
        axis_if.tlast  = 1'b0;
    end

    // ----------------------------------------------------------------
    // Default drive for AXI4-Lite (until UVM driver takes over)
    // ----------------------------------------------------------------
    initial begin
        axil_if.awaddr  = '0;
        axil_if.awvalid = 1'b0;
        axil_if.wdata   = '0;
        axil_if.wstrb   = '0;
        axil_if.wvalid  = 1'b0;
        axil_if.bready  = 1'b0;
        axil_if.araddr  = '0;
        axil_if.arvalid = 1'b0;
        axil_if.rready  = 1'b0;
    end

    // ----------------------------------------------------------------
    // Register virtual interfaces in config_db and launch UVM
    // ----------------------------------------------------------------
    initial begin
        uvm_config_db#(virtual axi4_stream_if)::set(null, "uvm_test_top.m_env.m_axis_agent*", "vif", axis_if);
        uvm_config_db#(virtual axi4_lite_if)::set(null, "uvm_test_top.m_env.m_axil_agent*", "vif", axil_if);
        run_test();
    end

    // ----------------------------------------------------------------
    // Simulation timeout
    // ----------------------------------------------------------------
    initial begin
        #10ms;
        `uvm_fatal("TIMEOUT", "Simulation timed out at 10ms")
    end

    // ----------------------------------------------------------------
    // SVA bind statements — protocol compliance & FSM safety
    // ----------------------------------------------------------------
    bind lliu_top axi4_stream_sva u_axis_sva (
        .clk    (clk),
        .rst    (rst),
        .tdata  (s_axis_tdata),
        .tvalid (s_axis_tvalid),
        .tready (s_axis_tready),
        .tlast  (s_axis_tlast)
    );

    bind lliu_top axi4_lite_sva u_axil_sva (
        .clk     (clk),
        .rst     (rst),
        .awaddr  (s_axil_awaddr),
        .awvalid (s_axil_awvalid),
        .awready (s_axil_awready),
        .wdata   (s_axil_wdata),
        .wstrb   (s_axil_wstrb),
        .wvalid  (s_axil_wvalid),
        .wready  (s_axil_wready),
        .bresp   (s_axil_bresp),
        .bvalid  (s_axil_bvalid),
        .bready  (s_axil_bready),
        .araddr  (s_axil_araddr),
        .arvalid (s_axil_arvalid),
        .arready (s_axil_arready),
        .rdata   (s_axil_rdata),
        .rresp   (s_axil_rresp),
        .rvalid  (s_axil_rvalid),
        .rready  (s_axil_rready)
    );

    bind itch_parser parser_sva u_parser_sva (
        .clk            (clk),
        .rst            (rst),
        .state          (state),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .msg_valid      (msg_valid),
        .fields_valid   (fields_valid)
    );

    bind dot_product_engine dot_product_sva u_dp_sva (
        .clk           (clk),
        .rst           (rst),
        .state         (state),
        .start         (start),
        .result_valid  (result_valid),
        .feature_valid (feature_valid),
        .acc_clear     (acc_clear)
    );

endmodule
