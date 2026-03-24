// axi4_lite_slave.sv — AXI4-Lite control-plane interface
//
// Register map:
//   0x00  CTRL    — [0] start, [1] soft_reset   (write-only, self-clearing)
//   0x04  STATUS  — [0] result_ready, [1] busy   (read-only)
//   0x08  WGT_ADDR — weight write address         (write)
//   0x0C  WGT_DATA — weight write data (bfloat16) (write, triggers wr_en)
//   0x10  RESULT  — inference result (float32)    (read-only)
//
// Single outstanding transaction. No pipelining.

import lliu_pkg::*;

module axi4_lite_slave #(
    parameter int ADDR_WIDTH = 8,
    parameter int DATA_WIDTH = 32
)(
    input  logic                    clk,
    input  logic                    rst,

    // ---- AXI4-Lite Write Address channel ----
    input  logic [ADDR_WIDTH-1:0]   s_axil_awaddr,
    input  logic                    s_axil_awvalid,
    output logic                    s_axil_awready,

    // ---- AXI4-Lite Write Data channel ----
    input  logic [DATA_WIDTH-1:0]   s_axil_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_axil_wstrb,
    input  logic                    s_axil_wvalid,
    output logic                    s_axil_wready,

    // ---- AXI4-Lite Write Response channel ----
    /* verilator coverage_off */
    output logic [1:0]              s_axil_bresp,
    /* verilator coverage_on */
    output logic                    s_axil_bvalid,
    input  logic                    s_axil_bready,

    // ---- AXI4-Lite Read Address channel ----
    input  logic [ADDR_WIDTH-1:0]   s_axil_araddr,
    input  logic                    s_axil_arvalid,
    output logic                    s_axil_arready,

    // ---- AXI4-Lite Read Data channel ----
    output logic [DATA_WIDTH-1:0]   s_axil_rdata,
    /* verilator coverage_off */
    output logic [1:0]              s_axil_rresp,
    /* verilator coverage_on */
    output logic                    s_axil_rvalid,
    input  logic                    s_axil_rready,

    // ---- Weight memory write port ----
    output logic [$clog2(FEATURE_VEC_LEN)-1:0] wgt_wr_addr,
    output bfloat16_t                          wgt_wr_data,
    output logic                               wgt_wr_en,

    // ---- Control outputs ----
    output logic                    ctrl_start,
    output logic                    ctrl_soft_reset,

    // ---- Status inputs ----
    input  logic                    status_result_ready,
    input  logic                    status_busy,

    // ---- Result input ----
    input  float32_t                result_data
);

    // ---- Register addresses ----
    localparam logic [ADDR_WIDTH-1:0] REG_CTRL     = 8'h00;
    localparam logic [ADDR_WIDTH-1:0] REG_STATUS   = 8'h04;
    localparam logic [ADDR_WIDTH-1:0] REG_WGT_ADDR = 8'h08;
    localparam logic [ADDR_WIDTH-1:0] REG_WGT_DATA = 8'h0C;
    localparam logic [ADDR_WIDTH-1:0] REG_RESULT   = 8'h10;

    // ---- Internal registers ----
    logic [$clog2(FEATURE_VEC_LEN)-1:0] wgt_addr_reg;

    // ---- Write channel state machine ----
    // Accept AW and W simultaneously, then respond with B
    /* verilator coverage_off */  // declaration — no executable code
    logic aw_captured, w_captured;
    /* verilator coverage_on */
    logic [ADDR_WIDTH-1:0] wr_addr_latched;
    logic [DATA_WIDTH-1:0] wr_data_latched;

    assign s_axil_awready = !aw_captured;
    assign s_axil_wready  = !w_captured;

    // Write response: always OKAY
    assign s_axil_bresp = 2'b00;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_captured     <= 1'b0;
            w_captured      <= 1'b0;
            s_axil_bvalid   <= 1'b0;
            wr_addr_latched <= '0;
            wr_data_latched <= '0;
            wgt_addr_reg    <= '0;
            wgt_wr_en       <= 1'b0;
            ctrl_start      <= 1'b0;
            ctrl_soft_reset <= 1'b0;
        end else begin
            // Self-clearing control pulses
            ctrl_start      <= 1'b0;
            ctrl_soft_reset <= 1'b0;
            wgt_wr_en       <= 1'b0;

            // B channel handshake
            if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end

            // Capture AW
            if (s_axil_awvalid && s_axil_awready) begin
                aw_captured     <= 1'b1;
                wr_addr_latched <= s_axil_awaddr;
            end

            // Capture W
            if (s_axil_wvalid && s_axil_wready) begin
                w_captured      <= 1'b1;
                wr_data_latched <= s_axil_wdata;
            end

            // When both AW and W are captured, process write
            if ((aw_captured || (s_axil_awvalid && s_axil_awready)) &&
                (w_captured  || (s_axil_wvalid  && s_axil_wready))) begin

                aw_captured   <= 1'b0;
                w_captured    <= 1'b0;
                s_axil_bvalid <= 1'b1;

                // Use the latest address/data (inline capture or latched)
                case (aw_captured ? wr_addr_latched : s_axil_awaddr)
                    REG_CTRL: begin
                        if (w_captured ? wr_data_latched[0] : s_axil_wdata[0])
                            ctrl_start <= 1'b1;
                        if (w_captured ? wr_data_latched[1] : s_axil_wdata[1])
                            ctrl_soft_reset <= 1'b1;
                    end
                    REG_WGT_ADDR: begin
                        wgt_addr_reg <= (w_captured ? wr_data_latched[$clog2(FEATURE_VEC_LEN)-1:0]
                                                    : s_axil_wdata[$clog2(FEATURE_VEC_LEN)-1:0]);
                    end
                    REG_WGT_DATA: begin
                        wgt_wr_en <= 1'b1;
                    end
                    default: ;  // Ignore writes to read-only or unmapped regs
                endcase
            end
        end
    end

    // Weight write port
    assign wgt_wr_addr = wgt_addr_reg;
    assign wgt_wr_data = bfloat16_t'(wr_data_latched[BF16_WIDTH-1:0]);

    // ---- Read channel state machine ----
    logic ar_captured;
    logic [ADDR_WIDTH-1:0] rd_addr_latched;

    assign s_axil_arready = !ar_captured && !s_axil_rvalid;
    assign s_axil_rresp   = 2'b00;  // Always OKAY

    always_ff @(posedge clk) begin
        if (rst) begin
            ar_captured     <= 1'b0;
            rd_addr_latched <= '0;
            s_axil_rvalid   <= 1'b0;
            s_axil_rdata    <= '0;
        end else begin
            // R channel handshake
            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end

            // Capture AR
            if (s_axil_arvalid && s_axil_arready) begin
                ar_captured     <= 1'b1;
                rd_addr_latched <= s_axil_araddr;
            end

            // Process read
            if (ar_captured) begin
                ar_captured   <= 1'b0;
                s_axil_rvalid <= 1'b1;

                case (rd_addr_latched)
                    REG_STATUS: s_axil_rdata <= {30'd0, status_busy, status_result_ready};
                    REG_RESULT: s_axil_rdata <= result_data;
                    default:    s_axil_rdata <= 32'hDEAD_BEEF;
                endcase
            end
        end
    end

endmodule
