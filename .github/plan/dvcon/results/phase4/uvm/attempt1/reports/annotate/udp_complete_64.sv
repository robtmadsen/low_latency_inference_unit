//      // verilator_coverage annotation
        // udp_complete_64.sv — Simulation stub for Forencich udp_complete_64
        // Strips IPv4 (20B) + UDP (8B) headers from Ethernet payload,
        // outputs raw UDP payload for MoldUDP64 processing.
        
        /* verilator lint_off UNUSEDSIGNAL */
        /* verilator lint_off UNDRIVEN */
        
        module udp_complete_64 (
            input  wire        clk,
            input  wire        rst,
        
            // Ethernet RX input
            input  wire        s_eth_hdr_valid,
            output reg         s_eth_hdr_ready,
            input  wire [47:0] s_eth_dest_mac,
            input  wire [47:0] s_eth_src_mac,
            input  wire [15:0] s_eth_type,
            input  wire [63:0] s_eth_payload_axis_tdata,
            input  wire [7:0]  s_eth_payload_axis_tkeep,
            input  wire        s_eth_payload_axis_tvalid,
            output reg         s_eth_payload_axis_tready,
            input  wire        s_eth_payload_axis_tlast,
            input  wire        s_eth_payload_axis_tuser,
        
            // TX Ethernet output (unused in RX-only path)
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
        
            // TX IP input
            input  wire        s_ip_hdr_valid,
            output wire        s_ip_hdr_ready,
            input  wire [5:0]  s_ip_dscp,
            input  wire [1:0]  s_ip_ecn,
            input  wire [15:0] s_ip_length,
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
        
            // TX IP output
            output wire        m_ip_hdr_valid,
            input  wire        m_ip_hdr_ready,
            output wire [47:0] m_ip_eth_dest_mac,
            output wire [47:0] m_ip_eth_src_mac,
            output wire [15:0] m_ip_eth_type,
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
        
            // TX UDP input
            input  wire        s_udp_hdr_valid,
            output wire        s_udp_hdr_ready,
            input  wire [5:0]  s_udp_ip_dscp,
            input  wire [1:0]  s_udp_ip_ecn,
            input  wire [7:0]  s_udp_ip_ttl,
            input  wire [31:0] s_udp_ip_source_ip,
            input  wire [31:0] s_udp_ip_dest_ip,
            input  wire [15:0] s_udp_source_port,
            input  wire [15:0] s_udp_dest_port,
            input  wire [15:0] s_udp_length,
            input  wire [15:0] s_udp_checksum,
            input  wire [63:0] s_udp_payload_axis_tdata,
            input  wire [7:0]  s_udp_payload_axis_tkeep,
            input  wire        s_udp_payload_axis_tvalid,
            output wire        s_udp_payload_axis_tready,
            input  wire        s_udp_payload_axis_tlast,
            input  wire        s_udp_payload_axis_tuser,
        
            // RX UDP output
            output reg         m_udp_hdr_valid,
            input  wire        m_udp_hdr_ready,
            output reg  [47:0] m_udp_eth_dest_mac,
            output reg  [47:0] m_udp_eth_src_mac,
            output reg  [15:0] m_udp_eth_type,
            output reg  [3:0]  m_udp_ip_version,
            output reg  [3:0]  m_udp_ip_ihl,
            output reg  [5:0]  m_udp_ip_dscp,
            output reg  [1:0]  m_udp_ip_ecn,
            output reg  [15:0] m_udp_ip_length,
            output reg  [15:0] m_udp_ip_identification,
            output reg  [2:0]  m_udp_ip_flags,
            output reg  [12:0] m_udp_ip_fragment_offset,
            output reg  [7:0]  m_udp_ip_ttl,
            output reg  [7:0]  m_udp_ip_protocol,
            output reg  [15:0] m_udp_ip_header_checksum,
            output reg  [31:0] m_udp_ip_source_ip,
            output reg  [31:0] m_udp_ip_dest_ip,
            output reg  [15:0] m_udp_source_port,
            output reg  [15:0] m_udp_dest_port,
            output reg  [15:0] m_udp_length,
            output reg  [15:0] m_udp_checksum,
            output reg  [63:0] m_udp_payload_axis_tdata,
            output reg  [7:0]  m_udp_payload_axis_tkeep,
            output reg         m_udp_payload_axis_tvalid,
            input  wire        m_udp_payload_axis_tready,
            output reg         m_udp_payload_axis_tlast,
            output reg         m_udp_payload_axis_tuser,
        
            // Status
            output wire        ip_rx_busy,
            output wire        ip_tx_busy,
            output wire        udp_rx_busy,
            output wire        udp_tx_busy,
            output wire        ip_rx_error_header_early_termination,
            output wire        ip_rx_error_payload_early_termination,
            output wire        ip_rx_error_invalid_header,
            output wire        ip_rx_error_invalid_checksum,
            output wire        ip_tx_error_payload_early_termination,
            output wire        ip_tx_error_arp_failed,
            output wire        udp_rx_error_header_early_termination,
            output wire        udp_rx_error_payload_early_termination,
            output wire        udp_tx_error_payload_early_termination,
        
            // Config
            input  wire [47:0] local_mac,
            input  wire [31:0] local_ip,
            input  wire [31:0] gateway_ip,
            input  wire [31:0] subnet_mask,
            input  wire        clear_arp_cache
        );
        
            // Tie off TX outputs
            assign m_eth_hdr_valid = 1'b0;
            assign m_eth_dest_mac = '0;
            assign m_eth_src_mac = '0;
            assign m_eth_type = '0;
            assign m_eth_payload_axis_tdata = '0;
            assign m_eth_payload_axis_tkeep = '0;
            assign m_eth_payload_axis_tvalid = 1'b0;
            assign m_eth_payload_axis_tlast = 1'b0;
            assign m_eth_payload_axis_tuser = 1'b0;
            assign m_ip_hdr_valid = 1'b0;
            assign m_ip_eth_dest_mac = '0; assign m_ip_eth_src_mac = '0; assign m_ip_eth_type = '0;
            assign m_ip_version = '0; assign m_ip_ihl = '0; assign m_ip_dscp = '0; assign m_ip_ecn = '0;
            assign m_ip_length = '0; assign m_ip_identification = '0; assign m_ip_flags = '0;
            assign m_ip_fragment_offset = '0; assign m_ip_ttl = '0; assign m_ip_protocol = '0;
            assign m_ip_header_checksum = '0; assign m_ip_source_ip = '0; assign m_ip_dest_ip = '0;
            assign m_ip_payload_axis_tdata = '0; assign m_ip_payload_axis_tkeep = '0;
            assign m_ip_payload_axis_tvalid = 1'b0; assign m_ip_payload_axis_tlast = 1'b0;
            assign m_ip_payload_axis_tuser = 1'b0;
            assign s_ip_hdr_ready = 1'b1; assign s_ip_payload_axis_tready = 1'b1;
            assign s_udp_hdr_ready = 1'b1; assign s_udp_payload_axis_tready = 1'b1;
            assign ip_rx_busy = 1'b0; assign ip_tx_busy = 1'b0;
            assign udp_rx_busy = 1'b0; assign udp_tx_busy = 1'b0;
            assign ip_rx_error_header_early_termination = 1'b0;
            assign ip_rx_error_payload_early_termination = 1'b0;
            assign ip_rx_error_invalid_header = 1'b0;
            assign ip_rx_error_invalid_checksum = 1'b0;
            assign ip_tx_error_payload_early_termination = 1'b0;
            assign ip_tx_error_arp_failed = 1'b0;
            assign udp_rx_error_header_early_termination = 1'b0;
            assign udp_rx_error_payload_early_termination = 1'b0;
            assign udp_tx_error_payload_early_termination = 1'b0;
        
            // ---------------------------------------------------------------
            // RX path: strip 20-byte IP header + 8-byte UDP header = 28 bytes
            // from Ethernet payload, output UDP payload.
            // ---------------------------------------------------------------
            // IP+UDP = 28 bytes = 3 full beats + 4 bytes
            // Beat 0: IP[0:7]    Beat 1: IP[8:15]    Beat 2: IP[16:19]+UDP[0:3]
            // Beat 3: UDP[4:7] + first 4 bytes of UDP payload
            // After beat 3, remaining beats are all UDP payload
            // Need 4-byte realignment from beat 3 onward
        
            typedef enum logic [2:0] {
                RX_IDLE   = 3'd0,
                RX_HDR    = 3'd1,  // consume IP+UDP header beats 0-2
                RX_TRANS  = 3'd2,  // transition beat (beat 3: UDP[4:7] + payload[0:3])
                RX_DATA   = 3'd3,  // forward realigned payload
                RX_FLUSH  = 3'd4,  // flush staged bytes
                RX_DROP   = 3'd5   // drop bad frames
            } rx_state_t;
        
            rx_state_t rx_state;
            reg [2:0]  hdr_beat_cnt;
            reg        eth_hdr_latched;
            reg [47:0] lat_dest_mac, lat_src_mac;
            reg [15:0] lat_eth_type;
        
            // IP header field capture
            reg [31:0] ip_src, ip_dst;
            reg [15:0] ip_len;
            // UDP header field capture
            reg [15:0] udp_src_port, udp_dst_port, udp_len, udp_cksum;
        
            // Staging for 4-byte realignment
            reg [31:0] stage4;
            reg [3:0]  stage4_keep;
            reg        stage4_valid;
            reg        stage4_last;
        
 016649     always_ff @(posedge clk) begin
 016632         if (rst) begin
 000017             rx_state <= RX_IDLE;
 000017             s_eth_hdr_ready <= 1'b0;
 000017             s_eth_payload_axis_tready <= 1'b0;
 000017             m_udp_hdr_valid <= 1'b0;
 000017             m_udp_payload_axis_tvalid <= 1'b0;
 000017             m_udp_payload_axis_tlast <= 1'b0;
 000017             m_udp_payload_axis_tuser <= 1'b0;
 000017             eth_hdr_latched <= 1'b0;
 000017             hdr_beat_cnt <= '0;
 000017             stage4_valid <= 1'b0;
 000017             stage4_last <= 1'b0;
 000017             ip_src <= '0; ip_dst <= '0; ip_len <= '0;
 000017             udp_src_port <= '0; udp_dst_port <= '0; udp_len <= '0; udp_cksum <= '0;
 000017             stage4 <= '0; stage4_keep <= '0;
 000017             lat_dest_mac <= '0; lat_src_mac <= '0; lat_eth_type <= '0;
 000017             m_udp_payload_axis_tdata <= '0;
 000017             m_udp_payload_axis_tkeep <= '0;
 000017             m_udp_eth_dest_mac <= '0; m_udp_eth_src_mac <= '0; m_udp_eth_type <= '0;
 000017             m_udp_ip_version <= '0; m_udp_ip_ihl <= '0; m_udp_ip_dscp <= '0;
 000017             m_udp_ip_ecn <= '0; m_udp_ip_length <= '0; m_udp_ip_identification <= '0;
 000017             m_udp_ip_flags <= '0; m_udp_ip_fragment_offset <= '0; m_udp_ip_ttl <= '0;
 000017             m_udp_ip_protocol <= '0; m_udp_ip_header_checksum <= '0;
 000017             m_udp_ip_source_ip <= '0; m_udp_ip_dest_ip <= '0;
 000017             m_udp_source_port <= '0; m_udp_dest_port <= '0;
 000017             m_udp_length <= '0; m_udp_checksum <= '0;
 016632         end else begin
 016632             case (rx_state)
 014730                 RX_IDLE: begin
 014730                     s_eth_hdr_ready <= 1'b1;
 014730                     s_eth_payload_axis_tready <= 1'b0;
 014730                     m_udp_payload_axis_tvalid <= 1'b0;
 014730                     m_udp_payload_axis_tlast <= 1'b0;
 014730                     m_udp_hdr_valid <= 1'b0;
 014730                     stage4_valid <= 1'b0;
 014566                     if (s_eth_hdr_valid && s_eth_hdr_ready) begin
 000164                         lat_dest_mac <= s_eth_dest_mac;
 000164                         lat_src_mac  <= s_eth_src_mac;
 000164                         lat_eth_type <= s_eth_type;
 000164                         eth_hdr_latched <= 1'b1;
 000164                         s_eth_hdr_ready <= 1'b0;
 000164                         s_eth_payload_axis_tready <= 1'b1;
 000164                         hdr_beat_cnt <= '0;
 000164                         rx_state <= RX_HDR;
                            end
                        end
        
 000487                 RX_HDR: begin
                            // Consume IP+UDP header beats (28 bytes = beats 0-2 + partial beat 3)
~000487                     if (s_eth_payload_axis_tvalid && s_eth_payload_axis_tready) begin
 000487                         case (hdr_beat_cnt)
 000164                             3'd0: begin
                                        // IP bytes 0-7: version/IHL/DSCP/ECN/length/id
 000164                                 ip_len <= {s_eth_payload_axis_tdata[23:16],
 000164                                            s_eth_payload_axis_tdata[31:24]};
                                    end
 000162                             3'd1: begin
                                        // IP bytes 8-15: flags/frag/TTL/protocol/checksum
                                        // nothing critical to capture for stub
                                    end
 000161                             3'd2: begin
                                        // IP bytes 16-19 (src IP) + UDP bytes 0-3 (src/dst port)
 000161                                 ip_src <= {s_eth_payload_axis_tdata[7:0],
 000161                                            s_eth_payload_axis_tdata[15:8],
 000161                                            s_eth_payload_axis_tdata[23:16],
 000161                                            s_eth_payload_axis_tdata[31:24]};
 000161                                 udp_src_port <= {s_eth_payload_axis_tdata[39:32],
 000161                                                  s_eth_payload_axis_tdata[47:40]};
 000161                                 udp_dst_port <= {s_eth_payload_axis_tdata[55:48],
 000161                                                  s_eth_payload_axis_tdata[63:56]};
                                    end
                                endcase
        
%000003                         if (s_eth_payload_axis_tlast) begin
%000003                             rx_state <= RX_IDLE;
 000323                         end else if (hdr_beat_cnt == 3'd2) begin
 000161                             rx_state <= RX_TRANS;
 000323                         end else begin
 000323                             hdr_beat_cnt <= hdr_beat_cnt + 3'd1;
                                end
                            end
                        end
        
 000161                 RX_TRANS: begin
                            // Beat 3: UDP bytes 4-7 at [31:0] + first 4 payload bytes at [63:32]
~000161                     if (s_eth_payload_axis_tvalid && s_eth_payload_axis_tready) begin
 000161                         udp_len   <= {s_eth_payload_axis_tdata[7:0],
 000161                                       s_eth_payload_axis_tdata[15:8]};
 000161                         udp_cksum <= {s_eth_payload_axis_tdata[23:16],
 000161                                       s_eth_payload_axis_tdata[31:24]};
        
                                // Emit UDP header sideband
 000161                         m_udp_hdr_valid <= 1'b1;
 000161                         m_udp_eth_dest_mac <= lat_dest_mac;
 000161                         m_udp_eth_src_mac  <= lat_src_mac;
 000161                         m_udp_eth_type     <= lat_eth_type;
 000161                         m_udp_ip_source_ip <= ip_src;
 000161                         m_udp_source_port  <= udp_src_port;
 000161                         m_udp_dest_port    <= udp_dst_port;
 000161                         m_udp_length       <= {s_eth_payload_axis_tdata[7:0],
 000161                                                s_eth_payload_axis_tdata[15:8]};
 000161                         m_udp_checksum     <= {s_eth_payload_axis_tdata[23:16],
 000161                                                s_eth_payload_axis_tdata[31:24]};
        
                                // Stage upper 4 bytes (first UDP payload bytes)
 000161                         stage4      <= s_eth_payload_axis_tdata[63:32];
 000161                         stage4_keep <= s_eth_payload_axis_tkeep[7:4];
 000161                         stage4_valid <= (s_eth_payload_axis_tkeep[7:4] != 4'b0);
        
~000160                         if (s_eth_payload_axis_tlast) begin
%000001                             stage4_last <= 1'b1;
%000001                             rx_state <= RX_FLUSH;
%000001                             s_eth_payload_axis_tready <= 1'b0;
 000160                         end else begin
 000160                             stage4_last <= 1'b0;
 000160                             rx_state <= RX_DATA;
                                end
                            end
                        end
        
 001099                 RX_DATA: begin
 000939                     if (m_udp_hdr_valid && m_udp_hdr_ready)
 000160                         m_udp_hdr_valid <= 1'b0;
        
                            // Output ready gating
 000939                     if (m_udp_payload_axis_tvalid && m_udp_payload_axis_tready)
 000939                         m_udp_payload_axis_tvalid <= 1'b0;
        
 001099                     s_eth_payload_axis_tready <= !m_udp_payload_axis_tvalid || m_udp_payload_axis_tready;
        
~001099                     if (s_eth_payload_axis_tvalid && s_eth_payload_axis_tready) begin
                                // Realign with 4-byte offset
 001099                         m_udp_payload_axis_tdata  <= {s_eth_payload_axis_tdata[31:0], stage4};
 001099                         m_udp_payload_axis_tkeep  <= {s_eth_payload_axis_tkeep[3:0], stage4_keep};
 001099                         m_udp_payload_axis_tvalid <= 1'b1;
 001099                         m_udp_payload_axis_tuser  <= 1'b0;
        
 001099                         stage4      <= s_eth_payload_axis_tdata[63:32];
 001099                         stage4_keep <= s_eth_payload_axis_tkeep[7:4];
        
 000939                         if (s_eth_payload_axis_tlast) begin
~000154                             if (s_eth_payload_axis_tkeep[7:4] != 4'b0) begin
 000154                                 m_udp_payload_axis_tlast <= 1'b0;
 000154                                 stage4_last <= 1'b1;
 000154                                 rx_state <= RX_FLUSH;
 000154                                 s_eth_payload_axis_tready <= 1'b0;
%000006                             end else begin
%000006                                 m_udp_payload_axis_tlast <= 1'b1;
%000006                                 rx_state <= RX_IDLE;
                                    end
 000939                         end else begin
 000939                             m_udp_payload_axis_tlast <= 1'b0;
                                end
                            end
                        end
        
 000155                 RX_FLUSH: begin
~000154                     if (m_udp_hdr_valid && m_udp_hdr_ready)
%000001                         m_udp_hdr_valid <= 1'b0;
        
~000155                     if (!m_udp_payload_axis_tvalid || m_udp_payload_axis_tready) begin
 000155                         m_udp_payload_axis_tdata  <= {32'b0, stage4};
 000155                         m_udp_payload_axis_tkeep  <= {4'b0, stage4_keep};
 000155                         m_udp_payload_axis_tvalid <= stage4_valid;
 000155                         m_udp_payload_axis_tlast  <= 1'b1;
 000155                         stage4_valid <= 1'b0;
 000155                         rx_state <= RX_IDLE;
                            end
                        end
        
%000000                 RX_DROP: begin
%000000                     s_eth_payload_axis_tready <= 1'b1;
%000000                     if (s_eth_payload_axis_tvalid && s_eth_payload_axis_tlast)
%000000                         rx_state <= RX_IDLE;
                        end
        
                        /* verilator coverage_off */
                        default: rx_state <= RX_IDLE;
                        /* verilator coverage_on */
                    endcase
                end
            end
        
        endmodule
        
        /* verilator lint_on UNUSEDSIGNAL */
        /* verilator lint_on UNDRIVEN */
        
