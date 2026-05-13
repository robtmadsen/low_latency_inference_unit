//      // verilator_coverage annotation
        /*
        
        Copyright (c) 2014-2020 Alex Forencich
        
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
         * ARP ethernet frame transmitter (ARP frame in, Ethernet frame out)
         */
        module arp_eth_tx #
        (
            // Width of AXI stream interfaces in bits
            parameter DATA_WIDTH = 8,
            // Propagate tkeep signal
            // If disabled, tkeep assumed to be 1'b1
            parameter KEEP_ENABLE = (DATA_WIDTH>8),
            // tkeep signal width (words per cycle)
            parameter KEEP_WIDTH = (DATA_WIDTH/8)
        )
        (
            input  wire                   clk,
            input  wire                   rst,
        
            /*
             * ARP frame input
             */
            input  wire                   s_frame_valid,
            output wire                   s_frame_ready,
            input  wire [47:0]            s_eth_dest_mac,
            input  wire [47:0]            s_eth_src_mac,
            input  wire [15:0]            s_eth_type,
            input  wire [15:0]            s_arp_htype,
            input  wire [15:0]            s_arp_ptype,
            input  wire [15:0]            s_arp_oper,
            input  wire [47:0]            s_arp_sha,
            input  wire [31:0]            s_arp_spa,
            input  wire [47:0]            s_arp_tha,
            input  wire [31:0]            s_arp_tpa,
        
            /*
             * Ethernet frame output
             */
            output wire                   m_eth_hdr_valid,
            input  wire                   m_eth_hdr_ready,
            output wire [47:0]            m_eth_dest_mac,
            output wire [47:0]            m_eth_src_mac,
            output wire [15:0]            m_eth_type,
            output wire [DATA_WIDTH-1:0]  m_eth_payload_axis_tdata,
            output wire [KEEP_WIDTH-1:0]  m_eth_payload_axis_tkeep,
            output wire                   m_eth_payload_axis_tvalid,
            input  wire                   m_eth_payload_axis_tready,
            output wire                   m_eth_payload_axis_tlast,
            output wire                   m_eth_payload_axis_tuser,
        
            /*
             * Status signals
             */
            output wire                   busy
        );
        
        parameter BYTE_LANES = KEEP_ENABLE ? KEEP_WIDTH : 1;
        
        parameter HDR_SIZE = 28;
        
        parameter CYCLE_COUNT = (HDR_SIZE+BYTE_LANES-1)/BYTE_LANES;
        
        parameter PTR_WIDTH = $clog2(CYCLE_COUNT);
        
        parameter OFFSET = HDR_SIZE % BYTE_LANES;
        
        // bus width assertions
 000001 initial begin
 000001     if (BYTE_LANES * 8 != DATA_WIDTH) begin
                $error("Error: AXI stream interface requires byte (8-bit) granularity (instance %m)");
                $finish;
            end
        end
        
        /*
        
        ARP Frame
        
         Field                       Length
         Destination MAC address     6 octets
         Source MAC address          6 octets
         Ethertype (0x0806)          2 octets
         HTYPE (1)                   2 octets
         PTYPE (0x0800)              2 octets
         HLEN (6)                    1 octets
         PLEN (4)                    1 octets
         OPER                        2 octets
         SHA Sender MAC              6 octets
         SPA Sender IP               4 octets
         THA Target MAC              6 octets
         TPA Target IP               4 octets
        
        This module receives an ARP frame with header fields in parallel  and
        transmits the complete Ethernet payload on an AXI interface.
        
        */
        
        // datapath control signals
        reg store_frame;
        
 000001 reg send_arp_header_reg = 1'b0, send_arp_header_next;
 000001 reg [PTR_WIDTH-1:0] ptr_reg = 0, ptr_next;
        
 000001 reg [15:0] arp_htype_reg = 16'd0;
 000001 reg [15:0] arp_ptype_reg = 16'd0;
 000001 reg [15:0] arp_oper_reg = 16'd0;
 000001 reg [47:0] arp_sha_reg = 48'd0;
 000001 reg [31:0] arp_spa_reg = 32'd0;
 000001 reg [47:0] arp_tha_reg = 48'd0;
 000001 reg [31:0] arp_tpa_reg = 32'd0;
        
 000001 reg s_frame_ready_reg = 1'b0, s_frame_ready_next;
        
 000001 reg m_eth_hdr_valid_reg = 1'b0, m_eth_hdr_valid_next;
 000001 reg [47:0] m_eth_dest_mac_reg = 48'd0;
 000001 reg [47:0] m_eth_src_mac_reg = 48'd0;
 000001 reg [15:0] m_eth_type_reg = 16'd0;
        
 000001 reg busy_reg = 1'b0;
        
        // internal datapath
        reg [DATA_WIDTH-1:0] m_eth_payload_axis_tdata_int;
        reg [KEEP_WIDTH-1:0] m_eth_payload_axis_tkeep_int;
        reg                  m_eth_payload_axis_tvalid_int;
 000001 reg                  m_eth_payload_axis_tready_int_reg = 1'b0;
        reg                  m_eth_payload_axis_tlast_int;
        reg                  m_eth_payload_axis_tuser_int;
        wire                 m_eth_payload_axis_tready_int_early;
        
        assign s_frame_ready = s_frame_ready_reg;
        
        assign m_eth_hdr_valid = m_eth_hdr_valid_reg;
        assign m_eth_dest_mac = m_eth_dest_mac_reg;
        assign m_eth_src_mac = m_eth_src_mac_reg;
        assign m_eth_type = m_eth_type_reg;
        
        assign busy = busy_reg;
        
 7806611 always @* begin
 7806611     send_arp_header_next = send_arp_header_reg;
 7806611     ptr_next = ptr_reg;
        
 7806611     s_frame_ready_next = 1'b0;
        
 7806611     store_frame = 1'b0;
        
 7806611     m_eth_hdr_valid_next = m_eth_hdr_valid_reg && !m_eth_hdr_ready;
        
 7806611     m_eth_payload_axis_tdata_int = {DATA_WIDTH{1'b0}};
 7806611     m_eth_payload_axis_tkeep_int = {KEEP_WIDTH{1'b0}};
 7806611     m_eth_payload_axis_tvalid_int = 1'b0;
 7806611     m_eth_payload_axis_tlast_int = 1'b0;
 7806611     m_eth_payload_axis_tuser_int = 1'b0;
        
 7806593     if (s_frame_ready && s_frame_valid) begin
 000018         store_frame = 1'b1;
 000018         m_eth_hdr_valid_next = 1'b1;
 000018         ptr_next = 0;
 000018         send_arp_header_next = 1'b1;
            end
        
 7793229     if (m_eth_payload_axis_tready_int_reg) begin
 7793157         if (send_arp_header_reg) begin
 000072             ptr_next = ptr_reg + 1;
        
 000072             m_eth_payload_axis_tdata_int = {DATA_WIDTH{1'b0}};
 000072             m_eth_payload_axis_tkeep_int = {KEEP_WIDTH{1'b0}};
 000072             m_eth_payload_axis_tvalid_int = 1'b1;
 000072             m_eth_payload_axis_tlast_int = 1'b0;
 000072             m_eth_payload_axis_tuser_int = 1'b0;
        
                    `define _HEADER_FIELD_(offset, field) \
                        if (ptr_reg == offset/BYTE_LANES) begin \
                            m_eth_payload_axis_tdata_int[(offset%BYTE_LANES)*8 +: 8] = field; \
                            m_eth_payload_axis_tkeep_int[offset%BYTE_LANES] = 1'b1; \
                        end
        
 000054             `_HEADER_FIELD_(0,  arp_htype_reg[1*8 +: 8])
 000054             `_HEADER_FIELD_(1,  arp_htype_reg[0*8 +: 8])
 000054             `_HEADER_FIELD_(2,  arp_ptype_reg[1*8 +: 8])
 000054             `_HEADER_FIELD_(3,  arp_ptype_reg[0*8 +: 8])
 000054             `_HEADER_FIELD_(4,  8'd6)
 000054             `_HEADER_FIELD_(5,  8'd4)
 000054             `_HEADER_FIELD_(6,  arp_oper_reg[1*8 +: 8])
 000054             `_HEADER_FIELD_(7,  arp_oper_reg[0*8 +: 8])
 000054             `_HEADER_FIELD_(8,  arp_sha_reg[5*8 +: 8])
 000054             `_HEADER_FIELD_(9,  arp_sha_reg[4*8 +: 8])
 000054             `_HEADER_FIELD_(10, arp_sha_reg[3*8 +: 8])
 000054             `_HEADER_FIELD_(11, arp_sha_reg[2*8 +: 8])
 000054             `_HEADER_FIELD_(12, arp_sha_reg[1*8 +: 8])
 000054             `_HEADER_FIELD_(13, arp_sha_reg[0*8 +: 8])
 000054             `_HEADER_FIELD_(14, arp_spa_reg[3*8 +: 8])
 000054             `_HEADER_FIELD_(15, arp_spa_reg[2*8 +: 8])
 000054             `_HEADER_FIELD_(16, arp_spa_reg[1*8 +: 8])
 000054             `_HEADER_FIELD_(17, arp_spa_reg[0*8 +: 8])
 000054             `_HEADER_FIELD_(18, arp_tha_reg[5*8 +: 8])
 000054             `_HEADER_FIELD_(19, arp_tha_reg[4*8 +: 8])
 000054             `_HEADER_FIELD_(20, arp_tha_reg[3*8 +: 8])
 000054             `_HEADER_FIELD_(21, arp_tha_reg[2*8 +: 8])
 000054             `_HEADER_FIELD_(22, arp_tha_reg[1*8 +: 8])
 000054             `_HEADER_FIELD_(23, arp_tha_reg[0*8 +: 8])
 000054             `_HEADER_FIELD_(24, arp_tpa_reg[3*8 +: 8])
 000054             `_HEADER_FIELD_(25, arp_tpa_reg[2*8 +: 8])
 000054             `_HEADER_FIELD_(26, arp_tpa_reg[1*8 +: 8])
 000054             `_HEADER_FIELD_(27, arp_tpa_reg[0*8 +: 8])
        
 000054             if (ptr_reg == 27/BYTE_LANES) begin
 000018                 m_eth_payload_axis_tlast_int = 1'b1;
 000018                 send_arp_header_next = 1'b0;
                    end
        
                    `undef _HEADER_FIELD_
                end
            end
        
 7806611     s_frame_ready_next = !m_eth_hdr_valid_next && !send_arp_header_next;
        end
        
 859379 always @(posedge clk) begin
 859379     send_arp_header_reg <= send_arp_header_next;
 859379     ptr_reg <= ptr_next;
        
 859379     s_frame_ready_reg <= s_frame_ready_next;
        
 859379     m_eth_hdr_valid_reg <= m_eth_hdr_valid_next;
        
 859379     busy_reg <= send_arp_header_next;
        
 859377     if (store_frame) begin
 000002         m_eth_dest_mac_reg <= s_eth_dest_mac;
 000002         m_eth_src_mac_reg <= s_eth_src_mac;
 000002         m_eth_type_reg <= s_eth_type;
 000002         arp_htype_reg <= s_arp_htype;
 000002         arp_ptype_reg <= s_arp_ptype;
 000002         arp_oper_reg <= s_arp_oper;
 000002         arp_sha_reg <= s_arp_sha;
 000002         arp_spa_reg <= s_arp_spa;
 000002         arp_tha_reg <= s_arp_tha;
 000002         arp_tpa_reg <= s_arp_tpa;
            end
        
 857900     if (rst) begin
 001479         send_arp_header_reg <= 1'b0;
 001479         ptr_reg <= 0;
 001479         s_frame_ready_reg <= 1'b0;
 001479         m_eth_hdr_valid_reg <= 1'b0;
 001479         busy_reg <= 1'b0;
            end
        end
        
        // output datapath logic
 000001 reg [DATA_WIDTH-1:0] m_eth_payload_axis_tdata_reg = {DATA_WIDTH{1'b0}};
 000001 reg [KEEP_WIDTH-1:0] m_eth_payload_axis_tkeep_reg = {KEEP_WIDTH{1'b0}};
 000001 reg                  m_eth_payload_axis_tvalid_reg = 1'b0, m_eth_payload_axis_tvalid_next;
 000001 reg                  m_eth_payload_axis_tlast_reg = 1'b0;
 000001 reg                  m_eth_payload_axis_tuser_reg = 1'b0;
        
 000001 reg [DATA_WIDTH-1:0] temp_m_eth_payload_axis_tdata_reg = {DATA_WIDTH{1'b0}};
 000001 reg [KEEP_WIDTH-1:0] temp_m_eth_payload_axis_tkeep_reg = {KEEP_WIDTH{1'b0}};
 000001 reg                  temp_m_eth_payload_axis_tvalid_reg = 1'b0, temp_m_eth_payload_axis_tvalid_next;
 000001 reg                  temp_m_eth_payload_axis_tlast_reg = 1'b0;
 000001 reg                  temp_m_eth_payload_axis_tuser_reg = 1'b0;
        
        // datapath control
        reg store_eth_payload_int_to_output;
        reg store_eth_payload_int_to_temp;
        reg store_eth_payload_axis_temp_to_output;
        
        assign m_eth_payload_axis_tdata = m_eth_payload_axis_tdata_reg;
~7806611 assign m_eth_payload_axis_tkeep = KEEP_ENABLE ? m_eth_payload_axis_tkeep_reg : {KEEP_WIDTH{1'b1}};
        assign m_eth_payload_axis_tvalid = m_eth_payload_axis_tvalid_reg;
        assign m_eth_payload_axis_tlast = m_eth_payload_axis_tlast_reg;
        assign m_eth_payload_axis_tuser = m_eth_payload_axis_tuser_reg;
        
        // enable ready input next cycle if output is ready or if both output registers are empty
        assign m_eth_payload_axis_tready_int_early = m_eth_payload_axis_tready || (!temp_m_eth_payload_axis_tvalid_reg && !m_eth_payload_axis_tvalid_reg);
        
 7806611 always @* begin
            // transfer sink ready state to source
 7806611     m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_reg;
 7806611     temp_m_eth_payload_axis_tvalid_next = temp_m_eth_payload_axis_tvalid_reg;
        
 7806611     store_eth_payload_int_to_output = 1'b0;
 7806611     store_eth_payload_int_to_temp = 1'b0;
 7806611     store_eth_payload_axis_temp_to_output = 1'b0;
        
 7793229     if (m_eth_payload_axis_tready_int_reg) begin
                // input is ready
~7793229         if (m_eth_payload_axis_tready || !m_eth_payload_axis_tvalid_reg) begin
                    // output is ready or currently not valid, transfer data to output
 7793229             m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_int;
 7793229             store_eth_payload_int_to_output = 1'b1;
%000000         end else begin
                    // output is not ready, store input in temp
%000000             temp_m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_int;
%000000             store_eth_payload_int_to_temp = 1'b1;
                end
~013382     end else if (m_eth_payload_axis_tready) begin
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
        
