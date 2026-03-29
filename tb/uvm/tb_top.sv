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
    // Waveform dump (Verilator --trace / VCS -debug)
    // ----------------------------------------------------------------
    initial begin
        $dumpfile("dump.vcd");
        $dumpvars(0, tb_top);
    end

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

    // KC705 block-test control interface (extra DUT-specific pins)
    kc705_ctrl_if  kc705_if (.clk(clk), .rst(rst));

    // ----------------------------------------------------------------
    // DUT instantiation — selected by compile-time define
    //
    //   Default (LLIU_TOP_DUT): instantiates lliu_top (v1 pipeline)
    //   MOLDUPP64_DUT:          instantiates moldupp64_strip
    //   SYMFILTER_DUT:          instantiates symbol_filter
    //   DROPFULL_DUT:           instantiates eth_axis_rx_wrap
    // ----------------------------------------------------------------

`ifdef MOLDUPP64_DUT
    // === DUT: moldupp64_strip ======================================
    // AXI4-S input from axis_if; tkeep tied to 0xFF (sequences always
    // send full 8-byte beats).  Output side wired into kc705_if.
    logic [7:0] s_tkeep_i;
    assign s_tkeep_i = 8'hFF;

    moldupp64_strip u_dut (
        .clk              (clk),
        .rst              (rst),
        // Input stream
        .s_tdata          (axis_if.tdata),
        .s_tkeep          (s_tkeep_i),
        .s_tvalid         (axis_if.tvalid),
        .s_tlast          (axis_if.tlast),
        .s_tready         (axis_if.tready),
        // Output stream → kc705_if
        .m_tdata          (kc705_if.m_tdata),
        .m_tkeep          (kc705_if.m_tkeep),
        .m_tvalid         (kc705_if.m_tvalid),
        .m_tlast          (kc705_if.m_tlast),
        .m_tready         (kc705_if.m_tready),
        // Status signals → kc705_if
        .seq_num          (kc705_if.seq_num),
        .msg_count        (kc705_if.msg_count),
        .seq_valid        (kc705_if.seq_valid),
        .dropped_datagrams(kc705_if.dropped_datagrams),
        .expected_seq_num (kc705_if.expected_seq_num)
    );

    // AXI4-Lite pins — no DUT connected; drive DUT outputs to idle
    assign axil_if.awready = 1'b0;
    assign axil_if.wready  = 1'b0;
    assign axil_if.bresp   = 2'b00;
    assign axil_if.bvalid  = 1'b0;
    assign axil_if.arready = 1'b0;
    assign axil_if.rdata   = 32'h0;
    assign axil_if.rresp   = 2'b00;
    assign axil_if.rvalid  = 1'b0;

`elsif SYMFILTER_DUT
    // === DUT: symbol_filter =======================================
    // Lookup input (stock_valid + stock) wired from kc705_if.
    // CAM write ports also from kc705_if.
    // axis_if not connected to DUT; tready tied to 1 to prevent agent hang.
    assign axis_if.tready = 1'b1;

    symbol_filter u_dut (
        .clk          (clk),
        .rst          (rst),
        .cam_wr_index (kc705_if.cam_wr_index),
        .cam_wr_data  (kc705_if.cam_wr_data),
        .cam_wr_valid (kc705_if.cam_wr_valid),
        .cam_wr_en_bit(kc705_if.cam_wr_en_bit),
        .stock        (kc705_if.stock),
        .stock_valid  (kc705_if.stock_valid),
        .watchlist_hit(kc705_if.watchlist_hit)
    );

    // AXI4-Lite pins — no DUT connected; idle stubs
    assign axil_if.awready = 1'b0;
    assign axil_if.wready  = 1'b0;
    assign axil_if.bresp   = 2'b00;
    assign axil_if.bvalid  = 1'b0;
    assign axil_if.arready = 1'b0;
    assign axil_if.rdata   = 32'h0;
    assign axil_if.rresp   = 2'b00;
    assign axil_if.rvalid  = 1'b0;

`elsif DROPFULL_DUT
    // === DUT: eth_axis_rx_wrap =====================================
    // MAC RX input from axis_if (tdata, tvalid, tlast) + kc705_if.s_tkeep.
    // Output side into kc705_if.eth_payload_*.

    eth_axis_rx_wrap u_dut (
        .clk                 (clk),
        .rst                 (rst),
        // MAC RX input
        .mac_rx_tdata        (axis_if.tdata),
        .mac_rx_tkeep        (kc705_if.s_tkeep),
        .mac_rx_tvalid       (axis_if.tvalid),
        .mac_rx_tlast        (axis_if.tlast),
        .mac_rx_tready       (axis_if.tready),
        // Downstream output
        .eth_payload_tdata   (kc705_if.eth_payload_tdata),
        .eth_payload_tkeep   (kc705_if.eth_payload_tkeep),
        .eth_payload_tvalid  (kc705_if.eth_payload_tvalid),
        .eth_payload_tlast   (kc705_if.eth_payload_tlast),
        .eth_payload_tready  (kc705_if.eth_payload_tready),
        // Control / status
        .fifo_almost_full    (kc705_if.fifo_almost_full),
        .dropped_frames      (kc705_if.dropped_frames)
    );

    // AXI4-Lite pins — no DUT connected; idle stubs
    assign axil_if.awready = 1'b0;
    assign axil_if.wready  = 1'b0;
    assign axil_if.bresp   = 2'b00;
    assign axil_if.bvalid  = 1'b0;
    assign axil_if.arready = 1'b0;
    assign axil_if.rdata   = 32'h0;
    assign axil_if.rresp   = 2'b00;
    assign axil_if.rvalid  = 1'b0;

`else
    // === DUT: lliu_top (default — v1 pipeline) ====================
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
`endif

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
        // KC705 block-test control interface — available to all tests
        uvm_config_db#(virtual kc705_ctrl_if)::set(null, "uvm_test_top*", "kc705_vif", kc705_if);
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
    // ----------------------------------------------------------------
    // SVA bind statements — guarded by DUT define
    // ----------------------------------------------------------------

`ifdef LLIU_TOP_DUT
    // --------------- lliu_top hierarchy --------------------------
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

    bind dot_product_engine dot_product_sva #(.VEC_LEN(VEC_LEN)) u_dp_sva (
        .clk           (clk),
        .rst           (rst),
        .state         (state),
        .start         (start),
        .result_valid  (result_valid),
        .feature_valid (feature_valid),
        .acc_clear     (acc_clear)
    );

    bind lliu_top feature_latency_sva u_feature_latency_sva (
        .clk                 (clk),
        .rst                 (sys_rst),
        .parser_fields_valid (parser_fields_valid),
        .feat_valid          (feat_valid)
    );

    bind lliu_top end_to_end_latency_sva u_end_to_end_latency_sva (
        .clk                (clk),
        .rst                (sys_rst),
        .add_order_accepted (parser_fields_valid),
        .fifo_rd_tvalid     (1'b0),            // KC705 path unused in lliu_top context
        .dp_result_valid    (dp_result_valid)
    );

    // ----------------------------------------------------------------
    // Latency profiling monitor — measures ingress-to-egress latency
    // ----------------------------------------------------------------
    bind lliu_top lliu_latency_monitor u_latency_mon (
        .clk               (clk),
        .rst               (rst),
        .add_order_accepted (parser_fields_valid),
        .dp_result_valid   (dp_result_valid)
    );

`endif // LLIU_TOP_DUT

`ifdef MOLDUPP64_DUT
    // --------------- moldupp64_strip binds -----------------------
    // Note: drop_state and header_done are tied to 1'b0 until RTL
    //       engineer marks them (* keep = "true" *) in moldupp64_strip.sv
    bind moldupp64_strip moldupp64_sva u_moldupp64_sva (
        .clk              (clk),
        .rst              (rst),
        .seq_valid        (seq_valid),
        .expected_seq_num (expected_seq_num),
        .msg_count        (msg_count),
        .s_tvalid         (s_tvalid),
        .m_tdata          (m_tdata),
        .m_tkeep          (m_tkeep),
        .m_tvalid         (m_tvalid),
        .m_tlast          (m_tlast),
        .m_tready         (m_tready),
        .drop_state       (1'b0),   // stub — RTL coordination required
        .header_done      (1'b0)    // stub — RTL coordination required
    );
`endif // MOLDUPP64_DUT

`ifdef SYMFILTER_DUT
    // --------------- symbol_filter binds -------------------------
    // cam_entry_match is tied to 1'b0 until RTL marks it (* keep = "true" *)
    bind symbol_filter symbol_filter_sva u_symfilter_sva (
        .clk            (clk),
        .rst            (rst),
        .stock_valid    (stock_valid),
        .stock          (stock),
        .watchlist_hit  (watchlist_hit),
        .cam_wr_index   (cam_wr_index),
        .cam_wr_data    (cam_wr_data),
        .cam_wr_valid   (cam_wr_valid),
        .cam_wr_en_bit  (cam_wr_en_bit),
        .cam_entry_match(1'b0)  // stub — RTL coordination required
    );
`endif // SYMFILTER_DUT

`ifdef DROPFULL_DUT
    // --------------- eth_axis_rx_wrap binds ----------------------
    // drop_current and frame_active tied to 1'b0 until RTL marks them
    bind eth_axis_rx_wrap drop_on_full_sva u_drop_sva (
        .clk                 (clk),
        .rst                 (rst),
        .mac_rx_tvalid       (mac_rx_tvalid),
        .mac_rx_tlast        (mac_rx_tlast),
        .mac_rx_tready       (mac_rx_tready),
        .eth_payload_tvalid  (eth_payload_tvalid),
        .fifo_almost_full    (fifo_almost_full),
        .dropped_frames      (dropped_frames),
        .drop_current        (1'b0),  // stub — RTL coordination required
        .frame_active        (1'b0)   // stub — RTL coordination required
    );
`endif // DROPFULL_DUT

endmodule
