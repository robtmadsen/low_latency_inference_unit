// axis_async_fifo.sv — Simulation stub for Forencich axis_async_fifo
// Dual-clock FIFO with gray-code pointer synchronization

module axis_async_fifo #(
    parameter DEPTH       = 128,
    parameter DATA_WIDTH  = 64,
    parameter KEEP_ENABLE = 1,
    parameter KEEP_WIDTH  = DATA_WIDTH/8,
    parameter LAST_ENABLE = 1,
    parameter ID_ENABLE   = 0,
    parameter ID_WIDTH    = 8,
    parameter DEST_ENABLE = 0,
    parameter DEST_WIDTH  = 8,
    parameter USER_ENABLE = 0,
    parameter USER_WIDTH  = 1,
    parameter RAM_PIPELINE = 1,
    parameter FRAME_FIFO  = 0
)(
    input  wire                   s_clk,
    input  wire                   s_rst,
    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]  s_axis_tkeep,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,
    input  wire [ID_WIDTH-1:0]    s_axis_tid,
    input  wire [DEST_WIDTH-1:0]  s_axis_tdest,
    input  wire [USER_WIDTH-1:0]  s_axis_tuser,
    input  wire                   s_pause_req,
    output wire                   s_pause_ack,
    output wire [$clog2(DEPTH):0] s_status_depth,
    output wire [$clog2(DEPTH):0] s_status_depth_commit,
    output wire                   s_status_overflow,
    output wire                   s_status_bad_frame,
    output wire                   s_status_good_frame,

    input  wire                   m_clk,
    input  wire                   m_rst,
    output wire [DATA_WIDTH-1:0]  m_axis_tdata,
    output wire [KEEP_WIDTH-1:0]  m_axis_tkeep,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,
    output wire                   m_axis_tlast,
    output wire [ID_WIDTH-1:0]    m_axis_tid,
    output wire [DEST_WIDTH-1:0]  m_axis_tdest,
    output wire [USER_WIDTH-1:0]  m_axis_tuser,
    input  wire                   m_pause_req,
    output wire                   m_pause_ack,
    output wire [$clog2(DEPTH):0] m_status_depth,
    output wire [$clog2(DEPTH):0] m_status_depth_commit,
    output wire                   m_status_overflow,
    output wire                   m_status_bad_frame,
    output wire                   m_status_good_frame
);

    localparam ADDR_W = $clog2(DEPTH);
    localparam WORD_W = DATA_WIDTH + KEEP_WIDTH + 1;

    reg [WORD_W-1:0] mem [0:DEPTH-1];

    // Write domain pointers
    reg [ADDR_W:0] wr_bin = '0, wr_gray = '0;
    reg [ADDR_W:0] rd_gray_s1 = '0, rd_gray_s2 = '0;

    // Read domain pointers
    reg [ADDR_W:0] rd_bin = '0, rd_gray = '0;
    reg [ADDR_W:0] wr_gray_s1 = '0, wr_gray_s2 = '0;

    // Gray <-> binary conversion
    function automatic [ADDR_W:0] bin2gray(input [ADDR_W:0] b);
        return b ^ (b >> 1);
    endfunction

    function automatic [ADDR_W:0] gray2bin(input [ADDR_W:0] g);
        reg [ADDR_W:0] b;
        b[ADDR_W] = g[ADDR_W];
        for (int i = ADDR_W-1; i >= 0; i--)
            b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    // Full/empty
    wire full  = (wr_gray == {~rd_gray_s2[ADDR_W:ADDR_W-1], rd_gray_s2[ADDR_W-2:0]});
    wire empty;

    // Write-side depth
    wire [ADDR_W:0] rd_bin_in_wclk = gray2bin(rd_gray_s2);
    assign s_status_depth = wr_bin - rd_bin_in_wclk;

    assign s_axis_tready        = !full && !s_rst;
    assign s_pause_ack          = s_pause_req;
    assign s_status_depth_commit = s_status_depth;
    assign s_status_overflow    = 1'b0;
    assign s_status_bad_frame   = 1'b0;
    assign s_status_good_frame  = 1'b0;

    // Write logic
    always_ff @(posedge s_clk) begin
        if (s_rst) begin
            wr_bin  <= '0;
            wr_gray <= '0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            mem[wr_bin[ADDR_W-1:0]] <= {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
            wr_bin  <= wr_bin + 1;
            wr_gray <= bin2gray(wr_bin + 1);
        end
    end

    // Sync rd_gray into s_clk
    always_ff @(posedge s_clk) begin
        if (s_rst) begin rd_gray_s1 <= '0; rd_gray_s2 <= '0; end
        else begin rd_gray_s1 <= rd_gray; rd_gray_s2 <= rd_gray_s1; end
    end

    // Sync wr_gray into m_clk
    always_ff @(posedge m_clk) begin
        if (m_rst) begin wr_gray_s1 <= '0; wr_gray_s2 <= '0; end
        else begin wr_gray_s1 <= wr_gray; wr_gray_s2 <= wr_gray_s1; end
    end

    // Read side - output register with ready/valid handshake
    reg [DATA_WIDTH-1:0] rd_tdata;
    reg [KEEP_WIDTH-1:0] rd_tkeep;
    reg                  rd_tlast;
    reg                  rd_valid;

    assign empty = (rd_gray == wr_gray_s2);

    wire rd_can_read = !empty;
    wire rd_pipe_ready = m_axis_tready || !rd_valid;

    always_ff @(posedge m_clk) begin
        if (m_rst) begin
            rd_bin   <= '0;
            rd_gray  <= '0;
            rd_valid <= 1'b0;
            rd_tdata <= '0;
            rd_tkeep <= '0;
            rd_tlast <= 1'b0;
        end else begin
            if (rd_pipe_ready) begin
                if (rd_can_read) begin
                    {rd_tlast, rd_tkeep, rd_tdata} <= mem[rd_bin[ADDR_W-1:0]];
                    rd_valid <= 1'b1;
                    rd_bin   <= rd_bin + 1;
                    rd_gray  <= bin2gray(rd_bin + 1);
                end else begin
                    rd_valid <= 1'b0;
                end
            end
        end
    end

    assign m_axis_tdata  = rd_tdata;
    assign m_axis_tkeep  = rd_tkeep;
    assign m_axis_tvalid = rd_valid;
    assign m_axis_tlast  = rd_tlast;
    assign m_axis_tid    = '0;
    assign m_axis_tdest  = '0;
    assign m_axis_tuser  = '0;
    assign m_pause_ack   = m_pause_req;

    wire [ADDR_W:0] wr_bin_in_rclk = gray2bin(wr_gray_s2);
    assign m_status_depth        = wr_bin_in_rclk - rd_bin;
    assign m_status_depth_commit = m_status_depth;
    assign m_status_overflow     = 1'b0;
    assign m_status_bad_frame    = 1'b0;
    assign m_status_good_frame   = 1'b0;

endmodule
