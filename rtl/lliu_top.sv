// lliu_top.sv — Top-level integration for the Low-Latency Inference Unit
//
// Pipeline: itch_parser → itch_field_extract → feature_extractor →
//           dot_product_engine → output_buffer
//
// Control plane: axi4_lite_slave → weight_mem, config, result readout
//
// Ports:
//   - AXI4-Stream slave (ITCH ingress)
//   - AXI4-Lite slave   (control plane)
//   - Clock, reset

import lliu_pkg::*;

// New KC705 modules (moldupp64_strip, symbol_filter, eth_axis_rx_wrap) are
// standalone primitives not yet wired into lliu_top; suppress the resulting
// MULTITOP diagnostic so the all-files lint run stays clean.
/* verilator lint_off MULTITOP */
module lliu_top #(
    parameter int VEC_LEN    = FEATURE_VEC_LEN,
    parameter int AXIL_ADDR  = 8,
    parameter int AXIL_DATA  = 32
)(
    input  logic        clk,
    input  logic        rst,

    // ---- AXI4-Stream slave (ITCH market data ingress) ----
    input  logic [63:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    // ---- AXI4-Lite slave (control plane) ----
    input  logic [AXIL_ADDR-1:0]   s_axil_awaddr,
    input  logic                    s_axil_awvalid,
    output logic                    s_axil_awready,

    input  logic [AXIL_DATA-1:0]   s_axil_wdata,
    input  logic [AXIL_DATA/8-1:0] s_axil_wstrb,
    input  logic                    s_axil_wvalid,
    output logic                    s_axil_wready,

    /* verilator coverage_off */
    output logic [1:0]              s_axil_bresp,
    /* verilator coverage_on */
    output logic                    s_axil_bvalid,
    input  logic                    s_axil_bready,

    input  logic [AXIL_ADDR-1:0]   s_axil_araddr,
    input  logic                    s_axil_arvalid,
    output logic                    s_axil_arready,

    output logic [AXIL_DATA-1:0]   s_axil_rdata,
    /* verilator coverage_off */
    output logic [1:0]              s_axil_rresp,
    /* verilator coverage_on */
    output logic                    s_axil_rvalid,
    input  logic                    s_axil_rready
);

    // ==================================================================
    // Internal signals
    // ==================================================================

    // Parser → field extract outputs (exposed at itch_parser ports)
    logic        parser_msg_valid;
    logic [7:0]  parser_message_type;
    logic [63:0] parser_order_ref;
    logic        parser_side;
    logic [31:0] parser_price;
    logic        parser_fields_valid;

    // Feature extractor outputs
    bfloat16_t   feat_vec [VEC_LEN];
    logic        feat_valid;

    // Weight memory interface
    logic [$clog2(VEC_LEN)-1:0] wgt_wr_addr;
    bfloat16_t                  wgt_wr_data;
    logic                       wgt_wr_en;
    logic [$clog2(VEC_LEN)-1:0] wgt_rd_addr;
    bfloat16_t                  wgt_rd_data;

    // Dot-product engine interface
    logic      dp_start;
    logic      dp_feature_valid;
    bfloat16_t dp_feature_in;
    bfloat16_t dp_weight_in;
    float32_t  dp_result;
    logic      dp_result_valid;

    // Output buffer interface
    float32_t  out_result;
    logic      out_ready;

    // Parser pipeline backpressure
    logic      pipeline_hold;

    // AXI4-Lite control
    logic      ctrl_start;
    logic      ctrl_soft_reset;

    // Combined reset: external rst OR soft reset from register
    logic      sys_rst;
    assign sys_rst = rst | ctrl_soft_reset;

    // ==================================================================
    // Parser Stage
    // ==================================================================

    // Hold off new AXI-S messages while the sequencer is busy processing the
    // previous Add-Order inference. This ensures 1:1 correspondence between
    // parser_fields_valid pulses and dp_result_valid pulses.
    assign pipeline_hold = feat_valid || (seq_state != SEQ_IDLE);

    itch_parser u_parser (
        .clk            (clk),
        .rst            (sys_rst),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .pipeline_hold  (pipeline_hold),
        .msg_valid      (parser_msg_valid),
        .message_type   (parser_message_type),
        .order_ref      (parser_order_ref),
        .side           (parser_side),
        .price          (parser_price),
        .fields_valid   (parser_fields_valid)
    );

    // ==================================================================
    // Feature Extraction Stage
    // ==================================================================

    feature_extractor #(
        .VEC_LEN (VEC_LEN)
    ) u_feat_extract (
        .clk            (clk),
        .rst            (sys_rst),
        .price          (parser_price),
        .order_ref      (parser_order_ref),
        .side           (parser_side),
        .fields_valid   (parser_fields_valid),
        .features       (feat_vec),
        .features_valid (feat_valid)
    );

    // ==================================================================
    // Inference Sequencer — feeds features and weights to dot-product engine
    // ==================================================================
    // When features are valid, we start the engine and iterate elements.
    // The weight memory has 1-cycle read latency, so we pipeline accordingly.

    typedef enum logic [1:0] {
        SEQ_IDLE    = 2'b00,
        SEQ_PRELOAD = 2'b01,  // kick off first weight read
        SEQ_FEED    = 2'b10
    } seq_state_t;

    seq_state_t seq_state;
    logic [$clog2(VEC_LEN+1)-1:0] seq_idx;

    always_ff @(posedge clk) begin
        if (sys_rst) begin
            seq_state       <= SEQ_IDLE;
            seq_idx         <= '0;
            dp_start        <= 1'b0;
            dp_feature_valid <= 1'b0;
            dp_feature_in   <= '0;
        end else begin
            dp_start         <= 1'b0;
            dp_feature_valid <= 1'b0;

            case (seq_state)
                SEQ_IDLE: begin
                    if (feat_valid) begin
                        // Start dot-product engine (clears accumulator)
                        dp_start  <= 1'b1;
                        seq_idx   <= '0;
                        seq_state <= SEQ_PRELOAD;
                    end
                end

                SEQ_PRELOAD: begin
                    // Weight read was kicked in IDLE→PRELOAD; data arrives next cycle
                    seq_state <= SEQ_FEED;
                end

                SEQ_FEED: begin
                    // Present feature[seq_idx] and weight (already on wgt_rd_data bus)
                    dp_feature_in    <= feat_vec[seq_idx[$clog2(VEC_LEN)-1:0]];
                    dp_feature_valid <= 1'b1;

                    if (seq_idx == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1) begin
                        seq_state <= SEQ_IDLE;
                    end else begin
                        seq_idx <= seq_idx + 1;
                    end
                end

                /* verilator coverage_off */
                default: seq_state <= SEQ_IDLE;
                /* verilator coverage_on */
            endcase
        end
    end

    // Weight read address follows sequencer index
    assign wgt_rd_addr = seq_idx[$clog2(VEC_LEN)-1:0];
    assign dp_weight_in = wgt_rd_data;

    // ==================================================================
    // Weight Memory
    // ==================================================================

    weight_mem #(
        .DEPTH (VEC_LEN)
    ) u_weight_mem (
        .clk     (clk),
        .rst     (sys_rst),
        .wr_addr (wgt_wr_addr),
        .wr_data (wgt_wr_data),
        .wr_en   (wgt_wr_en),
        .rd_addr (wgt_rd_addr),
        .rd_data (wgt_rd_data)
    );

    // ==================================================================
    // Dot-Product Engine
    // ==================================================================

    dot_product_engine #(
        .VEC_LEN (VEC_LEN)
    ) u_dp_engine (
        .clk           (clk),
        .rst           (sys_rst),
        .feature_in    (dp_feature_in),
        .feature_valid (dp_feature_valid),
        .weight_in     (dp_weight_in),
        .start         (dp_start),
        .result        (dp_result),
        .result_valid  (dp_result_valid)
    );

    // ==================================================================
    // Output Buffer
    // ==================================================================

    output_buffer u_out_buf (
        .clk          (clk),
        .rst          (sys_rst),
        .result_in    (dp_result),
        .result_valid (dp_result_valid),
        .result_out   (out_result),
        .result_ready (out_ready)
    );

    // ==================================================================
    // AXI4-Lite Slave (Control Plane)
    // ==================================================================

    // Busy = sequencer is not idle OR dp engine hasn't produced result
    logic status_busy;
    assign status_busy = (seq_state != SEQ_IDLE);

    axi4_lite_slave #(
        .ADDR_WIDTH (AXIL_ADDR),
        .DATA_WIDTH (AXIL_DATA)
    ) u_axil (
        .clk                 (clk),
        .rst                 (rst),  // AXI-Lite uses external reset (not soft)
        .s_axil_awaddr       (s_axil_awaddr),
        .s_axil_awvalid      (s_axil_awvalid),
        .s_axil_awready      (s_axil_awready),
        .s_axil_wdata        (s_axil_wdata),
        .s_axil_wstrb        (s_axil_wstrb),
        .s_axil_wvalid       (s_axil_wvalid),
        .s_axil_wready       (s_axil_wready),
        .s_axil_bresp        (s_axil_bresp),
        .s_axil_bvalid       (s_axil_bvalid),
        .s_axil_bready       (s_axil_bready),
        .s_axil_araddr       (s_axil_araddr),
        .s_axil_arvalid      (s_axil_arvalid),
        .s_axil_arready      (s_axil_arready),
        .s_axil_rdata        (s_axil_rdata),
        .s_axil_rresp        (s_axil_rresp),
        .s_axil_rvalid       (s_axil_rvalid),
        .s_axil_rready       (s_axil_rready),
        .wgt_wr_addr         (wgt_wr_addr),
        .wgt_wr_data         (wgt_wr_data),
        .wgt_wr_en           (wgt_wr_en),
        .ctrl_start          (ctrl_start),
        .ctrl_soft_reset     (ctrl_soft_reset),
        .status_result_ready (out_ready),
        .status_busy         (status_busy),
        .result_data         (out_result)
    );

endmodule
