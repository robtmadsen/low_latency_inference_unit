//      // verilator_coverage annotation
        /*
        
        Copyright (c) 2016-2018 Alex Forencich
        
        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:
        
        The above copyright notice and this permission notice shall be included in
        all copies or substantial portions of the Software.
        
        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
        THE SOFTWARE.
        
        */
        
        // Language: Verilog 2001
        
        `resetall
        `timescale 1ns / 1ps
        `default_nettype none
        
        /*
         * UDP checksum calculation module (64 bit datapath)
         */
        module udp_checksum_gen_64 #
        (
            parameter PAYLOAD_FIFO_DEPTH = 2048,
            parameter HEADER_FIFO_DEPTH = 8
        )
        (
            input  wire        clk,
            input  wire        rst,
            
            /*
             * UDP frame input
             */
            input  wire        s_udp_hdr_valid,
            output wire        s_udp_hdr_ready,
            input  wire [47:0] s_eth_dest_mac,
            input  wire [47:0] s_eth_src_mac,
            input  wire [15:0] s_eth_type,
            input  wire [3:0]  s_ip_version,
            input  wire [3:0]  s_ip_ihl,
            input  wire [5:0]  s_ip_dscp,
            input  wire [1:0]  s_ip_ecn,
            input  wire [15:0] s_ip_identification,
            input  wire [2:0]  s_ip_flags,
            input  wire [12:0] s_ip_fragment_offset,
            input  wire [7:0]  s_ip_ttl,
            input  wire [15:0] s_ip_header_checksum,
            input  wire [31:0] s_ip_source_ip,
            input  wire [31:0] s_ip_dest_ip,
            input  wire [15:0] s_udp_source_port,
            input  wire [15:0] s_udp_dest_port,
            input  wire [63:0] s_udp_payload_axis_tdata,
            input  wire [7:0]  s_udp_payload_axis_tkeep,
            input  wire        s_udp_payload_axis_tvalid,
            output wire        s_udp_payload_axis_tready,
            input  wire        s_udp_payload_axis_tlast,
            input  wire        s_udp_payload_axis_tuser,
            
            /*
             * UDP frame output
             */
            output wire        m_udp_hdr_valid,
            input  wire        m_udp_hdr_ready,
            output wire [47:0] m_eth_dest_mac,
            output wire [47:0] m_eth_src_mac,
            output wire [15:0] m_eth_type,
            output wire [3:0]  m_ip_version,
            output wire [3:0]  m_ip_ihl,
            output wire [5:0]  m_ip_dscp,
            output wire [1:0]  m_ip_ecn,
            output wire [15:0] m_ip_length,
            output wire [15:0] m_ip_identification,
            output wire [2:0]  m_ip_flags,
            output wire [12:0] m_ip_fragment_offset,
            output wire [7:0]  m_ip_ttl,
            output wire [7:0]  m_ip_protocol,
            output wire [15:0] m_ip_header_checksum,
            output wire [31:0] m_ip_source_ip,
            output wire [31:0] m_ip_dest_ip,
            output wire [15:0] m_udp_source_port,
            output wire [15:0] m_udp_dest_port,
            output wire [15:0] m_udp_length,
            output wire [15:0] m_udp_checksum,
            output wire [63:0] m_udp_payload_axis_tdata,
            output wire [7:0]  m_udp_payload_axis_tkeep,
            output wire        m_udp_payload_axis_tvalid,
            input  wire        m_udp_payload_axis_tready,
            output wire        m_udp_payload_axis_tlast,
            output wire        m_udp_payload_axis_tuser,
            
            /*
             * Status signals
             */
            output wire        busy
        );
        
        /*
        
        UDP Frame
        
         Field                       Length
         Destination MAC address     6 octets
         Source MAC address          6 octets
         Ethertype (0x0800)          2 octets
         Version (4)                 4 bits
         IHL (5-15)                  4 bits
         DSCP (0)                    6 bits
         ECN (0)                     2 bits
         length                      2 octets
         identification (0?)         2 octets
         flags (010)                 3 bits
         fragment offset (0)         13 bits
         time to live (64?)          1 octet
         protocol                    1 octet
         header checksum             2 octets
         source IP                   4 octets
         destination IP              4 octets
         options                     (IHL-5)*4 octets
        
         source port                 2 octets
         desination port             2 octets
         length                      2 octets
         checksum                    2 octets
        
         payload                     length octets
        
        This module receives a UDP frame with header fields in parallel and payload on
        an AXI stream interface, calculates the length and checksum, then produces the
        header fields in parallel along with the UDP payload in a separate AXI stream.
        
        */
        
        parameter HEADER_FIFO_ADDR_WIDTH = $clog2(HEADER_FIFO_DEPTH);
        
        localparam [2:0]
            STATE_IDLE = 3'd0,
            STATE_SUM_HEADER = 3'd1,
            STATE_SUM_PAYLOAD = 3'd2,
            STATE_FINISH_SUM_1 = 3'd3,
            STATE_FINISH_SUM_2 = 3'd4;
        
 000001 reg [2:0] state_reg = STATE_IDLE, state_next;
        
        // datapath control signals
        reg store_udp_hdr;
        reg shift_payload_in;
        reg [31:0] checksum_part;
        
 000001 reg [15:0] frame_ptr_reg = 16'd0, frame_ptr_next;
        
 000001 reg [31:0] checksum_reg = 32'd0, checksum_next;
 000001 reg [16:0] checksum_temp1_reg = 17'd0, checksum_temp1_next;
 000001 reg [16:0] checksum_temp2_reg = 17'd0, checksum_temp2_next;
        
 000001 reg [47:0] eth_dest_mac_reg = 48'd0;
 000001 reg [47:0] eth_src_mac_reg = 48'd0;
 000001 reg [15:0] eth_type_reg = 16'd0;
 000001 reg [3:0]  ip_version_reg = 4'd0;
 000001 reg [3:0]  ip_ihl_reg = 4'd0;
 000001 reg [5:0]  ip_dscp_reg = 6'd0;
 000001 reg [1:0]  ip_ecn_reg = 2'd0;
 000001 reg [15:0] ip_identification_reg = 16'd0;
 000001 reg [2:0]  ip_flags_reg = 3'd0;
 000001 reg [12:0] ip_fragment_offset_reg = 13'd0;
 000001 reg [7:0]  ip_ttl_reg = 8'd0;
 000001 reg [15:0] ip_header_checksum_reg = 16'd0;
 000001 reg [31:0] ip_source_ip_reg = 32'd0;
 000001 reg [31:0] ip_dest_ip_reg = 32'd0;
 000001 reg [15:0] udp_source_port_reg = 16'd0;
 000001 reg [15:0] udp_dest_port_reg = 16'd0;
        
 000001 reg hdr_valid_reg = 0, hdr_valid_next;
        
 000001 reg s_udp_hdr_ready_reg = 1'b0, s_udp_hdr_ready_next;
 000001 reg s_udp_payload_axis_tready_reg = 1'b0, s_udp_payload_axis_tready_next;
        
 000001 reg busy_reg = 1'b0;
        
        /*
         * UDP Payload FIFO
         */
        wire [63:0] s_udp_payload_fifo_tdata;
        wire [7:0] s_udp_payload_fifo_tkeep;
        wire s_udp_payload_fifo_tvalid;
        wire s_udp_payload_fifo_tready;
        wire s_udp_payload_fifo_tlast;
        wire s_udp_payload_fifo_tuser;
        
        wire [63:0] m_udp_payload_fifo_tdata;
        wire [7:0] m_udp_payload_fifo_tkeep;
        wire m_udp_payload_fifo_tvalid;
        wire m_udp_payload_fifo_tready;
        wire m_udp_payload_fifo_tlast;
        wire m_udp_payload_fifo_tuser;
        
        axis_fifo #(
            .DEPTH(PAYLOAD_FIFO_DEPTH),
            .DATA_WIDTH(64),
            .KEEP_ENABLE(1),
            .KEEP_WIDTH(8),
            .LAST_ENABLE(1),
            .ID_ENABLE(0),
            .DEST_ENABLE(0),
            .USER_ENABLE(1),
            .USER_WIDTH(1),
            .FRAME_FIFO(0)
        )
        payload_fifo (
            .clk(clk),
            .rst(rst),
            // AXI input
            .s_axis_tdata(s_udp_payload_fifo_tdata),
            .s_axis_tkeep(s_udp_payload_fifo_tkeep),
            .s_axis_tvalid(s_udp_payload_fifo_tvalid),
            .s_axis_tready(s_udp_payload_fifo_tready),
            .s_axis_tlast(s_udp_payload_fifo_tlast),
            .s_axis_tid(0),
            .s_axis_tdest(0),
            .s_axis_tuser(s_udp_payload_fifo_tuser),
            // AXI output
            .m_axis_tdata(m_udp_payload_fifo_tdata),
            .m_axis_tkeep(m_udp_payload_fifo_tkeep),
            .m_axis_tvalid(m_udp_payload_fifo_tvalid),
            .m_axis_tready(m_udp_payload_fifo_tready),
            .m_axis_tlast(m_udp_payload_fifo_tlast),
            .m_axis_tid(),
            .m_axis_tdest(),
            .m_axis_tuser(m_udp_payload_fifo_tuser),
            // Status
            .status_overflow(),
            .status_bad_frame(),
            .status_good_frame()
        );
        
        assign s_udp_payload_fifo_tdata = s_udp_payload_axis_tdata;
        assign s_udp_payload_fifo_tkeep = s_udp_payload_axis_tkeep;
        assign s_udp_payload_fifo_tvalid = s_udp_payload_axis_tvalid && shift_payload_in;
        assign s_udp_payload_axis_tready = s_udp_payload_fifo_tready && shift_payload_in;
        assign s_udp_payload_fifo_tlast = s_udp_payload_axis_tlast;
        assign s_udp_payload_fifo_tuser = s_udp_payload_axis_tuser;
        
        assign m_udp_payload_axis_tdata = m_udp_payload_fifo_tdata;
        assign m_udp_payload_axis_tkeep = m_udp_payload_fifo_tkeep;
        assign m_udp_payload_axis_tvalid = m_udp_payload_fifo_tvalid;
        assign m_udp_payload_fifo_tready = m_udp_payload_axis_tready;
        assign m_udp_payload_axis_tlast = m_udp_payload_fifo_tlast;
        assign m_udp_payload_axis_tuser = m_udp_payload_fifo_tuser;
        
        /*
         * UDP Header FIFO
         */
 000001 reg [HEADER_FIFO_ADDR_WIDTH:0] header_fifo_wr_ptr_reg = {HEADER_FIFO_ADDR_WIDTH+1{1'b0}}, header_fifo_wr_ptr_next;
 000001 reg [HEADER_FIFO_ADDR_WIDTH:0] header_fifo_rd_ptr_reg = {HEADER_FIFO_ADDR_WIDTH+1{1'b0}}, header_fifo_rd_ptr_next;
        
        reg [47:0] eth_dest_mac_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [47:0] eth_src_mac_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [15:0] eth_type_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [3:0] ip_version_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [3:0] ip_ihl_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [5:0] ip_dscp_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [1:0] ip_ecn_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [15:0] ip_identification_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [2:0] ip_flags_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [12:0] ip_fragment_offset_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [7:0] ip_ttl_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [15:0] ip_header_checksum_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [31:0] ip_source_ip_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [31:0] ip_dest_ip_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [15:0] udp_source_port_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [15:0] udp_dest_port_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [15:0] udp_length_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        reg [15:0] udp_checksum_mem[(2**HEADER_FIFO_ADDR_WIDTH)-1:0];
        
 000001 reg [47:0] m_eth_dest_mac_reg = 48'd0;
 000001 reg [47:0] m_eth_src_mac_reg = 48'd0;
 000001 reg [15:0] m_eth_type_reg = 16'd0;
 000001 reg [3:0]  m_ip_version_reg = 4'd0;
 000001 reg [3:0]  m_ip_ihl_reg = 4'd0;
 000001 reg [5:0]  m_ip_dscp_reg = 6'd0;
 000001 reg [1:0]  m_ip_ecn_reg = 2'd0;
 000001 reg [15:0] m_ip_identification_reg = 16'd0;
 000001 reg [2:0]  m_ip_flags_reg = 3'd0;
 000001 reg [12:0] m_ip_fragment_offset_reg = 13'd0;
 000001 reg [7:0]  m_ip_ttl_reg = 8'd0;
 000001 reg [15:0] m_ip_header_checksum_reg = 16'd0;
 000001 reg [31:0] m_ip_source_ip_reg = 32'd0;
 000001 reg [31:0] m_ip_dest_ip_reg = 32'd0;
 000001 reg [15:0] m_udp_source_port_reg = 16'd0;
 000001 reg [15:0] m_udp_dest_port_reg = 16'd0;
 000001 reg [15:0] m_udp_length_reg = 16'd0;
 000001 reg [15:0] m_udp_checksum_reg = 16'd0;
        
 000001 reg m_udp_hdr_valid_reg = 1'b0, m_udp_hdr_valid_next;
        
        // full when first MSB different but rest same
        wire header_fifo_full = ((header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH] != header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH]) &&
                                 (header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0] == header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]));
        // empty when pointers match exactly
        wire header_fifo_empty = header_fifo_wr_ptr_reg == header_fifo_rd_ptr_reg;
        
        // control signals
        reg header_fifo_write;
        reg header_fifo_read;
        
        wire header_fifo_ready = !header_fifo_full;
        
        assign m_udp_hdr_valid = m_udp_hdr_valid_reg;
        
        assign m_eth_dest_mac = m_eth_dest_mac_reg;
        assign m_eth_src_mac = m_eth_src_mac_reg;
        assign m_eth_type = m_eth_type_reg;
        assign m_ip_version = m_ip_version_reg;
        assign m_ip_ihl = m_ip_ihl_reg;
        assign m_ip_dscp = m_ip_dscp_reg;
        assign m_ip_ecn = m_ip_ecn_reg;
        assign m_ip_length = m_udp_length_reg + 16'd20;
        assign m_ip_identification = m_ip_identification_reg;
        assign m_ip_flags = m_ip_flags_reg;
        assign m_ip_fragment_offset = m_ip_fragment_offset_reg;
        assign m_ip_ttl = m_ip_ttl_reg;
        assign m_ip_protocol = 8'h11;
        assign m_ip_header_checksum = m_ip_header_checksum_reg;
        assign m_ip_source_ip = m_ip_source_ip_reg;
        assign m_ip_dest_ip = m_ip_dest_ip_reg;
        assign m_udp_source_port = m_udp_source_port_reg;
        assign m_udp_dest_port = m_udp_dest_port_reg;
        assign m_udp_length = m_udp_length_reg;
        assign m_udp_checksum = m_udp_checksum_reg;
        
        // Write logic
 7806611 always @* begin
 7806611     header_fifo_write = 1'b0;
        
 7806611     header_fifo_wr_ptr_next = header_fifo_wr_ptr_reg;
        
~7806611     if (hdr_valid_reg) begin
                // input data valid
%000000         if (~header_fifo_full) begin
                    // not full, perform write
%000000             header_fifo_write = 1'b1;
%000000             header_fifo_wr_ptr_next = header_fifo_wr_ptr_reg + 1;
                end
            end
        end
        
 859379 always @(posedge clk) begin
 857900     if (rst) begin
 001479         header_fifo_wr_ptr_reg <= {HEADER_FIFO_ADDR_WIDTH+1{1'b0}};
 857900     end else begin
 857900         header_fifo_wr_ptr_reg <= header_fifo_wr_ptr_next;
            end
        
~859379     if (header_fifo_write) begin
%000000         eth_dest_mac_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= eth_dest_mac_reg;
%000000         eth_src_mac_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= eth_src_mac_reg;
%000000         eth_type_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= eth_type_reg;
%000000         ip_version_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_version_reg;
%000000         ip_ihl_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_ihl_reg;
%000000         ip_dscp_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_dscp_reg;
%000000         ip_ecn_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_ecn_reg;
%000000         ip_identification_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_identification_reg;
%000000         ip_flags_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_flags_reg;
%000000         ip_fragment_offset_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_fragment_offset_reg;
%000000         ip_ttl_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_ttl_reg;
%000000         ip_header_checksum_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_header_checksum_reg;
%000000         ip_source_ip_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_source_ip_reg;
%000000         ip_dest_ip_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= ip_dest_ip_reg;
%000000         udp_source_port_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= udp_source_port_reg;
%000000         udp_dest_port_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= udp_dest_port_reg;
%000000         udp_length_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= frame_ptr_reg;
%000000         udp_checksum_mem[header_fifo_wr_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]] <= checksum_reg[15:0];
            end
        end
        
        // Read logic
 7806611 always @* begin
 7806611     header_fifo_read = 1'b0;
        
 7806611     header_fifo_rd_ptr_next = header_fifo_rd_ptr_reg;
        
 7806611     m_udp_hdr_valid_next = m_udp_hdr_valid_reg;
        
~7806611     if (m_udp_hdr_ready || !m_udp_hdr_valid) begin
                // output data not valid OR currently being transferred
~7806611         if (!header_fifo_empty) begin
                    // not empty, perform read
%000000             header_fifo_read = 1'b1;
%000000             m_udp_hdr_valid_next = 1'b1;
%000000             header_fifo_rd_ptr_next = header_fifo_rd_ptr_reg + 1;
 7806611         end else begin
                    // empty, invalidate
 7806611             m_udp_hdr_valid_next = 1'b0;
                end
            end
        end
        
 859379 always @(posedge clk) begin
 857900     if (rst) begin
 001479         header_fifo_rd_ptr_reg <= {HEADER_FIFO_ADDR_WIDTH+1{1'b0}};
 001479         m_udp_hdr_valid_reg <= 1'b0;
 857900     end else begin
 857900         header_fifo_rd_ptr_reg <= header_fifo_rd_ptr_next;
 857900         m_udp_hdr_valid_reg <= m_udp_hdr_valid_next;
            end
        
~859379     if (header_fifo_read) begin
%000000         m_eth_dest_mac_reg <= eth_dest_mac_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_eth_src_mac_reg <= eth_src_mac_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_eth_type_reg <= eth_type_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_version_reg <= ip_version_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_ihl_reg <= ip_ihl_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_dscp_reg <= ip_dscp_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_ecn_reg <= ip_ecn_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_identification_reg <= ip_identification_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_flags_reg <= ip_flags_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_fragment_offset_reg <= ip_fragment_offset_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_ttl_reg <= ip_ttl_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_header_checksum_reg <= ip_header_checksum_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_source_ip_reg <= ip_source_ip_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_ip_dest_ip_reg <= ip_dest_ip_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_udp_source_port_reg <= udp_source_port_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_udp_dest_port_reg <= udp_dest_port_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_udp_length_reg <= udp_length_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
%000000         m_udp_checksum_reg <= udp_checksum_mem[header_fifo_rd_ptr_reg[HEADER_FIFO_ADDR_WIDTH-1:0]];
            end
        end
        
        assign s_udp_hdr_ready = s_udp_hdr_ready_reg;
        
        assign busy = busy_reg;
        
        integer i, word_cnt;
        
 7806611 always @* begin
 7806611     state_next = STATE_IDLE;
        
 7806611     s_udp_hdr_ready_next = 1'b0;
 7806611     s_udp_payload_axis_tready_next = 1'b0;
        
 7806611     store_udp_hdr = 1'b0;
 7806611     shift_payload_in = 1'b0;
        
 7806611     frame_ptr_next = frame_ptr_reg;
 7806611     checksum_next = checksum_reg;
 7806611     checksum_temp1_next = checksum_temp1_reg;
 7806611     checksum_temp2_next = checksum_temp2_reg;
        
 7806611     hdr_valid_next = 1'b0;
        
 7806611     case (state_reg)
 7806611         STATE_IDLE: begin
                    // idle state
 7806611             s_udp_hdr_ready_next = header_fifo_ready;
        
~7806611             if (s_udp_hdr_ready && s_udp_hdr_valid) begin
%000000                 store_udp_hdr = 1'b1;
%000000                 frame_ptr_next = 0;
                        // 16'h0011 = zero padded type field
                        // 16'h0010 = header length times two
%000000                 checksum_next = 16'h0011 + 16'h0010;
%000000                 checksum_temp1_next = s_ip_source_ip[31:16];
%000000                 checksum_temp2_next = s_ip_source_ip[15:0];
%000000                 s_udp_hdr_ready_next = 1'b0;
%000000                 state_next = STATE_SUM_HEADER;
 7806611             end else begin
 7806611                 state_next = STATE_IDLE;
                    end
                end
%000000         STATE_SUM_HEADER: begin
                    // sum pseudo header and header
%000000             checksum_next = checksum_reg + checksum_temp1_reg + checksum_temp2_reg;
%000000             checksum_temp1_next = ip_dest_ip_reg[31:16] + ip_dest_ip_reg[15:0];
%000000             checksum_temp2_next = udp_source_port_reg + udp_dest_port_reg;
%000000             frame_ptr_next = 8;
%000000             state_next = STATE_SUM_PAYLOAD;
                end
%000000         STATE_SUM_PAYLOAD: begin
                    // sum payload
%000000             shift_payload_in = 1'b1;
        
%000000             if (s_udp_payload_axis_tready && s_udp_payload_axis_tvalid) begin
%000000                 word_cnt = 1;
%000000                 for (i = 1; i <= 8; i = i + 1) begin
%000000                     if (s_udp_payload_axis_tkeep == 8'hff >> (8-i)) word_cnt = i;
                        end
        
%000000                 checksum_temp1_next = 0;
%000000                 checksum_temp2_next = 0;
        
%000000                 for (i = 0; i < 4; i = i + 1) begin
%000000                     if (s_udp_payload_axis_tkeep[i]) begin
%000000                         if (i & 1) begin
%000000                             checksum_temp1_next = checksum_temp1_next + {8'h00, s_udp_payload_axis_tdata[i*8 +: 8]};
%000000                         end else begin
%000000                             checksum_temp1_next = checksum_temp1_next + {s_udp_payload_axis_tdata[i*8 +: 8], 8'h00};
                                end
                            end
                        end
        
%000000                 for (i = 4; i < 8; i = i + 1) begin
%000000                     if (s_udp_payload_axis_tkeep[i]) begin
%000000                         if (i & 1) begin
%000000                             checksum_temp2_next = checksum_temp2_next + {8'h00, s_udp_payload_axis_tdata[i*8 +: 8]};
%000000                         end else begin
%000000                             checksum_temp2_next = checksum_temp2_next + {s_udp_payload_axis_tdata[i*8 +: 8], 8'h00};
                                end
                            end
                        end
        
                        // add length * 2 (two copies of length field in pseudo header)
%000000                 checksum_next = checksum_reg + checksum_temp1_reg + checksum_temp2_reg + (word_cnt << 1);
        
%000000                 frame_ptr_next = frame_ptr_reg + word_cnt;
        
%000000                 if (s_udp_payload_axis_tlast) begin
%000000                     state_next = STATE_FINISH_SUM_1;
%000000                 end else begin
%000000                     state_next = STATE_SUM_PAYLOAD;
                        end
%000000             end else begin
%000000                 state_next = STATE_SUM_PAYLOAD;
                    end
                end
%000000         STATE_FINISH_SUM_1: begin
                    // empty pipeline
%000000             checksum_next = checksum_reg + checksum_temp1_reg + checksum_temp2_reg;
%000000             state_next = STATE_FINISH_SUM_2;
                end
%000000         STATE_FINISH_SUM_2: begin
                    // add MSW (twice!) for proper ones complement sum
%000000             checksum_part = checksum_reg[15:0] + checksum_reg[31:16];
%000000             checksum_next = ~(checksum_part[15:0] + checksum_part[16]);
%000000             hdr_valid_next = 1;
%000000             state_next = STATE_IDLE;
                end
            endcase
        end
        
 859379 always @(posedge clk) begin
 857900     if (rst) begin
 001479         state_reg <= STATE_IDLE;
 001479         s_udp_hdr_ready_reg <= 1'b0;
 001479         s_udp_payload_axis_tready_reg <= 1'b0;
 001479         hdr_valid_reg <= 1'b0;
 001479         busy_reg <= 1'b0;
 857900     end else begin
 857900         state_reg <= state_next;
        
 857900         s_udp_hdr_ready_reg <= s_udp_hdr_ready_next;
 857900         s_udp_payload_axis_tready_reg <= s_udp_payload_axis_tready_next;
        
 857900         hdr_valid_reg <= hdr_valid_next;
        
 857900         busy_reg <= state_next != STATE_IDLE;
            end
        
 859379     frame_ptr_reg <= frame_ptr_next;
 859379     checksum_reg <= checksum_next;
 859379     checksum_temp1_reg <= checksum_temp1_next;
 859379     checksum_temp2_reg <= checksum_temp2_next;
        
            // datapath
~859379     if (store_udp_hdr) begin
%000000         eth_dest_mac_reg <= s_eth_dest_mac;
%000000         eth_src_mac_reg <= s_eth_src_mac;
%000000         eth_type_reg <= s_eth_type;
%000000         ip_version_reg <= s_ip_version;
%000000         ip_ihl_reg <= s_ip_ihl;
%000000         ip_dscp_reg <= s_ip_dscp;
%000000         ip_ecn_reg <= s_ip_ecn;
%000000         ip_identification_reg <= s_ip_identification;
%000000         ip_flags_reg <= s_ip_flags;
%000000         ip_fragment_offset_reg <= s_ip_fragment_offset;
%000000         ip_ttl_reg <= s_ip_ttl;
%000000         ip_header_checksum_reg <= s_ip_header_checksum;
%000000         ip_source_ip_reg <= s_ip_source_ip;
%000000         ip_dest_ip_reg <= s_ip_dest_ip;
%000000         udp_source_port_reg <= s_udp_source_port;
%000000         udp_dest_port_reg <= s_udp_dest_port;
            end
        end
        
        endmodule
        
        `resetall
        
