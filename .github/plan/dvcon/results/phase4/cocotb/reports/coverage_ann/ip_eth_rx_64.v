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
         * IP ethernet frame receiver (Ethernet frame in, IP frame out, 64 bit datapath)
         */
        module ip_eth_rx_64
        (
            input  wire        clk,
            input  wire        rst,
        
            /*
             * Ethernet frame input
             */
            input  wire        s_eth_hdr_valid,
            output wire        s_eth_hdr_ready,
            input  wire [47:0] s_eth_dest_mac,
            input  wire [47:0] s_eth_src_mac,
            input  wire [15:0] s_eth_type,
            input  wire [63:0] s_eth_payload_axis_tdata,
            input  wire [7:0]  s_eth_payload_axis_tkeep,
            input  wire        s_eth_payload_axis_tvalid,
            output wire        s_eth_payload_axis_tready,
            input  wire        s_eth_payload_axis_tlast,
            input  wire        s_eth_payload_axis_tuser,
        
            /*
             * IP frame output
             */
            output wire        m_ip_hdr_valid,
            input  wire        m_ip_hdr_ready,
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
            output wire [63:0] m_ip_payload_axis_tdata,
            output wire [7:0]  m_ip_payload_axis_tkeep,
            output wire        m_ip_payload_axis_tvalid,
            input  wire        m_ip_payload_axis_tready,
            output wire        m_ip_payload_axis_tlast,
            output wire        m_ip_payload_axis_tuser,
        
            /*
             * Status signals
             */
            output wire        busy,
            output wire        error_header_early_termination,
            output wire        error_payload_early_termination,
            output wire        error_invalid_header,
            output wire        error_invalid_checksum
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
        
        This module receives an Ethernet frame with header fields in parallel and
        payload on an AXI stream interface, decodes and strips the IP header fields,
        then produces the header fields in parallel along with the IP payload in a
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
        reg store_eth_hdr;
        reg store_hdr_word_0;
        reg store_hdr_word_1;
        reg store_hdr_word_2;
        reg store_last_word;
        
        reg flush_save;
        reg transfer_in_save;
        
 000001 reg [5:0] hdr_ptr_reg = 6'd0, hdr_ptr_next;
 000001 reg [15:0] word_count_reg = 16'd0, word_count_next;
        
 000001 reg [16:0] hdr_sum_high_reg = 17'd0;
 000001 reg [16:0] hdr_sum_low_reg = 17'd0;
        reg [19:0] hdr_sum_temp;
 000001 reg [19:0] hdr_sum_reg = 20'd0, hdr_sum_next;
 000001 reg check_hdr_reg = 1'b0, check_hdr_next;
        
 000001 reg [63:0] last_word_data_reg = 64'd0;
 000001 reg [7:0] last_word_keep_reg = 8'd0;
        
 000001 reg s_eth_hdr_ready_reg = 1'b0, s_eth_hdr_ready_next;
 000001 reg s_eth_payload_axis_tready_reg = 1'b0, s_eth_payload_axis_tready_next;
        
 000001 reg m_ip_hdr_valid_reg = 1'b0, m_ip_hdr_valid_next;
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
        
 000001 reg busy_reg = 1'b0;
 000001 reg error_header_early_termination_reg = 1'b0, error_header_early_termination_next;
 000001 reg error_payload_early_termination_reg = 1'b0, error_payload_early_termination_next;
 000001 reg error_invalid_header_reg = 1'b0, error_invalid_header_next;
 000001 reg error_invalid_checksum_reg = 1'b0, error_invalid_checksum_next;
        
 000001 reg [63:0] save_eth_payload_axis_tdata_reg = 64'd0;
 000001 reg [7:0] save_eth_payload_axis_tkeep_reg = 8'd0;
 000001 reg save_eth_payload_axis_tlast_reg = 1'b0;
 000001 reg save_eth_payload_axis_tuser_reg = 1'b0;
        
        reg [63:0] shift_eth_payload_axis_tdata;
        reg [7:0] shift_eth_payload_axis_tkeep;
        reg shift_eth_payload_axis_tvalid;
        reg shift_eth_payload_axis_tlast;
        reg shift_eth_payload_axis_tuser;
        reg shift_eth_payload_s_tready;
 000001 reg shift_eth_payload_extra_cycle_reg = 1'b0;
        
        // internal datapath
        reg [63:0] m_ip_payload_axis_tdata_int;
        reg [7:0]  m_ip_payload_axis_tkeep_int;
        reg        m_ip_payload_axis_tvalid_int;
 000001 reg        m_ip_payload_axis_tready_int_reg = 1'b0;
        reg        m_ip_payload_axis_tlast_int;
        reg        m_ip_payload_axis_tuser_int;
        wire       m_ip_payload_axis_tready_int_early;
        
        assign s_eth_hdr_ready = s_eth_hdr_ready_reg;
        assign s_eth_payload_axis_tready = s_eth_payload_axis_tready_reg;
        
        assign m_ip_hdr_valid = m_ip_hdr_valid_reg;
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
        
        assign busy = busy_reg;
        assign error_header_early_termination = error_header_early_termination_reg;
        assign error_payload_early_termination = error_payload_early_termination_reg;
        assign error_invalid_header = error_invalid_header_reg;
        assign error_invalid_checksum = error_invalid_checksum_reg;
        
 000011 function [3:0] keep2count;
            input [7:0] k;
 000011     casez (k)
%000000         8'bzzzzzzz0: keep2count = 4'd0;
%000000         8'bzzzzzz01: keep2count = 4'd1;
%000000         8'bzzzzz011: keep2count = 4'd2;
%000000         8'bzzzz0111: keep2count = 4'd3;
%000000         8'bzzz01111: keep2count = 4'd4;
%000000         8'bzz011111: keep2count = 4'd5;
 000011         8'bz0111111: keep2count = 4'd6;
%000000         8'b01111111: keep2count = 4'd7;
%000000         8'b11111111: keep2count = 4'd8;
            endcase
        endfunction
        
 000054 function [7:0] count2keep;
            input [3:0] k;
 000054     case (k)
%000000         4'd0: count2keep = 8'b00000000;
%000000         4'd1: count2keep = 8'b00000001;
 000011         4'd2: count2keep = 8'b00000011;
%000000         4'd3: count2keep = 8'b00000111;
 000022         4'd4: count2keep = 8'b00001111;
%000000         4'd5: count2keep = 8'b00011111;
%000000         4'd6: count2keep = 8'b00111111;
%000000         4'd7: count2keep = 8'b01111111;
 000021         4'd8: count2keep = 8'b11111111;
            endcase
        endfunction
        
 7809398 always @* begin
 7809398     shift_eth_payload_axis_tdata[31:0] = save_eth_payload_axis_tdata_reg[63:32];
 7809398     shift_eth_payload_axis_tkeep[3:0] = save_eth_payload_axis_tkeep_reg[7:4];
        
 7806461     if (shift_eth_payload_extra_cycle_reg) begin
 002937         shift_eth_payload_axis_tdata[63:32] = 32'd0;
 002937         shift_eth_payload_axis_tkeep[7:4] = 4'd0;
 002937         shift_eth_payload_axis_tvalid = 1'b1;
 002937         shift_eth_payload_axis_tlast = save_eth_payload_axis_tlast_reg;
 002937         shift_eth_payload_axis_tuser = save_eth_payload_axis_tuser_reg;
 002937         shift_eth_payload_s_tready = flush_save;
 7806461     end else begin
 7806461         shift_eth_payload_axis_tdata[63:32] = s_eth_payload_axis_tdata[31:0];
 7806461         shift_eth_payload_axis_tkeep[7:4] = s_eth_payload_axis_tkeep[3:0];
 7806461         shift_eth_payload_axis_tvalid = s_eth_payload_axis_tvalid;
 7806461         shift_eth_payload_axis_tlast = (s_eth_payload_axis_tlast && (s_eth_payload_axis_tkeep[7:4] == 0));
 7806461         shift_eth_payload_axis_tuser = (s_eth_payload_axis_tuser && (s_eth_payload_axis_tkeep[7:4] == 0));
 7806461         shift_eth_payload_s_tready = !(s_eth_payload_axis_tlast && s_eth_payload_axis_tvalid && transfer_in_save);
            end
        end
        
 7809398 always @* begin
 7809398     state_next = STATE_IDLE;
        
 7809398     flush_save = 1'b0;
 7809398     transfer_in_save = 1'b0;
        
 7809398     s_eth_hdr_ready_next = 1'b0;
 7809398     s_eth_payload_axis_tready_next = 1'b0;
        
 7809398     store_eth_hdr = 1'b0;
 7809398     store_hdr_word_0 = 1'b0;
 7809398     store_hdr_word_1 = 1'b0;
 7809398     store_hdr_word_2 = 1'b0;
        
 7809398     store_last_word = 1'b0;
        
 7809398     hdr_ptr_next = hdr_ptr_reg;
 7809398     word_count_next = word_count_reg;
        
 7809398     hdr_sum_temp = 32'd0;
 7809398     hdr_sum_next = hdr_sum_reg;
 7809398     check_hdr_next = check_hdr_reg;
        
 7809398     m_ip_hdr_valid_next = m_ip_hdr_valid_reg && !m_ip_hdr_ready;
        
 7809398     error_header_early_termination_next = 1'b0;
 7809398     error_payload_early_termination_next = 1'b0;
 7809398     error_invalid_header_next = 1'b0;
 7809398     error_invalid_checksum_next = 1'b0;
        
 7809398     m_ip_payload_axis_tdata_int = 64'd0;
 7809398     m_ip_payload_axis_tkeep_int = 8'd0;
 7809398     m_ip_payload_axis_tvalid_int = 1'b0;
 7809398     m_ip_payload_axis_tlast_int = 1'b0;
 7809398     m_ip_payload_axis_tuser_int = 1'b0;
        
 7809398     case (state_reg)
 7773628         STATE_IDLE: begin
                    // idle state - wait for header
 7773628             hdr_ptr_next = 6'd0;
 7773628             hdr_sum_next = 32'd0;
 7773628             flush_save = 1'b1;
 7773628             s_eth_hdr_ready_next = !m_ip_hdr_valid_next;
        
 7770828             if (s_eth_hdr_ready && s_eth_hdr_valid) begin
 002800                 s_eth_hdr_ready_next = 1'b0;
 002800                 s_eth_payload_axis_tready_next = 1'b1;
 002800                 store_eth_hdr = 1'b1;
 002800                 state_next = STATE_READ_HEADER;
 7770828             end else begin
 7770828                 state_next = STATE_IDLE;
                    end
                end
 008960         STATE_READ_HEADER: begin
                    // read header
 008960             s_eth_payload_axis_tready_next = shift_eth_payload_s_tready;
 008960             word_count_next = m_ip_length_reg - 5*4;
        
~008960             if (s_eth_payload_axis_tvalid) begin
                        // word transfer in - store it
 008960                 hdr_ptr_next = hdr_ptr_reg + 6'd8;
 008960                 transfer_in_save = 1'b1;
 008960                 state_next = STATE_READ_HEADER;
        
 008960                 case (hdr_ptr_reg)
 003360                     6'h00: begin
 003360                         store_hdr_word_0 = 1'b1;
                            end
 002800                     6'h08: begin
 002800                         store_hdr_word_1 = 1'b1;
 002800                         hdr_sum_next = hdr_sum_high_reg + hdr_sum_low_reg;
                            end
 002800                     6'h10: begin
 002800                         store_hdr_word_2 = 1'b1;
 002800                         hdr_sum_next = hdr_sum_reg + hdr_sum_high_reg + hdr_sum_low_reg;
        
                                // check header checksum on next cycle for improved timing
 002800                         check_hdr_next = 1'b1;
        
 002770                         if (m_ip_version_reg != 4'd4 || m_ip_ihl_reg != 4'd5) begin
 000030                             error_invalid_header_next = 1'b1;
 000030                             s_eth_payload_axis_tready_next = shift_eth_payload_s_tready;
 000030                             state_next = STATE_WAIT_LAST;
 002770                         end else begin
 002770                             s_eth_payload_axis_tready_next = m_ip_payload_axis_tready_int_early && shift_eth_payload_s_tready;
 002770                             state_next = STATE_READ_PAYLOAD;
                                end
                            end
                        endcase
        
~008960                 if (shift_eth_payload_axis_tlast) begin
%000000                     error_header_early_termination_next = 1'b1;
%000000                     error_invalid_header_next = 1'b0;
%000000                     error_invalid_checksum_next = 1'b0;
%000000                     m_ip_hdr_valid_next = 1'b0;
%000000                     s_eth_hdr_ready_next = !m_ip_hdr_valid_next;
%000000                     s_eth_payload_axis_tready_next = 1'b0;
%000000                     state_next = STATE_IDLE;
                        end
        
%000000             end else begin
%000000                 state_next = STATE_READ_HEADER;
                    end
                end
 026489         STATE_READ_PAYLOAD: begin
                    // read payload
 026489             s_eth_payload_axis_tready_next = m_ip_payload_axis_tready_int_early && shift_eth_payload_s_tready;
        
 026489             m_ip_payload_axis_tdata_int = shift_eth_payload_axis_tdata;
 026489             m_ip_payload_axis_tkeep_int = shift_eth_payload_axis_tkeep;
 026489             m_ip_payload_axis_tlast_int = shift_eth_payload_axis_tlast;
 026489             m_ip_payload_axis_tuser_int = shift_eth_payload_axis_tuser;
        
 026489             store_last_word = 1'b1;
        
 023189             if (m_ip_payload_axis_tready_int_reg && shift_eth_payload_axis_tvalid) begin
                        // word transfer through
 023189                 word_count_next = word_count_reg - 16'd8;
 023189                 transfer_in_save = 1'b1;
 023189                 m_ip_payload_axis_tvalid_int = 1'b1;
 023135                 if (word_count_reg <= 8) begin
                            // have entire payload
 000054                     m_ip_payload_axis_tkeep_int = shift_eth_payload_axis_tkeep & count2keep(word_count_reg);
 000043                     if (shift_eth_payload_axis_tlast) begin
~000011                         if (keep2count(shift_eth_payload_axis_tkeep) < word_count_reg[4:0]) begin
                                    // end of frame, but length does not match
%000000                             error_payload_early_termination_next = 1'b1;
%000000                             m_ip_payload_axis_tuser_int = 1'b1;
                                end
 000011                         s_eth_payload_axis_tready_next = 1'b0;
 000011                         flush_save = 1'b1;
 000011                         s_eth_hdr_ready_next = !m_ip_hdr_valid_reg && !check_hdr_reg;
 000011                         state_next = STATE_IDLE;
 000043                     end else begin
 000043                         m_ip_payload_axis_tvalid_int = 1'b0;
 000043                         state_next = STATE_READ_PAYLOAD_LAST;
                            end
 023135                 end else begin
 020153                     if (shift_eth_payload_axis_tlast) begin
                                // end of frame, but length does not match
 002982                         error_payload_early_termination_next = 1'b1;
 002982                         m_ip_payload_axis_tuser_int = 1'b1;
 002982                         s_eth_payload_axis_tready_next = 1'b0;
 002982                         flush_save = 1'b1;
 002982                         s_eth_hdr_ready_next = !m_ip_hdr_valid_reg && !check_hdr_reg;
 002982                         state_next = STATE_IDLE;
 020153                     end else begin
 020153                         state_next = STATE_READ_PAYLOAD;
                            end
                        end
 003300             end else begin
 003300                 state_next = STATE_READ_PAYLOAD;
                    end
        
 023719             if (check_hdr_reg) begin
 002770                 check_hdr_next = 1'b0;
        
 002770                 hdr_sum_temp = hdr_sum_reg[15:0] + hdr_sum_reg[19:16] + hdr_sum_low_reg;
        
 002760                 if (hdr_sum_temp != 19'h0ffff && hdr_sum_temp != 19'h1fffe) begin
                            // bad checksum
 000010                     error_invalid_checksum_next = 1'b1;
 000010                     m_ip_payload_axis_tvalid_int = 1'b0;
~000010                     if (shift_eth_payload_axis_tlast && shift_eth_payload_axis_tvalid) begin
                                // only one payload cycle; return to idle now
%000000                         s_eth_hdr_ready_next = !m_ip_hdr_valid_reg && !check_hdr_reg;
%000000                         state_next = STATE_IDLE;
 000010                     end else begin
                                // drop payload
 000010                         s_eth_payload_axis_tready_next = shift_eth_payload_s_tready;
 000010                         state_next = STATE_WAIT_LAST;
                            end
 002760                 end else begin
                            // good checksum; transfer header
 002760                     m_ip_hdr_valid_next = 1'b1;
                        end
                    end
                end
 000067         STATE_READ_PAYLOAD_LAST: begin
                    // read and discard until end of frame
 000067             s_eth_payload_axis_tready_next = m_ip_payload_axis_tready_int_early && shift_eth_payload_s_tready;
        
 000067             m_ip_payload_axis_tdata_int = last_word_data_reg;
 000067             m_ip_payload_axis_tkeep_int = last_word_keep_reg;
 000067             m_ip_payload_axis_tlast_int = shift_eth_payload_axis_tlast;
 000067             m_ip_payload_axis_tuser_int = shift_eth_payload_axis_tuser;
        
 000055             if (m_ip_payload_axis_tready_int_reg && shift_eth_payload_axis_tvalid) begin
 000055                 transfer_in_save = 1'b1;
 000044                 if (shift_eth_payload_axis_tlast) begin
 000044                     s_eth_payload_axis_tready_next = 1'b0;
 000044                     flush_save = 1'b1;
 000044                     s_eth_hdr_ready_next = !m_ip_hdr_valid_next;
 000044                     m_ip_payload_axis_tvalid_int = 1'b1;
 000044                     state_next = STATE_IDLE;
 000011                 end else begin
 000011                     state_next = STATE_READ_PAYLOAD_LAST;
                        end
 000012             end else begin
 000012                 state_next = STATE_READ_PAYLOAD_LAST;
                    end
                end
 000254         STATE_WAIT_LAST: begin
                    // read and discard until end of frame
 000254             s_eth_payload_axis_tready_next = shift_eth_payload_s_tready;
        
~000254             if (shift_eth_payload_axis_tvalid) begin
 000254                 transfer_in_save = 1'b1;
 000210                 if (shift_eth_payload_axis_tlast) begin
 000044                     s_eth_payload_axis_tready_next = 1'b0;
 000044                     flush_save = 1'b1;
 000044                     s_eth_hdr_ready_next = !m_ip_hdr_valid_next;
 000044                     state_next = STATE_IDLE;
 000210                 end else begin
 000210                     state_next = STATE_WAIT_LAST;
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
 001479         s_eth_hdr_ready_reg <= 1'b0;
 001479         s_eth_payload_axis_tready_reg <= 1'b0;
 001479         m_ip_hdr_valid_reg <= 1'b0;
 001479         save_eth_payload_axis_tlast_reg <= 1'b0;
 001479         shift_eth_payload_extra_cycle_reg <= 1'b0;
 001479         busy_reg <= 1'b0;
 001479         error_header_early_termination_reg <= 1'b0;
 001479         error_payload_early_termination_reg <= 1'b0;
 001479         error_invalid_header_reg <= 1'b0;
 001479         error_invalid_checksum_reg <= 1'b0;
 857900     end else begin
 857900         state_reg <= state_next;
        
 857900         s_eth_hdr_ready_reg <= s_eth_hdr_ready_next;
 857900         s_eth_payload_axis_tready_reg <= s_eth_payload_axis_tready_next;
        
 857900         m_ip_hdr_valid_reg <= m_ip_hdr_valid_next;
        
 857900         error_header_early_termination_reg <= error_header_early_termination_next;
 857900         error_payload_early_termination_reg <= error_payload_early_termination_next;
 857900         error_invalid_header_reg <= error_invalid_header_next;
 857900         error_invalid_checksum_reg <= error_invalid_checksum_next;
        
 857900         busy_reg <= state_next != STATE_IDLE;
        
                // datapath
 854797         if (flush_save) begin
 854797             save_eth_payload_axis_tlast_reg <= 1'b0;
 854797             shift_eth_payload_extra_cycle_reg <= 1'b0;
 002827         end else if (transfer_in_save) begin
 002827             save_eth_payload_axis_tlast_reg <= s_eth_payload_axis_tlast;
 002827             shift_eth_payload_extra_cycle_reg <= s_eth_payload_axis_tlast && (s_eth_payload_axis_tkeep[7:4] != 0);
                end
            end
        
 859379     hdr_ptr_reg <= hdr_ptr_next;
 859379     word_count_reg <= word_count_next;
        
 859379     hdr_sum_reg <= hdr_sum_next;
 859379     check_hdr_reg <= check_hdr_next;
        
 856263     if (s_eth_payload_axis_tvalid) begin
 003116         hdr_sum_low_reg <= s_eth_payload_axis_tdata[15:0] + s_eth_payload_axis_tdata[31:16];
 003116         hdr_sum_high_reg <= s_eth_payload_axis_tdata[47:32] + s_eth_payload_axis_tdata[63:48];
            end
        
            // datapath
 859099     if (store_eth_hdr) begin
 000280         m_eth_dest_mac_reg <= s_eth_dest_mac;
 000280         m_eth_src_mac_reg <= s_eth_src_mac;
 000280         m_eth_type_reg <= s_eth_type;
            end
        
 856867     if (store_last_word) begin
 002512         last_word_data_reg <= m_ip_payload_axis_tdata_int;
 002512         last_word_keep_reg <= m_ip_payload_axis_tkeep_int;
            end
        
 859099     if (store_hdr_word_0) begin
 000280         {m_ip_version_reg, m_ip_ihl_reg} <= s_eth_payload_axis_tdata[ 7: 0];
 000280         {m_ip_dscp_reg, m_ip_ecn_reg} <= s_eth_payload_axis_tdata[15: 8];
 000280         m_ip_length_reg[15: 8] <= s_eth_payload_axis_tdata[23:16];
 000280         m_ip_length_reg[ 7: 0] <= s_eth_payload_axis_tdata[31:24];
 000280         m_ip_identification_reg[15: 8] <= s_eth_payload_axis_tdata[39:32];
 000280         m_ip_identification_reg[ 7: 0] <= s_eth_payload_axis_tdata[47:40];
 000280         {m_ip_flags_reg, m_ip_fragment_offset_reg[12:8]} <= s_eth_payload_axis_tdata[55:48];
 000280         m_ip_fragment_offset_reg[ 7:0] <= s_eth_payload_axis_tdata[63:56];
            end
        
 859099     if (store_hdr_word_1) begin
 000280         m_ip_ttl_reg <= s_eth_payload_axis_tdata[ 7: 0];
 000280         m_ip_protocol_reg <= s_eth_payload_axis_tdata[15: 8];
 000280         m_ip_header_checksum_reg[15: 8] <= s_eth_payload_axis_tdata[23:16];
 000280         m_ip_header_checksum_reg[ 7: 0] <= s_eth_payload_axis_tdata[31:24];
 000280         m_ip_source_ip_reg[31:24] <= s_eth_payload_axis_tdata[39:32];
 000280         m_ip_source_ip_reg[23:16] <= s_eth_payload_axis_tdata[47:40];
 000280         m_ip_source_ip_reg[15: 8] <= s_eth_payload_axis_tdata[55:48];
 000280         m_ip_source_ip_reg[ 7: 0] <= s_eth_payload_axis_tdata[63:56];
            end
        
 859099     if (store_hdr_word_2) begin
 000280         m_ip_dest_ip_reg[31:24] <= s_eth_payload_axis_tdata[ 7: 0];
 000280         m_ip_dest_ip_reg[23:16] <= s_eth_payload_axis_tdata[15: 8];
 000280         m_ip_dest_ip_reg[15: 8] <= s_eth_payload_axis_tdata[23:16];
 000280         m_ip_dest_ip_reg[ 7: 0] <= s_eth_payload_axis_tdata[31:24];
            end
        
 856272     if (transfer_in_save) begin
 003107         save_eth_payload_axis_tdata_reg <= s_eth_payload_axis_tdata;
 003107         save_eth_payload_axis_tkeep_reg <= s_eth_payload_axis_tkeep;
 003107         save_eth_payload_axis_tuser_reg <= s_eth_payload_axis_tuser;
            end
        end
        
        // output datapath logic
 000001 reg [63:0] m_ip_payload_axis_tdata_reg = 64'd0;
 000001 reg [7:0]  m_ip_payload_axis_tkeep_reg = 8'd0;
 000001 reg        m_ip_payload_axis_tvalid_reg = 1'b0, m_ip_payload_axis_tvalid_next;
 000001 reg        m_ip_payload_axis_tlast_reg = 1'b0;
 000001 reg        m_ip_payload_axis_tuser_reg = 1'b0;
        
 000001 reg [63:0] temp_m_ip_payload_axis_tdata_reg = 64'd0;
 000001 reg [7:0]  temp_m_ip_payload_axis_tkeep_reg = 8'd0;
 000001 reg        temp_m_ip_payload_axis_tvalid_reg = 1'b0, temp_m_ip_payload_axis_tvalid_next;
 000001 reg        temp_m_ip_payload_axis_tlast_reg = 1'b0;
 000001 reg        temp_m_ip_payload_axis_tuser_reg = 1'b0;
        
        // datapath control
        reg store_ip_payload_int_to_output;
        reg store_ip_payload_int_to_temp;
        reg store_ip_payload_axis_temp_to_output;
        
        assign m_ip_payload_axis_tdata = m_ip_payload_axis_tdata_reg;
        assign m_ip_payload_axis_tkeep = m_ip_payload_axis_tkeep_reg;
        assign m_ip_payload_axis_tvalid = m_ip_payload_axis_tvalid_reg;
        assign m_ip_payload_axis_tlast = m_ip_payload_axis_tlast_reg;
        assign m_ip_payload_axis_tuser = m_ip_payload_axis_tuser_reg;
        
        // enable ready input next cycle if output is ready or if both output registers are empty
        assign m_ip_payload_axis_tready_int_early = m_ip_payload_axis_tready || (!temp_m_ip_payload_axis_tvalid_reg && !m_ip_payload_axis_tvalid_reg);
        
 7809398 always @* begin
            // transfer sink ready state to source
 7809398     m_ip_payload_axis_tvalid_next = m_ip_payload_axis_tvalid_reg;
 7809398     temp_m_ip_payload_axis_tvalid_next = temp_m_ip_payload_axis_tvalid_reg;
        
 7809398     store_ip_payload_int_to_output = 1'b0;
 7809398     store_ip_payload_int_to_temp = 1'b0;
 7809398     store_ip_payload_axis_temp_to_output = 1'b0;
            
 7792665     if (m_ip_payload_axis_tready_int_reg) begin
                // input is ready
 7789861         if (m_ip_payload_axis_tready || !m_ip_payload_axis_tvalid_reg) begin
                    // output is ready or currently not valid, transfer data to output
 7789861             m_ip_payload_axis_tvalid_next = m_ip_payload_axis_tvalid_int;
 7789861             store_ip_payload_int_to_output = 1'b1;
 002804         end else begin
                    // output is not ready, store input in temp
 002804             temp_m_ip_payload_axis_tvalid_next = m_ip_payload_axis_tvalid_int;
 002804             store_ip_payload_int_to_temp = 1'b1;
                end
 013385     end else if (m_ip_payload_axis_tready) begin
                // input is not ready, but output is ready
 003348         m_ip_payload_axis_tvalid_next = temp_m_ip_payload_axis_tvalid_reg;
 003348         temp_m_ip_payload_axis_tvalid_next = 1'b0;
 003348         store_ip_payload_axis_temp_to_output = 1'b1;
            end
        end
        
 859379 always @(posedge clk) begin
 859379     m_ip_payload_axis_tvalid_reg <= m_ip_payload_axis_tvalid_next;
 859379     m_ip_payload_axis_tready_int_reg <= m_ip_payload_axis_tready_int_early;
 859379     temp_m_ip_payload_axis_tvalid_reg <= temp_m_ip_payload_axis_tvalid_next;
        
            // datapath
 857339     if (store_ip_payload_int_to_output) begin
 857339         m_ip_payload_axis_tdata_reg <= m_ip_payload_axis_tdata_int;
 857339         m_ip_payload_axis_tkeep_reg <= m_ip_payload_axis_tkeep_int;
 857339         m_ip_payload_axis_tlast_reg <= m_ip_payload_axis_tlast_int;
 857339         m_ip_payload_axis_tuser_reg <= m_ip_payload_axis_tuser_int;
 001760     end else if (store_ip_payload_axis_temp_to_output) begin
 000280         m_ip_payload_axis_tdata_reg <= temp_m_ip_payload_axis_tdata_reg;
 000280         m_ip_payload_axis_tkeep_reg <= temp_m_ip_payload_axis_tkeep_reg;
 000280         m_ip_payload_axis_tlast_reg <= temp_m_ip_payload_axis_tlast_reg;
 000280         m_ip_payload_axis_tuser_reg <= temp_m_ip_payload_axis_tuser_reg;
            end
        
 859099     if (store_ip_payload_int_to_temp) begin
 000280         temp_m_ip_payload_axis_tdata_reg <= m_ip_payload_axis_tdata_int;
 000280         temp_m_ip_payload_axis_tkeep_reg <= m_ip_payload_axis_tkeep_int;
 000280         temp_m_ip_payload_axis_tlast_reg <= m_ip_payload_axis_tlast_int;
 000280         temp_m_ip_payload_axis_tuser_reg <= m_ip_payload_axis_tuser_int;
            end
        
 857900     if (rst) begin
 001479         m_ip_payload_axis_tvalid_reg <= 1'b0;
 001479         m_ip_payload_axis_tready_int_reg <= 1'b0;
 001479         temp_m_ip_payload_axis_tvalid_reg <= 1'b0;
            end
        end
        
        endmodule
        
        `resetall
        
