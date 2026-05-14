//      // verilator_coverage annotation
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
%000001     reg [ADDR_W:0] wr_bin = '0, wr_gray = '0;
%000001     reg [ADDR_W:0] rd_gray_s1 = '0, rd_gray_s2 = '0;
        
            // Read domain pointers
%000001     reg [ADDR_W:0] rd_bin = '0, rd_gray = '0;
%000001     reg [ADDR_W:0] wr_gray_s1 = '0, wr_gray_s2 = '0;
        
            // Gray <-> binary conversion
 001540     function automatic [ADDR_W:0] bin2gray(input [ADDR_W:0] b);
 001540         return b ^ (b >> 1);
            endfunction
        
%000002     function automatic [ADDR_W:0] gray2bin(input [ADDR_W:0] g);
%000002         reg [ADDR_W:0] b;
%000002         b[ADDR_W] = g[ADDR_W];
~000014         for (int i = ADDR_W-1; i >= 0; i--)
 000014             b[i] = b[i+1] ^ g[i];
%000002         return b;
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
 016649     always_ff @(posedge s_clk) begin
 000017         if (s_rst) begin
 000017             wr_bin  <= '0;
 000017             wr_gray <= '0;
 015862         end else if (s_axis_tvalid && s_axis_tready) begin
 000770             mem[wr_bin[ADDR_W-1:0]] <= {s_axis_tlast, s_axis_tkeep, s_axis_tdata};
 000770             wr_bin  <= wr_bin + 1;
 000770             wr_gray <= bin2gray(wr_bin + 1);
                end
            end
        
            // Sync rd_gray into s_clk
 016649     always_ff @(posedge s_clk) begin
 016632         if (s_rst) begin rd_gray_s1 <= '0; rd_gray_s2 <= '0; end
 016632         else begin rd_gray_s1 <= rd_gray; rd_gray_s2 <= rd_gray_s1; end
            end
        
            // Sync wr_gray into m_clk
 031960     always_ff @(posedge m_clk) begin
 031928         if (m_rst) begin wr_gray_s1 <= '0; wr_gray_s2 <= '0; end
 031928         else begin wr_gray_s1 <= wr_gray; wr_gray_s2 <= wr_gray_s1; end
            end
        
            // Read side - output register with ready/valid handshake
            reg [DATA_WIDTH-1:0] rd_tdata;
            reg [KEEP_WIDTH-1:0] rd_tkeep;
            reg                  rd_tlast;
            reg                  rd_valid;
        
            assign empty = (rd_gray == wr_gray_s2);
        
            wire rd_can_read = !empty;
            wire rd_pipe_ready = m_axis_tready || !rd_valid;
        
 031960     always_ff @(posedge m_clk) begin
 031928         if (m_rst) begin
 000032             rd_bin   <= '0;
 000032             rd_gray  <= '0;
 000032             rd_valid <= 1'b0;
 000032             rd_tdata <= '0;
 000032             rd_tkeep <= '0;
 000032             rd_tlast <= 1'b0;
 031928         end else begin
~031928             if (rd_pipe_ready) begin
 031158                 if (rd_can_read) begin
 000770                     {rd_tlast, rd_tkeep, rd_tdata} <= mem[rd_bin[ADDR_W-1:0]];
 000770                     rd_valid <= 1'b1;
 000770                     rd_bin   <= rd_bin + 1;
 000770                     rd_gray  <= bin2gray(rd_bin + 1);
 031158                 end else begin
 031158                     rd_valid <= 1'b0;
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
        
