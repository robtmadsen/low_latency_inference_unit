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
         * AXI4-Stream ethernet frame receiver (AXI in, Ethernet frame out)
         */
        module eth_axis_rx #
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
            input  wire                  clk,
            input  wire                  rst,
        
            /*
             * AXI input
             */
            input  wire [DATA_WIDTH-1:0] s_axis_tdata,
            input  wire [KEEP_WIDTH-1:0] s_axis_tkeep,
            input  wire                  s_axis_tvalid,
            output wire                  s_axis_tready,
            input  wire                  s_axis_tlast,
            input  wire                  s_axis_tuser,
        
            /*
             * Ethernet frame output
             */
            output wire                  m_eth_hdr_valid,
            input  wire                  m_eth_hdr_ready,
            output wire [47:0]           m_eth_dest_mac,
            output wire [47:0]           m_eth_src_mac,
            output wire [15:0]           m_eth_type,
            output wire [DATA_WIDTH-1:0] m_eth_payload_axis_tdata,
            output wire [KEEP_WIDTH-1:0] m_eth_payload_axis_tkeep,
            output wire                  m_eth_payload_axis_tvalid,
            input  wire                  m_eth_payload_axis_tready,
            output wire                  m_eth_payload_axis_tlast,
            output wire                  m_eth_payload_axis_tuser,
        
            /*
             * Status signals
             */
            output wire                  busy,
            output wire                  error_header_early_termination
        );
        
        parameter BYTE_LANES = KEEP_ENABLE ? KEEP_WIDTH : 1;
        
        parameter HDR_SIZE = 14;
        
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
        
        Ethernet frame
        
         Field                       Length
         Destination MAC address     6 octets
         Source MAC address          6 octets
         Ethertype                   2 octets
        
        This module receives an Ethernet frame on an AXI stream interface, decodes
        and strips the headers, then produces the header fields in parallel along
        with the payload in a separate AXI stream.
        
        */
        
 000001 reg read_eth_header_reg = 1'b1, read_eth_header_next;
 000001 reg read_eth_payload_reg = 1'b0, read_eth_payload_next;
 000001 reg [PTR_WIDTH-1:0] ptr_reg = 0, ptr_next;
        
        reg flush_save;
        reg transfer_in_save;
        
 000001 reg s_axis_tready_reg = 1'b0, s_axis_tready_next;
        
 000001 reg m_eth_hdr_valid_reg = 1'b0, m_eth_hdr_valid_next;
 000001 reg [47:0] m_eth_dest_mac_reg = 48'd0, m_eth_dest_mac_next;
 000001 reg [47:0] m_eth_src_mac_reg = 48'd0, m_eth_src_mac_next;
 000001 reg [15:0] m_eth_type_reg = 16'd0, m_eth_type_next;
        
 000001 reg busy_reg = 1'b0;
 000001 reg error_header_early_termination_reg = 1'b0, error_header_early_termination_next;
        
 000001 reg [DATA_WIDTH-1:0] save_axis_tdata_reg = 64'd0;
 000001 reg [KEEP_WIDTH-1:0] save_axis_tkeep_reg = 8'd0;
 000001 reg save_axis_tlast_reg = 1'b0;
 000001 reg save_axis_tuser_reg = 1'b0;
        
        reg [DATA_WIDTH-1:0] shift_axis_tdata;
        reg [KEEP_WIDTH-1:0] shift_axis_tkeep;
        reg shift_axis_tvalid;
        reg shift_axis_tlast;
        reg shift_axis_tuser;
        reg shift_axis_input_tready;
 000001 reg shift_axis_extra_cycle_reg = 1'b0;
        
        // internal datapath
        reg [DATA_WIDTH-1:0] m_eth_payload_axis_tdata_int;
        reg [KEEP_WIDTH-1:0] m_eth_payload_axis_tkeep_int;
        reg                  m_eth_payload_axis_tvalid_int;
 000001 reg                  m_eth_payload_axis_tready_int_reg = 1'b0;
        reg                  m_eth_payload_axis_tlast_int;
        reg                  m_eth_payload_axis_tuser_int;
        wire                 m_eth_payload_axis_tready_int_early;
        
        assign s_axis_tready = s_axis_tready_reg;
        
        assign m_eth_hdr_valid = m_eth_hdr_valid_reg;
        assign m_eth_dest_mac = m_eth_dest_mac_reg;
        assign m_eth_src_mac = m_eth_src_mac_reg;
        assign m_eth_type = m_eth_type_reg;
        
        assign busy = busy_reg;
        assign error_header_early_termination = error_header_early_termination_reg;
        
 7808137 always @* begin
%000000     if (OFFSET == 0) begin
                // passthrough if no overlap
%000000         shift_axis_tdata = s_axis_tdata;
%000000         shift_axis_tkeep = s_axis_tkeep;
%000000         shift_axis_tvalid = s_axis_tvalid;
%000000         shift_axis_tlast = s_axis_tlast;
%000000         shift_axis_tuser = s_axis_tuser;
%000000         shift_axis_input_tready = 1'b1;
 7807585     end else if (shift_axis_extra_cycle_reg) begin
 000552         shift_axis_tdata = {s_axis_tdata, save_axis_tdata_reg} >> (OFFSET*8);
 000552         shift_axis_tkeep = {{KEEP_WIDTH{1'b0}}, save_axis_tkeep_reg} >> OFFSET;
 000552         shift_axis_tvalid = 1'b1;
 000552         shift_axis_tlast = save_axis_tlast_reg;
 000552         shift_axis_tuser = save_axis_tuser_reg;
 000552         shift_axis_input_tready = flush_save;
 7807585     end else begin
 7807585         shift_axis_tdata = {s_axis_tdata, save_axis_tdata_reg} >> (OFFSET*8);
 7807585         shift_axis_tkeep = {s_axis_tkeep, save_axis_tkeep_reg} >> OFFSET;
 7807585         shift_axis_tvalid = s_axis_tvalid;
 7807585         shift_axis_tlast = (s_axis_tlast && ((s_axis_tkeep & ({KEEP_WIDTH{1'b1}} << OFFSET)) == 0));
 7807585         shift_axis_tuser = (s_axis_tuser && ((s_axis_tkeep & ({KEEP_WIDTH{1'b1}} << OFFSET)) == 0));
 7807585         shift_axis_input_tready = !(s_axis_tlast && s_axis_tready && s_axis_tvalid);
            end
        end
        
 7808137 always @* begin
 7808137     read_eth_header_next = read_eth_header_reg;
 7808137     read_eth_payload_next = read_eth_payload_reg;
 7808137     ptr_next = ptr_reg;
        
 7808137     s_axis_tready_next = m_eth_payload_axis_tready_int_early && shift_axis_input_tready && (!m_eth_hdr_valid || m_eth_hdr_ready);
        
 7808137     flush_save = 1'b0;
 7808137     transfer_in_save = 1'b0;
        
 7808137     m_eth_hdr_valid_next = m_eth_hdr_valid_reg && !m_eth_hdr_ready;
        
 7808137     m_eth_dest_mac_next = m_eth_dest_mac_reg;
 7808137     m_eth_src_mac_next = m_eth_src_mac_reg;
 7808137     m_eth_type_next = m_eth_type_reg;
        
 7808137     error_header_early_termination_next = 1'b0;
        
 7808137     m_eth_payload_axis_tdata_int = shift_axis_tdata;
 7808137     m_eth_payload_axis_tkeep_int = shift_axis_tkeep;
 7808137     m_eth_payload_axis_tvalid_int = 1'b0;
 7808137     m_eth_payload_axis_tlast_int = shift_axis_tlast;
 7808137     m_eth_payload_axis_tuser_int = shift_axis_tuser;
        
 7770895     if ((s_axis_tready && s_axis_tvalid) || (m_eth_payload_axis_tready_int_reg && shift_axis_extra_cycle_reg)) begin
 037242         transfer_in_save = 1'b1;
        
 031676         if (read_eth_header_reg) begin
                    // word transfer in - store it
 005566             ptr_next = ptr_reg + 1;
        
                    `define _HEADER_FIELD_(offset, field) \
                        if (ptr_reg == offset/BYTE_LANES && (!KEEP_ENABLE || s_axis_tkeep[offset%BYTE_LANES])) begin \
                            field = s_axis_tdata[(offset%BYTE_LANES)*8 +: 8]; \
                        end
        
 003140             `_HEADER_FIELD_(0,  m_eth_dest_mac_next[5*8 +: 8])
 003140             `_HEADER_FIELD_(1,  m_eth_dest_mac_next[4*8 +: 8])
 003140             `_HEADER_FIELD_(2,  m_eth_dest_mac_next[3*8 +: 8])
 003140             `_HEADER_FIELD_(3,  m_eth_dest_mac_next[2*8 +: 8])
 003140             `_HEADER_FIELD_(4,  m_eth_dest_mac_next[1*8 +: 8])
 003140             `_HEADER_FIELD_(5,  m_eth_dest_mac_next[0*8 +: 8])
 003140             `_HEADER_FIELD_(6,  m_eth_src_mac_next[5*8 +: 8])
 003140             `_HEADER_FIELD_(7,  m_eth_src_mac_next[4*8 +: 8])
 003140             `_HEADER_FIELD_(8,  m_eth_src_mac_next[3*8 +: 8])
 003140             `_HEADER_FIELD_(9,  m_eth_src_mac_next[2*8 +: 8])
 003140             `_HEADER_FIELD_(10, m_eth_src_mac_next[1*8 +: 8])
 003140             `_HEADER_FIELD_(11, m_eth_src_mac_next[0*8 +: 8])
 003140             `_HEADER_FIELD_(12, m_eth_type_next[1*8 +: 8])
 003140             `_HEADER_FIELD_(13, m_eth_type_next[0*8 +: 8])
        
 003140             if (ptr_reg == 13/BYTE_LANES && (!KEEP_ENABLE || s_axis_tkeep[13%BYTE_LANES])) begin
~003140                 if (!shift_axis_tlast) begin
 003140                     m_eth_hdr_valid_next = 1'b1;
 003140                     read_eth_header_next = 1'b0;
 003140                     read_eth_payload_next = 1'b1;
                        end
                    end
        
                    `undef _HEADER_FIELD_
                end
        
 031676         if (read_eth_payload_reg) begin
                    // transfer payload
 031676             m_eth_payload_axis_tdata_int = shift_axis_tdata;
 031676             m_eth_payload_axis_tkeep_int = shift_axis_tkeep;
 031676             m_eth_payload_axis_tvalid_int = 1'b1;
 031676             m_eth_payload_axis_tlast_int = shift_axis_tlast;
 031676             m_eth_payload_axis_tuser_int = shift_axis_tuser;
                end
        
 033474         if (shift_axis_tlast) begin
~003768             if (read_eth_header_next) begin
                        // don't have the whole header
%000000                 error_header_early_termination_next = 1'b1;
                    end
        
 003768             flush_save = 1'b1;
 003768             ptr_next = 1'b0;
 003768             read_eth_header_next = 1'b1;
 003768             read_eth_payload_next = 1'b0;
                end
            end
        end
        
 859379 always @(posedge clk) begin
 859379     read_eth_header_reg <= read_eth_header_next;
 859379     read_eth_payload_reg <= read_eth_payload_next;
 859379     ptr_reg <= ptr_next;
        
 859379     s_axis_tready_reg <= s_axis_tready_next;
        
 859379     m_eth_hdr_valid_reg <= m_eth_hdr_valid_next;
 859379     m_eth_dest_mac_reg <= m_eth_dest_mac_next;
 859379     m_eth_src_mac_reg <= m_eth_src_mac_next;
 859379     m_eth_type_reg <= m_eth_type_next;
        
 859379     error_header_early_termination_reg <= error_header_early_termination_next;
        
 859379     busy_reg <= (read_eth_payload_next || ptr_next != 0);
        
 855673     if (transfer_in_save) begin
 003706         save_axis_tdata_reg <= s_axis_tdata;
 003706         save_axis_tkeep_reg <= s_axis_tkeep;
 003706         save_axis_tuser_reg <= s_axis_tuser;
            end
        
 000314     if (flush_save) begin
 000314         save_axis_tlast_reg <= 1'b0;
 000314         shift_axis_extra_cycle_reg <= 1'b0;
 855673     end else if (transfer_in_save) begin
 003392         save_axis_tlast_reg <= s_axis_tlast;
~003392         shift_axis_extra_cycle_reg <= OFFSET ? s_axis_tlast && ((s_axis_tkeep & ({KEEP_WIDTH{1'b1}} << OFFSET)) != 0) : 1'b0;
            end
        
 857900     if (rst) begin
 001479         read_eth_header_reg <= 1'b1;
 001479         read_eth_payload_reg <= 1'b0;
 001479         ptr_reg <= 0;
 001479         s_axis_tready_reg <= 1'b0;
 001479         m_eth_hdr_valid_reg <= 1'b0;
 001479         save_axis_tlast_reg <= 1'b0;
 001479         shift_axis_extra_cycle_reg <= 1'b0;
 001479         busy_reg <= 1'b0;
 001479         error_header_early_termination_reg <= 1'b0;
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
        
 7808137 always @* begin
            // transfer sink ready state to source
 7808137     m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_reg;
 7808137     temp_m_eth_payload_axis_tvalid_next = temp_m_eth_payload_axis_tvalid_reg;
        
 7808137     store_eth_payload_int_to_output = 1'b0;
 7808137     store_eth_payload_int_to_temp = 1'b0;
 7808137     store_eth_payload_axis_temp_to_output = 1'b0;
            
 7791988     if (m_eth_payload_axis_tready_int_reg) begin
                // input is ready
 7789218         if (m_eth_payload_axis_tready || !m_eth_payload_axis_tvalid_reg) begin
                    // output is ready or currently not valid, transfer data to output
 7789218             m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_int;
 7789218             store_eth_payload_int_to_output = 1'b1;
 002770         end else begin
                    // output is not ready, store input in temp
 002770             temp_m_eth_payload_axis_tvalid_next = m_eth_payload_axis_tvalid_int;
 002770             store_eth_payload_int_to_temp = 1'b1;
                end
 012990     end else if (m_eth_payload_axis_tready) begin
                // input is not ready, but output is ready
 003159         m_eth_payload_axis_tvalid_next = temp_m_eth_payload_axis_tvalid_reg;
 003159         temp_m_eth_payload_axis_tvalid_next = 1'b0;
 003159         store_eth_payload_axis_temp_to_output = 1'b1;
            end
        end
        
 859379 always @(posedge clk) begin
 859379     m_eth_payload_axis_tvalid_reg <= m_eth_payload_axis_tvalid_next;
 859379     m_eth_payload_axis_tready_int_reg <= m_eth_payload_axis_tready_int_early;
 859379     temp_m_eth_payload_axis_tvalid_reg <= temp_m_eth_payload_axis_tvalid_next;
        
            // datapath
 857347     if (store_eth_payload_int_to_output) begin
 857347         m_eth_payload_axis_tdata_reg <= m_eth_payload_axis_tdata_int;
 857347         m_eth_payload_axis_tkeep_reg <= m_eth_payload_axis_tkeep_int;
 857347         m_eth_payload_axis_tlast_reg <= m_eth_payload_axis_tlast_int;
 857347         m_eth_payload_axis_tuser_reg <= m_eth_payload_axis_tuser_int;
 001712     end else if (store_eth_payload_axis_temp_to_output) begin
 000320         m_eth_payload_axis_tdata_reg <= temp_m_eth_payload_axis_tdata_reg;
 000320         m_eth_payload_axis_tkeep_reg <= temp_m_eth_payload_axis_tkeep_reg;
 000320         m_eth_payload_axis_tlast_reg <= temp_m_eth_payload_axis_tlast_reg;
 000320         m_eth_payload_axis_tuser_reg <= temp_m_eth_payload_axis_tuser_reg;
            end
        
 859103     if (store_eth_payload_int_to_temp) begin
 000276         temp_m_eth_payload_axis_tdata_reg <= m_eth_payload_axis_tdata_int;
 000276         temp_m_eth_payload_axis_tkeep_reg <= m_eth_payload_axis_tkeep_int;
 000276         temp_m_eth_payload_axis_tlast_reg <= m_eth_payload_axis_tlast_int;
 000276         temp_m_eth_payload_axis_tuser_reg <= m_eth_payload_axis_tuser_int;
            end
        
 857900     if (rst) begin
 001479         m_eth_payload_axis_tvalid_reg <= 1'b0;
 001479         m_eth_payload_axis_tready_int_reg <= 1'b0;
 001479         temp_m_eth_payload_axis_tvalid_reg <= 1'b0;
            end
        end
        
        endmodule
        
        `resetall
        
