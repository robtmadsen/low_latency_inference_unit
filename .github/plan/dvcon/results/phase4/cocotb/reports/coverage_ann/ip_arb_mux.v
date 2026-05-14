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
         * IP arbitrated multiplexer
         */
        module ip_arb_mux #
        (
            parameter S_COUNT = 4,
            parameter DATA_WIDTH = 8,
            parameter KEEP_ENABLE = (DATA_WIDTH>8),
            parameter KEEP_WIDTH = (DATA_WIDTH/8),
            parameter ID_ENABLE = 0,
            parameter ID_WIDTH = 8,
            parameter DEST_ENABLE = 0,
            parameter DEST_WIDTH = 8,
            parameter USER_ENABLE = 1,
            parameter USER_WIDTH = 1,
            // select round robin arbitration
            parameter ARB_TYPE_ROUND_ROBIN = 0,
            // LSB priority selection
            parameter ARB_LSB_HIGH_PRIORITY = 1
        )
        (
            input  wire                          clk,
            input  wire                          rst,
        
            /*
             * IP frame inputs
             */
            input  wire [S_COUNT-1:0]            s_ip_hdr_valid,
            output wire [S_COUNT-1:0]            s_ip_hdr_ready,
            input  wire [S_COUNT*48-1:0]         s_eth_dest_mac,
            input  wire [S_COUNT*48-1:0]         s_eth_src_mac,
            input  wire [S_COUNT*16-1:0]         s_eth_type,
            input  wire [S_COUNT*4-1:0]          s_ip_version,
            input  wire [S_COUNT*4-1:0]          s_ip_ihl,
            input  wire [S_COUNT*6-1:0]          s_ip_dscp,
            input  wire [S_COUNT*2-1:0]          s_ip_ecn,
            input  wire [S_COUNT*16-1:0]         s_ip_length,
            input  wire [S_COUNT*16-1:0]         s_ip_identification,
            input  wire [S_COUNT*3-1:0]          s_ip_flags,
            input  wire [S_COUNT*13-1:0]         s_ip_fragment_offset,
            input  wire [S_COUNT*8-1:0]          s_ip_ttl,
            input  wire [S_COUNT*8-1:0]          s_ip_protocol,
            input  wire [S_COUNT*16-1:0]         s_ip_header_checksum,
            input  wire [S_COUNT*32-1:0]         s_ip_source_ip,
            input  wire [S_COUNT*32-1:0]         s_ip_dest_ip,
            input  wire [S_COUNT*DATA_WIDTH-1:0] s_ip_payload_axis_tdata,
            input  wire [S_COUNT*KEEP_WIDTH-1:0] s_ip_payload_axis_tkeep,
            input  wire [S_COUNT-1:0]            s_ip_payload_axis_tvalid,
            output wire [S_COUNT-1:0]            s_ip_payload_axis_tready,
            input  wire [S_COUNT-1:0]            s_ip_payload_axis_tlast,
            input  wire [S_COUNT*ID_WIDTH-1:0]   s_ip_payload_axis_tid,
            input  wire [S_COUNT*DEST_WIDTH-1:0] s_ip_payload_axis_tdest,
            input  wire [S_COUNT*USER_WIDTH-1:0] s_ip_payload_axis_tuser,
        
            /*
             * IP frame output
             */
            output wire                          m_ip_hdr_valid,
            input  wire                          m_ip_hdr_ready,
            output wire [47:0]                   m_eth_dest_mac,
            output wire [47:0]                   m_eth_src_mac,
            output wire [15:0]                   m_eth_type,
            output wire [3:0]                    m_ip_version,
            output wire [3:0]                    m_ip_ihl,
            output wire [5:0]                    m_ip_dscp,
            output wire [1:0]                    m_ip_ecn,
            output wire [15:0]                   m_ip_length,
            output wire [15:0]                   m_ip_identification,
            output wire [2:0]                    m_ip_flags,
            output wire [12:0]                   m_ip_fragment_offset,
            output wire [7:0]                    m_ip_ttl,
            output wire [7:0]                    m_ip_protocol,
            output wire [15:0]                   m_ip_header_checksum,
            output wire [31:0]                   m_ip_source_ip,
            output wire [31:0]                   m_ip_dest_ip,
            output wire [DATA_WIDTH-1:0]         m_ip_payload_axis_tdata,
            output wire [KEEP_WIDTH-1:0]         m_ip_payload_axis_tkeep,
            output wire                          m_ip_payload_axis_tvalid,
            input  wire                          m_ip_payload_axis_tready,
            output wire                          m_ip_payload_axis_tlast,
            output wire [ID_WIDTH-1:0]           m_ip_payload_axis_tid,
            output wire [DEST_WIDTH-1:0]         m_ip_payload_axis_tdest,
            output wire [USER_WIDTH-1:0]         m_ip_payload_axis_tuser
        );
        
        parameter CL_S_COUNT = $clog2(S_COUNT);
        
 000001 reg frame_reg = 1'b0, frame_next;
        
 000001 reg [S_COUNT-1:0] s_ip_hdr_ready_reg = {S_COUNT{1'b0}}, s_ip_hdr_ready_next;
        
 000001 reg m_ip_hdr_valid_reg = 1'b0, m_ip_hdr_valid_next;
 000001 reg [47:0] m_eth_dest_mac_reg = 48'd0, m_eth_dest_mac_next;
 000001 reg [47:0] m_eth_src_mac_reg = 48'd0, m_eth_src_mac_next;
 000001 reg [15:0] m_eth_type_reg = 16'd0, m_eth_type_next;
 000001 reg [3:0]  m_ip_version_reg = 4'd0, m_ip_version_next;
 000001 reg [3:0]  m_ip_ihl_reg = 4'd0, m_ip_ihl_next;
 000001 reg [5:0]  m_ip_dscp_reg = 6'd0, m_ip_dscp_next;
 000001 reg [1:0]  m_ip_ecn_reg = 2'd0, m_ip_ecn_next;
 000001 reg [15:0] m_ip_length_reg = 16'd0, m_ip_length_next;
 000001 reg [15:0] m_ip_identification_reg = 16'd0, m_ip_identification_next;
 000001 reg [2:0]  m_ip_flags_reg = 3'd0, m_ip_flags_next;
 000001 reg [12:0] m_ip_fragment_offset_reg = 13'd0, m_ip_fragment_offset_next;
 000001 reg [7:0]  m_ip_ttl_reg = 8'd0, m_ip_ttl_next;
 000001 reg [7:0]  m_ip_protocol_reg = 8'd0, m_ip_protocol_next;
 000001 reg [15:0] m_ip_header_checksum_reg = 16'd0, m_ip_header_checksum_next;
 000001 reg [31:0] m_ip_source_ip_reg = 32'd0, m_ip_source_ip_next;
 000001 reg [31:0] m_ip_dest_ip_reg = 32'd0, m_ip_dest_ip_next;
        
        wire [S_COUNT-1:0] request;
        wire [S_COUNT-1:0] acknowledge;
        wire [S_COUNT-1:0] grant;
        wire grant_valid;
        wire [CL_S_COUNT-1:0] grant_encoded;
        
        // internal datapath
        reg  [DATA_WIDTH-1:0] m_ip_payload_axis_tdata_int;
        reg  [KEEP_WIDTH-1:0] m_ip_payload_axis_tkeep_int;
        reg                   m_ip_payload_axis_tvalid_int;
 000001 reg                   m_ip_payload_axis_tready_int_reg = 1'b0;
        reg                   m_ip_payload_axis_tlast_int;
        reg  [ID_WIDTH-1:0]   m_ip_payload_axis_tid_int;
        reg  [DEST_WIDTH-1:0] m_ip_payload_axis_tdest_int;
        reg  [USER_WIDTH-1:0] m_ip_payload_axis_tuser_int;
        wire                  m_ip_payload_axis_tready_int_early;
        
        assign s_ip_hdr_ready = s_ip_hdr_ready_reg;
        
        assign s_ip_payload_axis_tready = (m_ip_payload_axis_tready_int_reg && grant_valid) << grant_encoded;
        
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
        
        // mux for incoming packet
        wire [DATA_WIDTH-1:0] current_s_tdata  = s_ip_payload_axis_tdata[grant_encoded*DATA_WIDTH +: DATA_WIDTH];
        wire [KEEP_WIDTH-1:0] current_s_tkeep  = s_ip_payload_axis_tkeep[grant_encoded*KEEP_WIDTH +: KEEP_WIDTH];
        wire                  current_s_tvalid = s_ip_payload_axis_tvalid[grant_encoded];
        wire                  current_s_tready = s_ip_payload_axis_tready[grant_encoded];
        wire                  current_s_tlast  = s_ip_payload_axis_tlast[grant_encoded];
        wire [ID_WIDTH-1:0]   current_s_tid    = s_ip_payload_axis_tid[grant_encoded*ID_WIDTH +: ID_WIDTH];
        wire [DEST_WIDTH-1:0] current_s_tdest  = s_ip_payload_axis_tdest[grant_encoded*DEST_WIDTH +: DEST_WIDTH];
        wire [USER_WIDTH-1:0] current_s_tuser  = s_ip_payload_axis_tuser[grant_encoded*USER_WIDTH +: USER_WIDTH];
        
        // arbiter instance
        arbiter #(
            .PORTS(S_COUNT),
            .ARB_TYPE_ROUND_ROBIN(ARB_TYPE_ROUND_ROBIN),
            .ARB_BLOCK(1),
            .ARB_BLOCK_ACK(1),
            .ARB_LSB_HIGH_PRIORITY(ARB_LSB_HIGH_PRIORITY)
        )
        arb_inst (
            .clk(clk),
            .rst(rst),
            .request(request),
            .acknowledge(acknowledge),
            .grant(grant),
            .grant_valid(grant_valid),
            .grant_encoded(grant_encoded)
        );
        
        assign request = s_ip_hdr_valid & ~grant;
        assign acknowledge = grant & s_ip_payload_axis_tvalid & s_ip_payload_axis_tready & s_ip_payload_axis_tlast;
        
 7806611 always @* begin
 7806611     frame_next = frame_reg;
        
 7806611     s_ip_hdr_ready_next = {S_COUNT{1'b0}};
        
 7806611     m_ip_hdr_valid_next = m_ip_hdr_valid_reg && !m_ip_hdr_ready;
 7806611     m_eth_dest_mac_next = m_eth_dest_mac_reg;
 7806611     m_eth_src_mac_next = m_eth_src_mac_reg;
 7806611     m_eth_type_next = m_eth_type_reg;
 7806611     m_ip_version_next = m_ip_version_reg;
 7806611     m_ip_ihl_next = m_ip_ihl_reg;
 7806611     m_ip_dscp_next = m_ip_dscp_reg;
 7806611     m_ip_ecn_next = m_ip_ecn_reg;
 7806611     m_ip_length_next = m_ip_length_reg;
 7806611     m_ip_identification_next = m_ip_identification_reg;
 7806611     m_ip_flags_next = m_ip_flags_reg;
 7806611     m_ip_fragment_offset_next = m_ip_fragment_offset_reg;
 7806611     m_ip_ttl_next = m_ip_ttl_reg;
 7806611     m_ip_protocol_next = m_ip_protocol_reg;
 7806611     m_ip_header_checksum_next = m_ip_header_checksum_reg;
 7806611     m_ip_source_ip_next = m_ip_source_ip_reg;
 7806611     m_ip_dest_ip_next = m_ip_dest_ip_reg;
        
~7806611     if (s_ip_payload_axis_tvalid[grant_encoded] && s_ip_payload_axis_tready[grant_encoded]) begin
                // end of frame detection
%000000         if (s_ip_payload_axis_tlast[grant_encoded]) begin
%000000             frame_next = 1'b0;
                end
            end
        
~7806611     if (!frame_reg && grant_valid && (m_ip_hdr_ready || !m_ip_hdr_valid)) begin
                // start of frame
%000000         frame_next = 1'b1;
        
%000000         s_ip_hdr_ready_next = grant;
        
%000000         m_ip_hdr_valid_next = 1'b1;
%000000         m_eth_dest_mac_next = s_eth_dest_mac[grant_encoded*48 +: 48];
%000000         m_eth_src_mac_next = s_eth_src_mac[grant_encoded*48 +: 48];
%000000         m_eth_type_next = s_eth_type[grant_encoded*16 +: 16];
%000000         m_ip_version_next = s_ip_version[grant_encoded*4 +: 4];
%000000         m_ip_ihl_next = s_ip_ihl[grant_encoded*4 +: 4];
%000000         m_ip_dscp_next = s_ip_dscp[grant_encoded*6 +: 6];
%000000         m_ip_ecn_next = s_ip_ecn[grant_encoded*2 +: 2];
%000000         m_ip_length_next = s_ip_length[grant_encoded*16 +: 16];
%000000         m_ip_identification_next = s_ip_identification[grant_encoded*16 +: 16];
%000000         m_ip_flags_next = s_ip_flags[grant_encoded*3 +: 3];
%000000         m_ip_fragment_offset_next = s_ip_fragment_offset[grant_encoded*13 +: 13];
%000000         m_ip_ttl_next = s_ip_ttl[grant_encoded*8 +: 8];
%000000         m_ip_protocol_next = s_ip_protocol[grant_encoded*8 +: 8];
%000000         m_ip_header_checksum_next = s_ip_header_checksum[grant_encoded*16 +: 16];
%000000         m_ip_source_ip_next = s_ip_source_ip[grant_encoded*32 +: 32];
%000000         m_ip_dest_ip_next = s_ip_dest_ip[grant_encoded*32 +: 32];
            end
        
            // pass through selected packet data
 7806611     m_ip_payload_axis_tdata_int  = current_s_tdata;
 7806611     m_ip_payload_axis_tkeep_int  = current_s_tkeep;
 7806611     m_ip_payload_axis_tvalid_int = current_s_tvalid && m_ip_payload_axis_tready_int_reg && grant_valid;
 7806611     m_ip_payload_axis_tlast_int  = current_s_tlast;
 7806611     m_ip_payload_axis_tid_int    = current_s_tid;
 7806611     m_ip_payload_axis_tdest_int  = current_s_tdest;
 7806611     m_ip_payload_axis_tuser_int  = current_s_tuser;
        end
        
 859379 always @(posedge clk) begin
 859379     frame_reg <= frame_next;
        
 859379     s_ip_hdr_ready_reg <= s_ip_hdr_ready_next;
        
 859379     m_ip_hdr_valid_reg <= m_ip_hdr_valid_next;
 859379     m_eth_dest_mac_reg <= m_eth_dest_mac_next;
 859379     m_eth_src_mac_reg <= m_eth_src_mac_next;
 859379     m_eth_type_reg <= m_eth_type_next;
 859379     m_ip_version_reg <= m_ip_version_next;
 859379     m_ip_ihl_reg <= m_ip_ihl_next;
 859379     m_ip_dscp_reg <= m_ip_dscp_next;
 859379     m_ip_ecn_reg <= m_ip_ecn_next;
 859379     m_ip_length_reg <= m_ip_length_next;
 859379     m_ip_identification_reg <= m_ip_identification_next;
 859379     m_ip_flags_reg <= m_ip_flags_next;
 859379     m_ip_fragment_offset_reg <= m_ip_fragment_offset_next;
 859379     m_ip_ttl_reg <= m_ip_ttl_next;
 859379     m_ip_protocol_reg <= m_ip_protocol_next;
 859379     m_ip_header_checksum_reg <= m_ip_header_checksum_next;
 859379     m_ip_source_ip_reg <= m_ip_source_ip_next;
 859379     m_ip_dest_ip_reg <= m_ip_dest_ip_next;
        
 857900     if (rst) begin
 001479         frame_reg <= 1'b0;
 001479         s_ip_hdr_ready_reg <= {S_COUNT{1'b0}};
 001479         m_ip_hdr_valid_reg <= 1'b0;
            end
        end
        
        // output datapath logic
 000001 reg [DATA_WIDTH-1:0] m_ip_payload_axis_tdata_reg  = {DATA_WIDTH{1'b0}};
 000001 reg [KEEP_WIDTH-1:0] m_ip_payload_axis_tkeep_reg  = {KEEP_WIDTH{1'b0}};
 000001 reg                  m_ip_payload_axis_tvalid_reg = 1'b0, m_ip_payload_axis_tvalid_next;
 000001 reg                  m_ip_payload_axis_tlast_reg  = 1'b0;
 000001 reg [ID_WIDTH-1:0]   m_ip_payload_axis_tid_reg    = {ID_WIDTH{1'b0}};
 000001 reg [DEST_WIDTH-1:0] m_ip_payload_axis_tdest_reg  = {DEST_WIDTH{1'b0}};
 000001 reg [USER_WIDTH-1:0] m_ip_payload_axis_tuser_reg  = {USER_WIDTH{1'b0}};
        
 000001 reg [DATA_WIDTH-1:0] temp_m_ip_payload_axis_tdata_reg  = {DATA_WIDTH{1'b0}};
 000001 reg [KEEP_WIDTH-1:0] temp_m_ip_payload_axis_tkeep_reg  = {KEEP_WIDTH{1'b0}};
 000001 reg                  temp_m_ip_payload_axis_tvalid_reg = 1'b0, temp_m_ip_payload_axis_tvalid_next;
 000001 reg                  temp_m_ip_payload_axis_tlast_reg  = 1'b0;
 000001 reg [ID_WIDTH-1:0]   temp_m_ip_payload_axis_tid_reg    = {ID_WIDTH{1'b0}};
 000001 reg [DEST_WIDTH-1:0] temp_m_ip_payload_axis_tdest_reg  = {DEST_WIDTH{1'b0}};
 000001 reg [USER_WIDTH-1:0] temp_m_ip_payload_axis_tuser_reg  = {USER_WIDTH{1'b0}};
        
        // datapath control
        reg store_axis_int_to_output;
        reg store_axis_int_to_temp;
        reg store_ip_payload_axis_temp_to_output;
        
        assign m_ip_payload_axis_tdata  = m_ip_payload_axis_tdata_reg;
~7806611 assign m_ip_payload_axis_tkeep  = KEEP_ENABLE ? m_ip_payload_axis_tkeep_reg : {KEEP_WIDTH{1'b1}};
        assign m_ip_payload_axis_tvalid = m_ip_payload_axis_tvalid_reg;
        assign m_ip_payload_axis_tlast  = m_ip_payload_axis_tlast_reg;
~000001 assign m_ip_payload_axis_tid    = ID_ENABLE   ? m_ip_payload_axis_tid_reg   : {ID_WIDTH{1'b0}};
~000001 assign m_ip_payload_axis_tdest  = DEST_ENABLE ? m_ip_payload_axis_tdest_reg : {DEST_WIDTH{1'b0}};
~7806611 assign m_ip_payload_axis_tuser  = USER_ENABLE ? m_ip_payload_axis_tuser_reg : {USER_WIDTH{1'b0}};
        
        // enable ready input next cycle if output is ready or if both output registers are empty
        assign m_ip_payload_axis_tready_int_early = m_ip_payload_axis_tready || (!temp_m_ip_payload_axis_tvalid_reg && !m_ip_payload_axis_tvalid_reg);
        
 7806611 always @* begin
            // transfer sink ready state to source
 7806611     m_ip_payload_axis_tvalid_next = m_ip_payload_axis_tvalid_reg;
 7806611     temp_m_ip_payload_axis_tvalid_next = temp_m_ip_payload_axis_tvalid_reg;
        
 7806611     store_axis_int_to_output = 1'b0;
 7806611     store_axis_int_to_temp = 1'b0;
 7806611     store_ip_payload_axis_temp_to_output = 1'b0;
        
 7793229     if (m_ip_payload_axis_tready_int_reg) begin
                // input is ready
~7793229         if (m_ip_payload_axis_tready || !m_ip_payload_axis_tvalid_reg) begin
                    // output is ready or currently not valid, transfer data to output
 7793229             m_ip_payload_axis_tvalid_next = m_ip_payload_axis_tvalid_int;
 7793229             store_axis_int_to_output = 1'b1;
%000000         end else begin
                    // output is not ready, store input in temp
%000000             temp_m_ip_payload_axis_tvalid_next = m_ip_payload_axis_tvalid_int;
%000000             store_axis_int_to_temp = 1'b1;
                end
~013382     end else if (m_ip_payload_axis_tready) begin
                // input is not ready, but output is ready
%000000         m_ip_payload_axis_tvalid_next = temp_m_ip_payload_axis_tvalid_reg;
%000000         temp_m_ip_payload_axis_tvalid_next = 1'b0;
%000000         store_ip_payload_axis_temp_to_output = 1'b1;
            end
        end
        
 859379 always @(posedge clk) begin
 859379     m_ip_payload_axis_tvalid_reg <= m_ip_payload_axis_tvalid_next;
 859379     m_ip_payload_axis_tready_int_reg <= m_ip_payload_axis_tready_int_early;
 859379     temp_m_ip_payload_axis_tvalid_reg <= temp_m_ip_payload_axis_tvalid_next;
        
            // datapath
 857899     if (store_axis_int_to_output) begin
 857899         m_ip_payload_axis_tdata_reg <= m_ip_payload_axis_tdata_int;
 857899         m_ip_payload_axis_tkeep_reg <= m_ip_payload_axis_tkeep_int;
 857899         m_ip_payload_axis_tlast_reg <= m_ip_payload_axis_tlast_int;
 857899         m_ip_payload_axis_tid_reg   <= m_ip_payload_axis_tid_int;
 857899         m_ip_payload_axis_tdest_reg <= m_ip_payload_axis_tdest_int;
 857899         m_ip_payload_axis_tuser_reg <= m_ip_payload_axis_tuser_int;
~001480     end else if (store_ip_payload_axis_temp_to_output) begin
%000000         m_ip_payload_axis_tdata_reg <= temp_m_ip_payload_axis_tdata_reg;
%000000         m_ip_payload_axis_tkeep_reg <= temp_m_ip_payload_axis_tkeep_reg;
%000000         m_ip_payload_axis_tlast_reg <= temp_m_ip_payload_axis_tlast_reg;
%000000         m_ip_payload_axis_tid_reg   <= temp_m_ip_payload_axis_tid_reg;
%000000         m_ip_payload_axis_tdest_reg <= temp_m_ip_payload_axis_tdest_reg;
%000000         m_ip_payload_axis_tuser_reg <= temp_m_ip_payload_axis_tuser_reg;
            end
        
~859379     if (store_axis_int_to_temp) begin
%000000         temp_m_ip_payload_axis_tdata_reg <= m_ip_payload_axis_tdata_int;
%000000         temp_m_ip_payload_axis_tkeep_reg <= m_ip_payload_axis_tkeep_int;
%000000         temp_m_ip_payload_axis_tlast_reg <= m_ip_payload_axis_tlast_int;
%000000         temp_m_ip_payload_axis_tid_reg   <= m_ip_payload_axis_tid_int;
%000000         temp_m_ip_payload_axis_tdest_reg <= m_ip_payload_axis_tdest_int;
%000000         temp_m_ip_payload_axis_tuser_reg <= m_ip_payload_axis_tuser_int;
            end
        
 857900     if (rst) begin
 001479         m_ip_payload_axis_tvalid_reg <= 1'b0;
 001479         m_ip_payload_axis_tready_int_reg <= 1'b0;
 001479         temp_m_ip_payload_axis_tvalid_reg <= 1'b0;
            end
        end
        
        endmodule
        
        `resetall
        
