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
         * IP ethernet frame transmitter (IP frame in, Ethernet frame out, 64 bit datapath)
         */
        module ip_eth_tx_64
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
            input  wire [5:0]  s_ip_dscp,
            input  wire [1:0]  s_ip_ecn,
            input  wire [15:0] s_ip_length,
            input  wire [15:0] s_ip_identification,
            input  wire [2:0]  s_ip_flags,
            input  wire [12:0] s_ip_fragment_offset,
            input  wire [7:0]  s_ip_ttl,
            input  wire [7:0]  s_ip_protocol,
            input  wire [31:0] s_ip_source_ip,
            input  wire [31:0] s_ip_dest_ip,
            input  wire [63:0] s_ip_payload_axis_tdata,
            input  wire [7:0]  s_ip_payload_axis_tkeep,
            input  wire        s_ip_payload_axis_tvalid,
            output wire        s_ip_payload_axis_tready,
            input  wire        s_ip_payload_axis_tlast,
            input  wire        s_ip_payload_axis_tuser,
        
            /*
             * Ethernet frame output
             */
            output wire        m_eth_hdr_valid,
            input  wire        m_eth_hdr_ready,
            output wire [47:0] m_eth_dest_mac,
            output wire [47:0] m_eth_src_mac,
            output wire [15:0] m_eth_type,
            output wire [63:0] m_eth_payload_axis_tdata,
            output wire [7:0]  m_eth_payload_axis_tkeep,
            output wire        m_eth_payload_axis_tvalid,
            input  wire        m_eth_payload_axis_tready,
            output wire        m_eth_payload_axis_tlast,
            output wire        m_eth_payload_axis_tuser,
        
            /*
             * Status signals
             */
            output wire        busy,
            output wire        error_payload_early_termination
        );
        
        /*
        
        IP Frame
        
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
         payload                     length octets
        
        This module receives an IP frame with header fields in parallel along with the
        payload in an AXI stream, combines the header with the payload, passes through
        the Ethernet headers, and transmits the complete Ethernet payload on an AXI
        interface.
        
        */
        
        localparam [2:0]
            STATE_IDLE = 3'd0,
            STATE_WRITE_HEADER = 3'd1,
            STATE_WRITE_HEADER_LAST = 3'd2,
            STATE_WRITE_PAYLOAD = 3'd3,
            STATE_WRITE_PAYLOAD_LAST = 3'd4,
            STATE_WAIT_LAST = 3'd5;
        
 000001 reg [2:0] state_reg = STATE_IDLE, state_next;
        
        // datapath control signals
        reg store_ip_hdr;
        reg store_last_word;
        
 000001 reg [5:0] hdr_ptr_reg = 6'd0, hdr_ptr_next;
 000001 reg [15:0] word_count_reg = 16'd0, word_count_next;
        
        reg flush_save;
        reg transfer_in_save;
        
        reg [19:0] hdr_sum_temp;
 000001 reg [19:0] hdr_sum_reg = 20'd0, hdr_sum_next;
        
 000001 reg [63:0] last_word_data_reg = 64'd0;
 000001 reg [7:0] last_word_keep_reg = 8'd0;
        
 000001 reg [5:0] ip_dscp_reg = 6'd0;
 000001 reg [1:0] ip_ecn_reg = 2'd0;
 000001 reg [15:0] ip_length_reg = 16'd0;
 000001 reg [15:0] ip_identification_reg = 16'd0;
 000001 reg [2:0] ip_flags_reg = 3'd0;
 000001 reg [12:0] ip_fragment_offset_reg = 13'd0;
 000001 reg [7:0] ip_ttl_reg = 8'd0;
 000001 reg [7:0] ip_protocol_reg = 8'd0;
 000001 reg [31:0] ip_source_ip_reg = 32'd0;
 000001 reg [31:0] ip_dest_ip_reg = 32'd0;
        
 000001 reg s_ip_hdr_ready_reg = 1'b0, s_ip_hdr_ready_next;
 000001 reg s_ip_payload_axis_tready_reg = 1'b0, s_ip_payload_axis_tready_next;
        
 000001 reg m_eth_hdr_valid_reg = 1'b0, m_eth_hdr_valid_next;
 000001 reg [47:0] m_eth_dest_mac_reg = 48'd0;
 000001 reg [47:0] m_eth_src_mac_reg = 48'd0;
 000001 reg [15:0] m_eth_type_reg = 16'd0;
        
 000001 reg busy_reg = 1'b0;
 000001 reg error_payload_early_termination_reg = 1'b0, error_payload_early_termination_next;
        
 000001 reg [63:0] save_ip_payload_axis_tdata_reg = 64'd0;
 000001 reg [7:0] save_ip_payload_axis_tkeep_reg = 8'd0;
 000001 reg save_ip_payload_axis_tlast_reg = 1'b0;
 000001 reg save_ip_payload_axis_tuser_reg = 1'b0;
        
        reg [63:0] shift_ip_payload_axis_tdata;
        reg [7:0] shift_ip_payload_axis_tkeep;
        reg shift_ip_payload_axis_tvalid;
        reg shift_ip_payload_axis_tlast;
        reg shift_ip_payload_axis_tuser;
        reg shift_ip_payload_s_tready;
 000001 reg shift_ip_payload_extra_cycle_reg = 1'b0;
        
        // internal datapath
        reg [63:0] m_eth_payload_axis_tdata_int;
        reg [7:0]  m_eth_payload_axis_tkeep_int;
        reg        m_eth_payload_axis_tvalid_int;
 000001 reg        m_eth_payload_axis_tready_int_reg = 1'b0;
        reg        m_eth_payload_axis_tlast_int;
        reg        m_eth_payload_axis_tuser_int;
        wire       m_eth_payload_axis_tready_int_early;
        
        assign s_ip_hdr_ready = s_ip_hdr_ready_reg;
        assign s_ip_payload_axis_tready = s_ip_payload_axis_tready_reg;
        
        assign m_eth_hdr_valid = m_eth_hdr_valid_reg;
        assign m_eth_dest_mac = m_eth_dest_mac_reg;
        assign m_eth_src_mac = m_eth_src_mac_reg;
        assign m_eth_type = m_eth_type_reg;
        
        assign busy = busy_reg;
        assign error_payload_early_termination = error_payload_early_termination_reg;
        
%000000 function [3:0] keep2count;
            input [7:0] k;
%000000     casez (k)
%000000         8'bzzzzzzz0: keep2count = 4'd0;
%000000         8'bzzzzzz01: keep2count = 4'd1;
%000000         8'bzzzzz011: keep2count = 4'd2;
%000000         8'bzzzz0111: keep2count = 4'd3;
%000000         8'bzzz01111: keep2count = 4'd4;
%000000         8'bzz011111: keep2count = 4'd5;
%000000         8'bz0111111: keep2count = 4'd6;
%000000         8'b01111111: keep2count = 4'd7;
%000000         8'b11111111: keep2count = 4'd8;
            endcase
        endfunction
        
%000000 function [7:0] count2keep;
            input [3:0] k;
%000000     case (k)
%000000         4'd0: count2keep = 8'b00000000;
%000000         4'd1: count2keep = 8'b00000001;
%000000         4'd2: count2keep = 8'b00000011;
%000000         4'd3: count2keep = 8'b00000111;
%000000         4'd4: count2keep = 8'b00001111;
%000000         4'd5: count2keep = 8'b00011111;
%000000         4'd6: count2keep = 8'b00111111;
%000000         4'd7: count2keep = 8'b01111111;
%000000         4'd8: count2keep = 8'b11111111;
            endcase
        endfunction
        
 7806614 always @* begin
 7806614     shift_ip_payload_axis_tdata[31:0] = save_ip_payload_axis_tdata_reg[63:32];
 7806614     shift_ip_payload_axis_tkeep[3:0] = save_ip_payload_axis_tkeep_reg[7:4];
        
~7806614     if (shift_ip_payload_extra_cycle_reg) begin
%000000         shift_ip_payload_axis_tdata[63:32] = 32'd0;
%000000         shift_ip_payload_axis_tkeep[7:4] = 4'd0;
%000000         shift_ip_payload_axis_tvalid = 1'b1;
%000000         shift_ip_payload_axis_tlast = save_ip_payload_axis_tlast_reg;
%000000         shift_ip_payload_axis_tuser = save_ip_payload_axis_tuser_reg;
%000000         shift_ip_payload_s_tready = flush_save;
 7806614     end else begin
 7806614         shift_ip_payload_axis_tdata[63:32] = s_ip_payload_axis_tdata[31:0];
 7806614         shift_ip_payload_axis_tkeep[7:4] = s_ip_payload_axis_tkeep[3:0];
 7806614         shift_ip_payload_axis_tvalid = s_ip_payload_axis_tvalid;
 7806614         shift_ip_payload_axis_tlast = (s_ip_payload_axis_tlast && (s_ip_payload_axis_tkeep[7:4] == 0));
 7806614         shift_ip_payload_axis_tuser = (s_ip_payload_axis_tuser && (s_ip_payload_axis_tkeep[7:4] == 0));
 7806614         shift_ip_payload_s_tready = !(s_ip_payload_axis_tlast && s_ip_payload_axis_tvalid && transfer_in_save) && !save_ip_payload_axis_tlast_reg;
            end
        end
        
 7806614 always @* begin
 7806614     state_next = STATE_IDLE;
        
 7806614     s_ip_hdr_ready_next = 1'b0;
 7806614     s_ip_payload_axis_tready_next = 1'b0;
        
 7806614     store_ip_hdr = 1'b0;
        
 7806614     store_last_word = 1'b0;
        
 7806614     flush_save = 1'b0;
 7806614     transfer_in_save = 1'b0;
        
 7806614     hdr_ptr_next = hdr_ptr_reg;
 7806614     word_count_next = word_count_reg;
        
 7806614     hdr_sum_temp = 20'd0;
 7806614     hdr_sum_next = hdr_sum_reg;
        
 7806614     m_eth_hdr_valid_next = m_eth_hdr_valid_reg && !m_eth_hdr_ready;
        
 7806614     error_payload_early_termination_next = 1'b0;
        
 7806614     m_eth_payload_axis_tdata_int = 1'b0;
 7806614     m_eth_payload_axis_tkeep_int = 1'b0;
 7806614     m_eth_payload_axis_tvalid_int = 1'b0;
 7806614     m_eth_payload_axis_tlast_int = 1'b0;
 7806614     m_eth_payload_axis_tuser_int = 1'b0;
        
 7806614     case (state_reg)
 7806614         STATE_IDLE: begin
                    // idle state - wait for data
 7806614             hdr_ptr_next = 6'd0;
 7806614             flush_save = 1'b1;
 7806614             s_ip_hdr_ready_next = !m_eth_hdr_valid_next;
        
~7806614             if (s_ip_hdr_ready && s_ip_hdr_valid) begin
%000000                 store_ip_hdr = 1'b1;
%000000                 hdr_sum_next = {4'd4, 4'd5, s_ip_dscp, s_ip_ecn} +
%000000                                s_ip_length +
%000000                                s_ip_identification +
%000000                                {s_ip_flags, s_ip_fragment_offset} +
%000000                                {s_ip_ttl, s_ip_protocol} +
%000000                                s_ip_source_ip[31:16] +
%000000                                s_ip_source_ip[15: 0] +
%000000                                s_ip_dest_ip[31:16] +
%000000                                s_ip_dest_ip[15: 0];
%000000                 s_ip_hdr_ready_next = 1'b0;
%000000                 m_eth_hdr_valid_next = 1'b1;
%000000                 if (m_eth_payload_axis_tready_int_reg) begin
%000000                     m_eth_payload_axis_tvalid_int = 1'b1;
%000000                     m_eth_payload_axis_tdata_int[ 7: 0] = {4'd4, 4'd5}; // ip_version, ip_ihl
%000000                     m_eth_payload_axis_tdata_int[15: 8] = {s_ip_dscp, s_ip_ecn};
%000000                     m_eth_payload_axis_tdata_int[23:16] = s_ip_length[15: 8];
%000000                     m_eth_payload_axis_tdata_int[31:24] = s_ip_length[ 7: 0];
%000000                     m_eth_payload_axis_tdata_int[39:32] = s_ip_identification[15: 8];
%000000                     m_eth_payload_axis_tdata_int[47:40] = s_ip_identification[ 7: 0];
%000000                     m_eth_payload_axis_tdata_int[55:48] = {s_ip_flags, s_ip_fragment_offset[12: 8]};
%000000                     m_eth_payload_axis_tdata_int[63:56] = s_ip_fragment_offset[ 7: 0];
%000000                     m_eth_payload_axis_tkeep_int = 8'hff;
%000000                     hdr_ptr_next = 6'd8;
                        end
%000000                 state_next = STATE_WRITE_HEADER;
 7806614             end else begin
 7806614                 state_next = STATE_IDLE;
                    end
                end
%000000         STATE_WRITE_HEADER: begin
                    // write header
%000000             word_count_next = ip_length_reg - 5*4 + 4;
        
%000000             if (m_eth_payload_axis_tready_int_reg) begin
%000000                 hdr_ptr_next = hdr_ptr_reg + 6'd8;
%000000                 m_eth_payload_axis_tvalid_int = 1'b1;
%000000                 state_next = STATE_WRITE_HEADER;
%000000                 case (hdr_ptr_reg)
%000000                     6'h00: begin
%000000                         m_eth_payload_axis_tdata_int[ 7: 0] = {4'd4, 4'd5}; // ip_version, ip_ihl
%000000                         m_eth_payload_axis_tdata_int[15: 8] = {ip_dscp_reg, ip_ecn_reg};
%000000                         m_eth_payload_axis_tdata_int[23:16] = ip_length_reg[15: 8];
%000000                         m_eth_payload_axis_tdata_int[31:24] = ip_length_reg[ 7: 0];
%000000                         m_eth_payload_axis_tdata_int[39:32] = ip_identification_reg[15: 8];
%000000                         m_eth_payload_axis_tdata_int[47:40] = ip_identification_reg[ 7: 0];
%000000                         m_eth_payload_axis_tdata_int[55:48] = {ip_flags_reg, ip_fragment_offset_reg[12: 8]};
%000000                         m_eth_payload_axis_tdata_int[63:56] = ip_fragment_offset_reg[ 7: 0];
%000000                         m_eth_payload_axis_tkeep_int = 8'hff;
                            end
%000000                     6'h08: begin
%000000                         hdr_sum_temp = hdr_sum_reg[15:0] + hdr_sum_reg[19:16];
%000000                         hdr_sum_temp = hdr_sum_temp[15:0] + hdr_sum_temp[16];
%000000                         m_eth_payload_axis_tdata_int[ 7: 0] = ip_ttl_reg;
%000000                         m_eth_payload_axis_tdata_int[15: 8] = ip_protocol_reg;
%000000                         m_eth_payload_axis_tdata_int[23:16] = ~hdr_sum_temp[15: 8];
%000000                         m_eth_payload_axis_tdata_int[31:24] = ~hdr_sum_temp[ 7: 0];
%000000                         m_eth_payload_axis_tdata_int[39:32] = ip_source_ip_reg[31:24];
%000000                         m_eth_payload_axis_tdata_int[47:40] = ip_source_ip_reg[23:16];
%000000                         m_eth_payload_axis_tdata_int[55:48] = ip_source_ip_reg[15: 8];
%000000                         m_eth_payload_axis_tdata_int[63:56] = ip_source_ip_reg[ 7: 0];
%000000                         m_eth_payload_axis_tkeep_int = 8'hff;
%000000                         s_ip_payload_axis_tready_next = m_eth_payload_axis_tready_int_early;
%000000                         state_next = STATE_WRITE_HEADER_LAST;
                            end
                        endcase
%000000             end else begin
%000000                 state_next = STATE_WRITE_HEADER;
                    end
                end
%000000         STATE_WRITE_HEADER_LAST: begin
                    // last header word requires first payload word; process accordingly
%000000             s_ip_payload_axis_tready_next = m_eth_payload_axis_tready_int_early && shift_ip_payload_s_tready;
        
%000000             if (s_ip_payload_axis_tready && s_ip_payload_axis_tvalid) begin
%000000                 m_eth_payload_axis_tvalid_int = 1'b1;
%000000                 transfer_in_save = 1'b1;
        
%000000                 m_eth_payload_axis_tdata_int[ 7: 0] = ip_dest_ip_reg[31:24];
%000000                 m_eth_payload_axis_tdata_int[15: 8] = ip_dest_ip_reg[23:16];
%000000                 m_eth_payload_axis_tdata_int[23:16] = ip_dest_ip_reg[15: 8];
%000000                 m_eth_payload_axis_tdata_int[31:24] = ip_dest_ip_reg[ 7: 0];
%000000                 m_eth_payload_axis_tdata_int[39:32] = shift_ip_payload_axis_tdata[39:32];
%000000                 m_eth_payload_axis_tdata_int[47:40] = shift_ip_payload_axis_tdata[47:40];
%000000                 m_eth_payload_axis_tdata_int[55:48] = shift_ip_payload_axis_tdata[55:48];
%000000                 m_eth_payload_axis_tdata_int[63:56] = shift_ip_payload_axis_tdata[63:56];
%000000                 m_eth_payload_axis_tkeep_int = {shift_ip_payload_axis_tkeep[7:4], 4'hF};
%000000                 m_eth_payload_axis_tlast_int = shift_ip_payload_axis_tlast;
%000000                 m_eth_payload_axis_tuser_int = shift_ip_payload_axis_tuser;
%000000                 word_count_next = word_count_reg - 16'd8;
        
%000000                 if (keep2count(m_eth_payload_axis_tkeep_int) >= word_count_reg) begin
                            // have entire payload
%000000                     m_eth_payload_axis_tkeep_int = count2keep(word_count_reg);
%000000                     if (shift_ip_payload_axis_tlast) begin
%000000                         s_ip_hdr_ready_next = !m_eth_hdr_valid_next;
%000000                         s_ip_payload_axis_tready_next = 1'b0;
%000000                         state_next = STATE_IDLE;
%000000                     end else begin
%000000                         store_last_word = 1'b1;
%000000                         s_ip_payload_axis_tready_next = shift_ip_payload_s_tready;
%000000                         m_eth_payload_axis_tvalid_int = 1'b0;
%000000                         state_next = STATE_WRITE_PAYLOAD_LAST;
                            end
%000000                 end else begin
%000000                     if (shift_ip_payload_axis_tlast) begin
                                // end of frame, but length does not match
%000000                         error_payload_early_termination_next = 1'b1;
%000000                         s_ip_payload_axis_tready_next = shift_ip_payload_s_tready;
%000000                         m_eth_payload_axis_tuser_int = 1'b1;
%000000                         state_next = STATE_WAIT_LAST;
%000000                     end else begin
%000000                         state_next = STATE_WRITE_PAYLOAD;
                            end
                        end
%000000             end else begin
%000000                 state_next = STATE_WRITE_HEADER_LAST;
                    end
                end
%000000         STATE_WRITE_PAYLOAD: begin
                    // write payload
%000000             s_ip_payload_axis_tready_next = m_eth_payload_axis_tready_int_early && shift_ip_payload_s_tready;
        
%000000             m_eth_payload_axis_tdata_int = shift_ip_payload_axis_tdata;
%000000             m_eth_payload_axis_tkeep_int = shift_ip_payload_axis_tkeep;
%000000             m_eth_payload_axis_tlast_int = shift_ip_payload_axis_tlast;
%000000             m_eth_payload_axis_tuser_int = shift_ip_payload_axis_tuser;
        
%000000             store_last_word = 1'b1;
        
%000000             if (m_eth_payload_axis_tready_int_reg && shift_ip_payload_axis_tvalid) begin
                        // word transfer through
%000000                 word_count_next = word_count_reg - 16'd8;
%000000                 transfer_in_save = 1'b1;
%000000                 m_eth_payload_axis_tvalid_int = 1'b1;
%000000                 if (word_count_reg <= 8) begin
                            // have entire payload
%000000                     m_eth_payload_axis_tkeep_int = count2keep(word_count_reg);
%000000                     if (shift_ip_payload_axis_tlast) begin
%000000                         if (keep2count(shift_ip_payload_axis_tkeep) < word_count_reg[4:0]) begin
                                    // end of frame, but length does not match
%000000                             error_payload_early_termination_next = 1'b1;
%000000                             m_eth_payload_axis_tuser_int = 1'b1;
                                end
%000000                         s_ip_payload_axis_tready_next = 1'b0;
%000000                         flush_save = 1'b1;
%000000                         s_ip_hdr_ready_next = !m_eth_hdr_valid_next;
%000000                         state_next = STATE_IDLE;
%000000                     end else begin
%000000                         m_eth_payload_axis_tvalid_int = 1'b0;
%000000                         state_next = STATE_WRITE_PAYLOAD_LAST;
                            end
%000000                 end else begin
%000000                     if (shift_ip_payload_axis_tlast) begin
                                // end of frame, but length does not match
%000000                         error_payload_early_termination_next = 1'b1;
%000000                         m_eth_payload_axis_tuser_int = 1'b1;
%000000                         s_ip_payload_axis_tready_next = 1'b0;
%000000                         flush_save = 1'b1;
%000000                         s_ip_hdr_ready_next = !m_eth_hdr_valid_next;
%000000                         state_next = STATE_IDLE;
%000000                     end else begin
%000000                         state_next = STATE_WRITE_PAYLOAD;
                            end
                        end
%000000             end else begin
%000000                 state_next = STATE_WRITE_PAYLOAD;
                    end
                end
%000000         STATE_WRITE_PAYLOAD_LAST: begin
                    // read and discard until end of frame
%000000             s_ip_payload_axis_tready_next = m_eth_payload_axis_tready_int_early && shift_ip_payload_s_tready;
        
%000000             m_eth_payload_axis_tdata_int = last_word_data_reg;
%000000             m_eth_payload_axis_tkeep_int = last_word_keep_reg;
%000000             m_eth_payload_axis_tlast_int = shift_ip_payload_axis_tlast;
%000000             m_eth_payload_axis_tuser_int = shift_ip_payload_axis_tuser;
        
%000000             if (m_eth_payload_axis_tready_int_reg && shift_ip_payload_axis_tvalid) begin
%000000                 transfer_in_save = 1'b1;
%000000                 if (shift_ip_payload_axis_tlast) begin
%000000                     s_ip_hdr_ready_next = !m_eth_hdr_valid_next;
%000000                     s_ip_payload_axis_tready_next = 1'b0;
%000000                     m_eth_payload_axis_tvalid_int = 1'b1;
%000000                     state_next = STATE_IDLE;
%000000                 end else begin
%000000                     state_next = STATE_WRITE_PAYLOAD_LAST;
                        end
%000000             end else begin
%000000                 state_next = STATE_WRITE_PAYLOAD_LAST;
                    end
                end
%000000         STATE_WAIT_LAST: begin
                    // read and discard until end of frame
%000000             s_ip_payload_axis_tready_next = shift_ip_payload_s_tready;
        
%000000             if (shift_ip_payload_axis_tvalid) begin
%000000                 transfer_in_save = 1'b1;
%000000                 if (shift_ip_payload_axis_tlast) begin
%000000                     s_ip_hdr_ready_next = !m_eth_hdr_valid_next;
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
 001479         m_eth_hdr_valid_reg <= 1'b0;
 001479         save_ip_payload_axis_tlast_reg <= 1'b0;
 001479         shift_ip_payload_extra_cycle_reg <= 1'b0;
 001479         busy_reg <= 1'b0;
 001479         error_payload_early_termination_reg <= 1'b0;
 857900     end else begin
 857900         state_reg <= state_next;
        
 857900         s_ip_hdr_ready_reg <= s_ip_hdr_ready_next;
 857900         s_ip_payload_axis_tready_reg <= s_ip_payload_axis_tready_next;
        
 857900         m_eth_hdr_valid_reg <= m_eth_hdr_valid_next;
        
 857900         busy_reg <= state_next != STATE_IDLE;
        
 857900         error_payload_early_termination_reg <= error_payload_early_termination_next;
        
 857900         if (flush_save) begin
 857900             save_ip_payload_axis_tlast_reg <= 1'b0;
 857900             shift_ip_payload_extra_cycle_reg <= 1'b0;
%000000         end else if (transfer_in_save) begin
%000000             save_ip_payload_axis_tlast_reg <= s_ip_payload_axis_tlast;
%000000             shift_ip_payload_extra_cycle_reg <= s_ip_payload_axis_tlast && (s_ip_payload_axis_tkeep[7:4] != 0);
                end
            end
        
 859379     hdr_ptr_reg <= hdr_ptr_next;
 859379     word_count_reg <= word_count_next;
        
 859379     hdr_sum_reg <= hdr_sum_next;
        
            // datapath
~859379     if (store_ip_hdr) begin
%000000         m_eth_dest_mac_reg <= s_eth_dest_mac;
%000000         m_eth_src_mac_reg <= s_eth_src_mac;
%000000         m_eth_type_reg <= s_eth_type;
%000000         ip_dscp_reg <= s_ip_dscp;
%000000         ip_ecn_reg <= s_ip_ecn;
%000000         ip_length_reg <= s_ip_length;
%000000         ip_identification_reg <= s_ip_identification;
%000000         ip_flags_reg <= s_ip_flags;
%000000         ip_fragment_offset_reg <= s_ip_fragment_offset;
%000000         ip_ttl_reg <= s_ip_ttl;
%000000         ip_protocol_reg <= s_ip_protocol;
%000000         ip_source_ip_reg <= s_ip_source_ip;
%000000         ip_dest_ip_reg <= s_ip_dest_ip;
            end
        
~859379     if (store_last_word) begin
%000000         last_word_data_reg <= m_eth_payload_axis_tdata_int;
%000000         last_word_keep_reg <= m_eth_payload_axis_tkeep_int;
            end
        
~859379     if (transfer_in_save) begin
%000000         save_ip_payload_axis_tdata_reg <= s_ip_payload_axis_tdata;
%000000         save_ip_payload_axis_tkeep_reg <= s_ip_payload_axis_tkeep;
%000000         save_ip_payload_axis_tuser_reg <= s_ip_payload_axis_tuser;
            end
        end
        
        // output datapath logic
 000001 reg [63:0] m_eth_payload_axis_tdata_reg = 64'd0;
 000001 reg [7:0]  m_eth_payload_axis_tkeep_reg = 8'd0;
 000001 reg        m_eth_payload_axis_tvalid_reg = 1'b0, m_eth_payload_axis_tvalid_next;
 000001 reg        m_eth_payload_axis_tlast_reg = 1'b0;
 000001 reg        m_eth_payload_axis_tuser_reg = 1'b0;
        
 000001 reg [63:0] temp_m_eth_payload_axis_tdata_reg = 64'd0;
 000001 reg [7:0]  temp_m_eth_payload_axis_tkeep_reg = 8'd0;
 000001 reg        temp_m_eth_payload_axis_tvalid_reg = 1'b0, temp_m_eth_payload_axis_tvalid_next;
 000001 reg        temp_m_eth_payload_axis_tlast_reg = 1'b0;
 000001 reg        temp_m_eth_payload_axis_tuser_reg = 1'b0;
        
        // datapath control
        reg store_eth_payload_int_to_output;
        reg store_eth_payload_int_to_temp;
        reg store_eth_payload_axis_temp_to_output;
        
        assign m_eth_payload_axis_tdata = m_eth_payload_axis_tdata_reg;
        assign m_eth_payload_axis_tkeep = m_eth_payload_axis_tkeep_reg;
        assign m_eth_payload_axis_tvalid = m_eth_payload_axis_tvalid_reg;
        assign m_eth_payload_axis_tlast = m_eth_payload_axis_tlast_reg;
        assign m_eth_payload_axis_tuser = m_eth_payload_axis_tuser_reg;
        
        // enable ready input next cycle if output is ready or if both output registers are empty
        assign m_eth_payload_axis_tready_int_early = m_eth_payload_axis_tready || (!temp_m_eth_payload_axis_tvalid_reg && !m_eth_payload_axis_tvalid_reg);
        
 7806614 always @* begin
            // transfer sink ready state to source
 7806614     m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_reg;
 7806614     temp_m_eth_payload_axis_tvalid_next = temp_m_eth_payload_axis_tvalid_reg;
        
 7806614     store_eth_payload_int_to_output = 1'b0;
 7806614     store_eth_payload_int_to_temp = 1'b0;
 7806614     store_eth_payload_axis_temp_to_output = 1'b0;
            
 7793229     if (m_eth_payload_axis_tready_int_reg) begin
                // input is ready
~7793229         if (m_eth_payload_axis_tready | !m_eth_payload_axis_tvalid_reg) begin
                    // output is ready or currently not valid, transfer data to output
 7793229             m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_int;
 7793229             store_eth_payload_int_to_output = 1'b1;
%000000         end else begin
                    // output is not ready, store input in temp
%000000             temp_m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_int;
%000000             store_eth_payload_int_to_temp = 1'b1;
                end
~013385     end else if (m_eth_payload_axis_tready) begin
                // input is not ready, but output is ready
%000000         m_eth_payload_axis_tvalid_next = temp_m_eth_payload_axis_tvalid_reg;
%000000         temp_m_eth_payload_axis_tvalid_next = 1'b0;
%000000         store_eth_payload_axis_temp_to_output = 1'b1;
            end
        end
        
 859379 always @(posedge clk) begin
 859379     m_eth_payload_axis_tvalid_reg <= m_eth_payload_axis_tvalid_next;
 859379     m_eth_payload_axis_tready_int_reg <= m_eth_payload_axis_tready_int_early;
 859379     temp_m_eth_payload_axis_tvalid_reg <= temp_m_eth_payload_axis_tvalid_next;
        
            // datapath
 857899     if (store_eth_payload_int_to_output) begin
 857899         m_eth_payload_axis_tdata_reg <= m_eth_payload_axis_tdata_int;
 857899         m_eth_payload_axis_tkeep_reg <= m_eth_payload_axis_tkeep_int;
 857899         m_eth_payload_axis_tlast_reg <= m_eth_payload_axis_tlast_int;
 857899         m_eth_payload_axis_tuser_reg <= m_eth_payload_axis_tuser_int;
~001480     end else if (store_eth_payload_axis_temp_to_output) begin
%000000         m_eth_payload_axis_tdata_reg <= temp_m_eth_payload_axis_tdata_reg;
%000000         m_eth_payload_axis_tkeep_reg <= temp_m_eth_payload_axis_tkeep_reg;
%000000         m_eth_payload_axis_tlast_reg <= temp_m_eth_payload_axis_tlast_reg;
%000000         m_eth_payload_axis_tuser_reg <= temp_m_eth_payload_axis_tuser_reg;
            end
        
~859379     if (store_eth_payload_int_to_temp) begin
%000000         temp_m_eth_payload_axis_tdata_reg <= m_eth_payload_axis_tdata_int;
%000000         temp_m_eth_payload_axis_tkeep_reg <= m_eth_payload_axis_tkeep_int;
%000000         temp_m_eth_payload_axis_tlast_reg <= m_eth_payload_axis_tlast_int;
%000000         temp_m_eth_payload_axis_tuser_reg <= m_eth_payload_axis_tuser_int;
            end
        
 857900     if (rst) begin
 001479         m_eth_payload_axis_tvalid_reg <= 1'b0;
 001479         m_eth_payload_axis_tready_int_reg <= 1'b0;
 001479         temp_m_eth_payload_axis_tvalid_reg <= 1'b0;
            end
        end
        
        endmodule
        
        `resetall
        
