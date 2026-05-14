//      // verilator_coverage annotation
        /*
        
        Copyright (c) 2014-2018 Alex Forencich
        
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
         * UDP ethernet frame receiver (IP frame in, UDP frame out, 64 bit datapath)
         */
        module udp_ip_rx_64
        (
            input  wire        clk,
            input  wire        rst,
        
            /*
             * IP frame input
             */
            input  wire        s_ip_hdr_valid,
            output wire        s_ip_hdr_ready,
            input  wire [47:0] s_eth_dest_mac,
            input  wire [47:0] s_eth_src_mac,
            input  wire [15:0] s_eth_type,
            input  wire [3:0]  s_ip_version,
            input  wire [3:0]  s_ip_ihl,
            input  wire [5:0]  s_ip_dscp,
            input  wire [1:0]  s_ip_ecn,
            input  wire [15:0] s_ip_length,
            input  wire [15:0] s_ip_identification,
            input  wire [2:0]  s_ip_flags,
            input  wire [12:0] s_ip_fragment_offset,
            input  wire [7:0]  s_ip_ttl,
            input  wire [7:0]  s_ip_protocol,
            input  wire [15:0] s_ip_header_checksum,
            input  wire [31:0] s_ip_source_ip,
            input  wire [31:0] s_ip_dest_ip,
            input  wire [63:0] s_ip_payload_axis_tdata,
            input  wire [7:0]  s_ip_payload_axis_tkeep,
            input  wire        s_ip_payload_axis_tvalid,
            output wire        s_ip_payload_axis_tready,
            input  wire        s_ip_payload_axis_tlast,
            input  wire        s_ip_payload_axis_tuser,
        
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
            output wire        busy,
            output wire        error_header_early_termination,
            output wire        error_payload_early_termination
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
        
        This module receives an IP frame with header fields in parallel and payload on
        an AXI stream interface, decodes and strips the UDP header fields, then
        produces the header fields in parallel along with the UDP payload in a
        separate AXI stream.
        
        */
        
        localparam [2:0]
            STATE_IDLE = 3'd0,
            STATE_READ_HEADER = 3'd1,
            STATE_READ_PAYLOAD = 3'd2,
            STATE_READ_PAYLOAD_LAST = 3'd3,
            STATE_WAIT_LAST = 3'd4;
        
 000001 reg [2:0] state_reg = STATE_IDLE, state_next;
        
        // datapath control signals
        reg store_ip_hdr;
        reg store_hdr_word_0;
        reg store_last_word;
        
 000001 reg [15:0] word_count_reg = 16'd0, word_count_next;
        
 000001 reg [63:0] last_word_data_reg = 64'd0;
 000001 reg [7:0] last_word_keep_reg = 8'd0;
        
 000001 reg m_udp_hdr_valid_reg = 1'b0, m_udp_hdr_valid_next;
 000001 reg [47:0] m_eth_dest_mac_reg = 48'd0;
 000001 reg [47:0] m_eth_src_mac_reg = 48'd0;
 000001 reg [15:0] m_eth_type_reg = 16'd0;
 000001 reg [3:0] m_ip_version_reg = 4'd0;
 000001 reg [3:0] m_ip_ihl_reg = 4'd0;
 000001 reg [5:0] m_ip_dscp_reg = 6'd0;
 000001 reg [1:0] m_ip_ecn_reg = 2'd0;
 000001 reg [15:0] m_ip_length_reg = 16'd0;
 000001 reg [15:0] m_ip_identification_reg = 16'd0;
 000001 reg [2:0] m_ip_flags_reg = 3'd0;
 000001 reg [12:0] m_ip_fragment_offset_reg = 13'd0;
 000001 reg [7:0] m_ip_ttl_reg = 8'd0;
 000001 reg [7:0] m_ip_protocol_reg = 8'd0;
 000001 reg [15:0] m_ip_header_checksum_reg = 16'd0;
 000001 reg [31:0] m_ip_source_ip_reg = 32'd0;
 000001 reg [31:0] m_ip_dest_ip_reg = 32'd0;
 000001 reg [15:0] m_udp_source_port_reg = 16'd0;
 000001 reg [15:0] m_udp_dest_port_reg = 16'd0;
 000001 reg [15:0] m_udp_length_reg = 16'd0;
 000001 reg [15:0] m_udp_checksum_reg = 16'd0;
        
 000001 reg s_ip_hdr_ready_reg = 1'b0, s_ip_hdr_ready_next;
 000001 reg s_ip_payload_axis_tready_reg = 1'b0, s_ip_payload_axis_tready_next;
        
 000001 reg busy_reg = 1'b0;
 000001 reg error_header_early_termination_reg = 1'b0, error_header_early_termination_next;
 000001 reg error_payload_early_termination_reg = 1'b0, error_payload_early_termination_next;
        
        // internal datapath
        reg [63:0] m_udp_payload_axis_tdata_int;
        reg [7:0]  m_udp_payload_axis_tkeep_int;
        reg        m_udp_payload_axis_tvalid_int;
 000001 reg        m_udp_payload_axis_tready_int_reg = 1'b0;
        reg        m_udp_payload_axis_tlast_int;
        reg        m_udp_payload_axis_tuser_int;
        wire       m_udp_payload_axis_tready_int_early;
        
        assign s_ip_hdr_ready = s_ip_hdr_ready_reg;
        assign s_ip_payload_axis_tready = s_ip_payload_axis_tready_reg;
        
        assign m_udp_hdr_valid = m_udp_hdr_valid_reg;
        assign m_eth_dest_mac = m_eth_dest_mac_reg;
        assign m_eth_src_mac = m_eth_src_mac_reg;
        assign m_eth_type = m_eth_type_reg;
        assign m_ip_version = m_ip_version_reg;
        assign m_ip_ihl = m_ip_ihl_reg;
        assign m_ip_dscp = m_ip_dscp_reg;
        assign m_ip_ecn = m_ip_ecn_reg;
        assign m_ip_length = m_ip_length_reg;
        assign m_ip_identification = m_ip_identification_reg;
        assign m_ip_flags = m_ip_flags_reg;
        assign m_ip_fragment_offset = m_ip_fragment_offset_reg;
        assign m_ip_ttl = m_ip_ttl_reg;
        assign m_ip_protocol = m_ip_protocol_reg;
        assign m_ip_header_checksum = m_ip_header_checksum_reg;
        assign m_ip_source_ip = m_ip_source_ip_reg;
        assign m_ip_dest_ip = m_ip_dest_ip_reg;
        assign m_udp_source_port = m_udp_source_port_reg;
        assign m_udp_dest_port = m_udp_dest_port_reg;
        assign m_udp_length = m_udp_length_reg;
        assign m_udp_checksum = m_udp_checksum_reg;
        
        assign busy = busy_reg;
        assign error_header_early_termination = error_header_early_termination_reg;
        assign error_payload_early_termination = error_payload_early_termination_reg;
        
 000036 function [3:0] keep2count;
            input [7:0] k;
 000036     casez (k)
%000000         8'bzzzzzzz0: keep2count = 4'd0;
%000000         8'bzzzzzz01: keep2count = 4'd1;
 000009         8'bzzzzz011: keep2count = 4'd2;
%000000         8'bzzzz0111: keep2count = 4'd3;
 000009         8'bzzz01111: keep2count = 4'd4;
%000000         8'bzz011111: keep2count = 4'd5;
%000000         8'bz0111111: keep2count = 4'd6;
%000000         8'b01111111: keep2count = 4'd7;
 000018         8'b11111111: keep2count = 4'd8;
            endcase
        endfunction
        
 000036 function [7:0] count2keep;
            input [3:0] k;
 000036     case (k)
%000000         4'd0: count2keep = 8'b00000000;
%000000         4'd1: count2keep = 8'b00000001;
 000009         4'd2: count2keep = 8'b00000011;
%000000         4'd3: count2keep = 8'b00000111;
 000009         4'd4: count2keep = 8'b00001111;
%000000         4'd5: count2keep = 8'b00011111;
%000000         4'd6: count2keep = 8'b00111111;
%000000         4'd7: count2keep = 8'b01111111;
 000018         4'd8: count2keep = 8'b11111111;
            endcase
        endfunction
        
 7806611 always @* begin
 7806611     state_next = STATE_IDLE;
        
 7806611     s_ip_hdr_ready_next = 1'b0;
 7806611     s_ip_payload_axis_tready_next = 1'b0;
        
 7806611     store_ip_hdr = 1'b0;
 7806611     store_hdr_word_0 = 1'b0;
        
 7806611     store_last_word = 1'b0;
        
 7806611     word_count_next = word_count_reg;
        
 7806611     m_udp_hdr_valid_next = m_udp_hdr_valid_reg && !m_udp_hdr_ready;
        
 7806611     error_header_early_termination_next = 1'b0;
 7806611     error_payload_early_termination_next = 1'b0;
        
 7806611     m_udp_payload_axis_tdata_int = 64'd0;
 7806611     m_udp_payload_axis_tkeep_int = 8'd0;
 7806611     m_udp_payload_axis_tvalid_int = 1'b0;
 7806611     m_udp_payload_axis_tlast_int = 1'b0;
 7806611     m_udp_payload_axis_tuser_int = 1'b0;
        
 7806611     case (state_reg)
 7784796         STATE_IDLE: begin
                    // idle state - wait for header
 7784796             s_ip_hdr_ready_next = !m_udp_hdr_valid_next;
        
 7782056             if (s_ip_hdr_ready && s_ip_hdr_valid) begin
 002740                 s_ip_hdr_ready_next = 1'b0;
 002740                 s_ip_payload_axis_tready_next = 1'b1;
 002740                 store_ip_hdr = 1'b1;
 002740                 state_next = STATE_READ_HEADER;
 7782056             end else begin
 7782056                 state_next = STATE_IDLE;
                    end
                end
 002740         STATE_READ_HEADER: begin
                    // read header state
 002740             s_ip_payload_axis_tready_next = 1'b1;
        
 002740             word_count_next = {s_ip_payload_axis_tdata[39:32], s_ip_payload_axis_tdata[47:40]} - 16'd8;
        
~002740             if (s_ip_payload_axis_tready && s_ip_payload_axis_tvalid) begin
                        // word transfer in - store it
 002740                 state_next = STATE_READ_HEADER;
        
 002740                 store_hdr_word_0 = 1'b1;
 002740                 m_udp_hdr_valid_next = 1'b1;
 002740                 s_ip_payload_axis_tready_next = m_udp_payload_axis_tready_int_early;
 002740                 state_next = STATE_READ_PAYLOAD;
        
~002740                 if (s_ip_payload_axis_tlast) begin
%000000                     error_header_early_termination_next = 1'b1;
%000000                     m_udp_hdr_valid_next = 1'b0;
%000000                     s_ip_hdr_ready_next = !m_udp_hdr_valid_next;
%000000                     s_ip_payload_axis_tready_next = 1'b0;
%000000                     state_next = STATE_IDLE;
                        end
        
%000000             end else begin
%000000                 state_next = STATE_READ_HEADER;
                    end
                end
 019075         STATE_READ_PAYLOAD: begin
                    // read payload
 019075             s_ip_payload_axis_tready_next = m_udp_payload_axis_tready_int_early;
        
 019075             m_udp_payload_axis_tdata_int = s_ip_payload_axis_tdata;
 019075             m_udp_payload_axis_tkeep_int = s_ip_payload_axis_tkeep;
 019075             m_udp_payload_axis_tlast_int = s_ip_payload_axis_tlast;
 019075             m_udp_payload_axis_tuser_int = s_ip_payload_axis_tuser;
        
 019075             store_last_word = 1'b1;
        
 019012             if (s_ip_payload_axis_tready && s_ip_payload_axis_tvalid) begin
                        // word transfer through
 019012                 word_count_next = word_count_reg - 16'd8;
 019012                 m_udp_payload_axis_tvalid_int = 1'b1;
 018976                 if (word_count_reg <= 8) begin
                            // have entire payload
 000036                     m_udp_payload_axis_tkeep_int = s_ip_payload_axis_tkeep & count2keep(word_count_reg);
~000036                     if (s_ip_payload_axis_tlast) begin
~000036                         if (keep2count(s_ip_payload_axis_tkeep) < word_count_reg[4:0]) begin
                                    // end of frame, but length does not match
%000000                             error_payload_early_termination_next = 1'b1;
%000000                             m_udp_payload_axis_tuser_int = 1'b1;
                                end
 000036                         s_ip_payload_axis_tready_next = 1'b0;
 000036                         s_ip_hdr_ready_next = !m_udp_hdr_valid_next;
 000036                         state_next = STATE_IDLE;
%000000                     end else begin
%000000                         m_udp_payload_axis_tvalid_int = 1'b0;
%000000                         state_next = STATE_READ_PAYLOAD_LAST;
                            end
 018976                 end else begin
 016497                     if (s_ip_payload_axis_tlast) begin
                                // end of frame, but length does not match
 002479                         error_payload_early_termination_next = 1'b1;
 002479                         m_udp_payload_axis_tuser_int = 1'b1;
 002479                         s_ip_payload_axis_tready_next = 1'b0;
 002479                         s_ip_hdr_ready_next = !m_udp_hdr_valid_next;
 002479                         state_next = STATE_IDLE;
 016497                     end else begin
 016497                         state_next = STATE_READ_PAYLOAD;
                            end
                        end
 000063             end else begin
 000063                 state_next = STATE_READ_PAYLOAD;
                    end
                end
%000000         STATE_READ_PAYLOAD_LAST: begin
                    // read and discard until end of frame
%000000             s_ip_payload_axis_tready_next = m_udp_payload_axis_tready_int_early;
        
%000000             m_udp_payload_axis_tdata_int = last_word_data_reg;
%000000             m_udp_payload_axis_tkeep_int = last_word_keep_reg;
%000000             m_udp_payload_axis_tlast_int = s_ip_payload_axis_tlast;
%000000             m_udp_payload_axis_tuser_int = s_ip_payload_axis_tuser;
        
%000000             if (s_ip_payload_axis_tready && s_ip_payload_axis_tvalid) begin
%000000                 if (s_ip_payload_axis_tlast) begin
%000000                     s_ip_hdr_ready_next = !m_udp_hdr_valid_next;
%000000                     s_ip_payload_axis_tready_next = 1'b0;
%000000                     m_udp_payload_axis_tvalid_int = 1'b1;
%000000                     state_next = STATE_IDLE;
%000000                 end else begin
%000000                     state_next = STATE_READ_PAYLOAD_LAST;
                        end
%000000             end else begin
%000000                 state_next = STATE_READ_PAYLOAD_LAST;
                    end
                end
%000000         STATE_WAIT_LAST: begin
                    // wait for end of frame; read and discard
%000000             s_ip_payload_axis_tready_next = 1'b1;
        
%000000             if (s_ip_payload_axis_tready && s_ip_payload_axis_tvalid) begin
%000000                 if (s_ip_payload_axis_tlast) begin
%000000                     s_ip_hdr_ready_next = !m_udp_hdr_valid_next;
%000000                     s_ip_payload_axis_tready_next = 1'b0;
%000000                     state_next = STATE_IDLE;
%000000                 end else begin
%000000                     state_next = STATE_WAIT_LAST;
                        end
%000000             end else begin
%000000                 state_next = STATE_WAIT_LAST;
                    end
                end
            endcase
        end
        
 859379 always @(posedge clk) begin
 857900     if (rst) begin
 001479         state_reg <= STATE_IDLE;
 001479         s_ip_hdr_ready_reg <= 1'b0;
 001479         s_ip_payload_axis_tready_reg <= 1'b0;
 001479         m_udp_hdr_valid_reg <= 1'b0;
 001479         busy_reg <= 1'b0;
 001479         error_header_early_termination_reg <= 1'b0;
 001479         error_payload_early_termination_reg <= 1'b0;
 857900     end else begin
 857900         state_reg <= state_next;
        
 857900         s_ip_hdr_ready_reg <= s_ip_hdr_ready_next;
 857900         s_ip_payload_axis_tready_reg <= s_ip_payload_axis_tready_next;
        
 857900         m_udp_hdr_valid_reg <= m_udp_hdr_valid_next;
        
 857900         error_header_early_termination_reg <= error_header_early_termination_next;
 857900         error_payload_early_termination_reg <= error_payload_early_termination_next;
        
 857900         busy_reg <= state_next != STATE_IDLE;
            end
        
 859379     word_count_reg <= word_count_next;
        
            // datapath
 859105     if (store_ip_hdr) begin
 000274         m_eth_dest_mac_reg <= s_eth_dest_mac;
 000274         m_eth_src_mac_reg <= s_eth_src_mac;
 000274         m_eth_type_reg <= s_eth_type;
 000274         m_ip_version_reg <= s_ip_version;
 000274         m_ip_ihl_reg <= s_ip_ihl;
 000274         m_ip_dscp_reg <= s_ip_dscp;
 000274         m_ip_ecn_reg <= s_ip_ecn;
 000274         m_ip_length_reg <= s_ip_length;
 000274         m_ip_identification_reg <= s_ip_identification;
 000274         m_ip_flags_reg <= s_ip_flags;
 000274         m_ip_fragment_offset_reg <= s_ip_fragment_offset;
 000274         m_ip_ttl_reg <= s_ip_ttl;
 000274         m_ip_protocol_reg <= s_ip_protocol;
 000274         m_ip_header_checksum_reg <= s_ip_header_checksum;
 000274         m_ip_source_ip_reg <= s_ip_source_ip;
 000274         m_ip_dest_ip_reg <= s_ip_dest_ip;
            end
        
 857421     if (store_last_word) begin
 001958         last_word_data_reg <= m_udp_payload_axis_tdata_int;
 001958         last_word_keep_reg <= m_udp_payload_axis_tkeep_int;
            end
        
 859105     if (store_hdr_word_0) begin
 000274         m_udp_source_port_reg[15: 8] <= s_ip_payload_axis_tdata[ 7: 0];
 000274         m_udp_source_port_reg[ 7: 0] <= s_ip_payload_axis_tdata[15: 8];
 000274         m_udp_dest_port_reg[15: 8] <= s_ip_payload_axis_tdata[23:16];
 000274         m_udp_dest_port_reg[ 7: 0] <= s_ip_payload_axis_tdata[31:24];
 000274         m_udp_length_reg[15: 8] <= s_ip_payload_axis_tdata[39:32];
 000274         m_udp_length_reg[ 7: 0] <= s_ip_payload_axis_tdata[47:40];
 000274         m_udp_checksum_reg[15: 8] <= s_ip_payload_axis_tdata[55:48];
 000274         m_udp_checksum_reg[ 7: 0] <= s_ip_payload_axis_tdata[63:56];
            end
        end
        
        // output datapath logic
 000001 reg [63:0] m_udp_payload_axis_tdata_reg = 64'd0;
 000001 reg [7:0]  m_udp_payload_axis_tkeep_reg = 8'd0;
 000001 reg        m_udp_payload_axis_tvalid_reg = 1'b0, m_udp_payload_axis_tvalid_next;
 000001 reg        m_udp_payload_axis_tlast_reg = 1'b0;
 000001 reg        m_udp_payload_axis_tuser_reg = 1'b0;
        
 000001 reg [63:0] temp_m_udp_payload_axis_tdata_reg = 64'd0;
 000001 reg [7:0]  temp_m_udp_payload_axis_tkeep_reg = 8'd0;
 000001 reg        temp_m_udp_payload_axis_tvalid_reg = 1'b0, temp_m_udp_payload_axis_tvalid_next;
 000001 reg        temp_m_udp_payload_axis_tlast_reg = 1'b0;
 000001 reg        temp_m_udp_payload_axis_tuser_reg = 1'b0;
        
        // datapath control
        reg store_udp_payload_int_to_output;
        reg store_udp_payload_int_to_temp;
        reg store_udp_payload_axis_temp_to_output;
        
        assign m_udp_payload_axis_tdata = m_udp_payload_axis_tdata_reg;
        assign m_udp_payload_axis_tkeep = m_udp_payload_axis_tkeep_reg;
        assign m_udp_payload_axis_tvalid = m_udp_payload_axis_tvalid_reg;
        assign m_udp_payload_axis_tlast = m_udp_payload_axis_tlast_reg;
        assign m_udp_payload_axis_tuser = m_udp_payload_axis_tuser_reg;
        
        // enable ready input next cycle if output is ready or if both output registers are empty
        assign m_udp_payload_axis_tready_int_early = m_udp_payload_axis_tready || (!temp_m_udp_payload_axis_tvalid_reg && !m_udp_payload_axis_tvalid_reg);
        
 7806611 always @* begin
            // transfer sink ready state to source
 7806611     m_udp_payload_axis_tvalid_next = m_udp_payload_axis_tvalid_reg;
 7806611     temp_m_udp_payload_axis_tvalid_next = temp_m_udp_payload_axis_tvalid_reg;
        
 7806611     store_udp_payload_int_to_output = 1'b0;
 7806611     store_udp_payload_int_to_temp = 1'b0;
 7806611     store_udp_payload_axis_temp_to_output = 1'b0;
            
 7793229     if (m_udp_payload_axis_tready_int_reg) begin
                // input is ready
~7793229         if (m_udp_payload_axis_tready || !m_udp_payload_axis_tvalid_reg) begin
                    // output is ready or currently not valid, transfer data to output
 7793229             m_udp_payload_axis_tvalid_next = m_udp_payload_axis_tvalid_int;
 7793229             store_udp_payload_int_to_output = 1'b1;
%000000         end else begin
                    // output is not ready, store input in temp
%000000             temp_m_udp_payload_axis_tvalid_next = m_udp_payload_axis_tvalid_int;
%000000             store_udp_payload_int_to_temp = 1'b1;
                end
~013382     end else if (m_udp_payload_axis_tready) begin
                // input is not ready, but output is ready
 013382         m_udp_payload_axis_tvalid_next = temp_m_udp_payload_axis_tvalid_reg;
 013382         temp_m_udp_payload_axis_tvalid_next = 1'b0;
 013382         store_udp_payload_axis_temp_to_output = 1'b1;
            end
        end
        
 859379 always @(posedge clk) begin
 859379     m_udp_payload_axis_tvalid_reg <= m_udp_payload_axis_tvalid_next;
 859379     m_udp_payload_axis_tready_int_reg <= m_udp_payload_axis_tready_int_early;
 859379     temp_m_udp_payload_axis_tvalid_reg <= temp_m_udp_payload_axis_tvalid_next;
        
            // datapath
 857899     if (store_udp_payload_int_to_output) begin
 857899         m_udp_payload_axis_tdata_reg <= m_udp_payload_axis_tdata_int;
 857899         m_udp_payload_axis_tkeep_reg <= m_udp_payload_axis_tkeep_int;
 857899         m_udp_payload_axis_tlast_reg <= m_udp_payload_axis_tlast_int;
 857899         m_udp_payload_axis_tuser_reg <= m_udp_payload_axis_tuser_int;
~001480     end else if (store_udp_payload_axis_temp_to_output) begin
 001480         m_udp_payload_axis_tdata_reg <= temp_m_udp_payload_axis_tdata_reg;
 001480         m_udp_payload_axis_tkeep_reg <= temp_m_udp_payload_axis_tkeep_reg;
 001480         m_udp_payload_axis_tlast_reg <= temp_m_udp_payload_axis_tlast_reg;
 001480         m_udp_payload_axis_tuser_reg <= temp_m_udp_payload_axis_tuser_reg;
            end
        
~859379     if (store_udp_payload_int_to_temp) begin
%000000         temp_m_udp_payload_axis_tdata_reg <= m_udp_payload_axis_tdata_int;
%000000         temp_m_udp_payload_axis_tkeep_reg <= m_udp_payload_axis_tkeep_int;
%000000         temp_m_udp_payload_axis_tlast_reg <= m_udp_payload_axis_tlast_int;
%000000         temp_m_udp_payload_axis_tuser_reg <= m_udp_payload_axis_tuser_int;
            end
        
 857900     if (rst) begin
 001479         m_udp_payload_axis_tvalid_reg <= 1'b0;
 001479         m_udp_payload_axis_tready_int_reg <= 1'b0;
 001479         temp_m_udp_payload_axis_tvalid_reg <= 1'b0;
            end
        end
        
        endmodule
        
        `resetall
        
