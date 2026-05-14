//      // verilator_coverage annotation
        // tb_top.sv — UVM testbench top for kc705_top HFT SoC
        //
        // Drives two clock domains (clk_156 @ 156.25 MHz, clk_300 @ 300 MHz),
        // active-high cpu_reset, Ethernet AXIS stimulus, AXI4-Lite configuration,
        // and monitors OUCH AXIS output.
        
        /* verilator lint_off IMPORTSTAR */
        /* verilator lint_off WIDTHEXPAND */
        /* verilator lint_off WIDTHTRUNC */
        /* verilator lint_off UNUSEDSIGNAL */
        /* verilator lint_off UNDRIVEN */
        /* verilator lint_off PINMISSING */
        /* verilator lint_off CASEINCOMPLETE */
        /* verilator lint_off UNSIGNED */
        /* verilator lint_off BLKSEQ */
        /* verilator lint_off MULTIDRIVEN */
        
        import lliu_pkg::*;
        
        module tb_top;
        
            // ================================================================
            // Clock generation
            // ================================================================
%000001     reg clk_156 = 0;
%000001     reg clk_300 = 0;
        
            // 156.25 MHz -> 6.4ns period -> 3.2ns half
 033297     always #3200ps clk_156 = ~clk_156;
            // 300 MHz -> 3.333ns period -> 1.667ns half
 063919     always #1667ps clk_300 = ~clk_300;
        
            // ================================================================
            // Reset
            // ================================================================
%000001     reg cpu_reset = 1;
        
            // ================================================================
            // DUT signals
            // ================================================================
            // MAC RX AXIS (driven by testbench)
            reg  [63:0] mac_rx_tdata;
            reg  [7:0]  mac_rx_tkeep;
            reg         mac_rx_tvalid;
            reg         mac_rx_tlast;
            wire        mac_rx_tready;
        
            // AXI4-Lite
            reg  [11:0] axil_awaddr;
            reg         axil_awvalid;
            wire        axil_awready;
            reg  [31:0] axil_wdata;
            reg  [3:0]  axil_wstrb;
            reg         axil_wvalid;
            wire        axil_wready;
            wire [1:0]  axil_bresp;
            wire        axil_bvalid;
            reg         axil_bready;
            reg  [11:0] axil_araddr;
            reg         axil_arvalid;
            wire        axil_arready;
            wire [31:0] axil_rdata;
            wire [1:0]  axil_rresp;
            wire        axil_rvalid;
            reg         axil_rready;
        
            // OUCH output AXIS
            wire [63:0] m_axis_tdata;
            wire [7:0]  m_axis_tkeep;
            wire        m_axis_tvalid;
            wire        m_axis_tlast;
            reg         m_axis_tready;
        
            // Monitoring
            wire [31:0] collision_count_out;
            wire        tx_overflow_out;
            wire [31:0] dropped_frames_out;
            wire [31:0] dropped_datagrams_out;
            wire [63:0] expected_seq_num_out;
            wire        fifo_rd_tvalid;
        
            // PCIe (unused, tie off)
            wire [3:0] pcie_txp, pcie_txn;
        
            // ================================================================
            // DUT instantiation
            // ================================================================
            kc705_top #(
                .AXIL_ADDR(12),
                .AXIL_DATA(32)
            ) u_dut (
                .sys_clk_p        (1'b0),
                .sys_clk_n        (1'b1),
                .cpu_reset        (cpu_reset),
                .sfp_rx_p         (1'b0),
                .sfp_rx_n         (1'b1),
                .sfp_tx_p         (),
                .sfp_tx_n         (),
                .mgt_refclk_p     (1'b0),
                .mgt_refclk_n     (1'b1),
                .axil_awaddr      (axil_awaddr),
                .axil_awvalid     (axil_awvalid),
                .axil_awready     (axil_awready),
                .axil_wdata       (axil_wdata),
                .axil_wstrb       (axil_wstrb),
                .axil_wvalid      (axil_wvalid),
                .axil_wready      (axil_wready),
                .axil_bresp       (axil_bresp),
                .axil_bvalid      (axil_bvalid),
                .axil_bready      (axil_bready),
                .axil_araddr      (axil_araddr),
                .axil_arvalid     (axil_arvalid),
                .axil_arready     (axil_arready),
                .axil_rdata       (axil_rdata),
                .axil_rresp       (axil_rresp),
                .axil_rvalid      (axil_rvalid),
                .axil_rready      (axil_rready),
                .pcie_clk_p       (1'b0),
                .pcie_clk_n       (1'b1),
                .pcie_rst_n       (1'b1),
                .pcie_rxp         (4'b0),
                .pcie_rxn         (4'b1111),
                .pcie_txp         (pcie_txp),
                .pcie_txn         (pcie_txn),
                .m_axis_tdata     (m_axis_tdata),
                .m_axis_tkeep     (m_axis_tkeep),
                .m_axis_tvalid    (m_axis_tvalid),
                .m_axis_tlast     (m_axis_tlast),
                .m_axis_tready    (m_axis_tready),
                .collision_count_out   (collision_count_out),
                .tx_overflow_out       (tx_overflow_out),
                .dropped_frames_out    (dropped_frames_out),
                .dropped_datagrams_out (dropped_datagrams_out),
                .expected_seq_num_out  (expected_seq_num_out),
                .clk_156_in       (clk_156),
                .clk_300_in       (clk_300),
                .mac_rx_tdata     (mac_rx_tdata),
                .mac_rx_tkeep     (mac_rx_tkeep),
                .mac_rx_tvalid    (mac_rx_tvalid),
                .mac_rx_tlast     (mac_rx_tlast),
                .mac_rx_tready    (mac_rx_tready),
                .fifo_rd_tvalid   (fifo_rd_tvalid)
            );
        
            // ================================================================
            // Scoreboard / result tracking
            // ================================================================
%000001     int ouch_pkt_count = 0;
%000001     int ouch_beat_count = 0;
%000001     int tests_run = 0;
%000001     int tests_passed = 0;
%000001     int tests_failed = 0;
%000001     int bbo_update_count = 0;
%000001     int total_itch_msgs = 0;
%000001     longint unsigned next_seq = 1; // MoldUDP64 sequence number tracker
        
            // Monitor OUCH output
 031960     always @(posedge clk_300) begin
 031882         if (!cpu_reset && m_axis_tvalid && m_axis_tready) begin
 000078             ouch_beat_count++;
 000065             if (m_axis_tlast) begin
 000013                 ouch_pkt_count++;
 000013                 $display("[%0t] OUCH packet #%0d completed (%0d beats total)",
 000013                          $time, ouch_pkt_count, ouch_beat_count);
                    end
                end
            end
        
            // ================================================================
            // Helper tasks
            // ================================================================
        
            // AXI4-Lite write (clk_300 domain)
 001002     task automatic axil_write(input [11:0] addr, input [31:0] data);
 001002         @(posedge clk_300);
 001002         axil_awaddr  <= addr;
 001002         axil_awvalid <= 1'b1;
 001002         axil_wdata   <= data;
 001002         axil_wstrb   <= 4'hF;
 001002         axil_wvalid  <= 1'b1;
 001002         axil_bready  <= 1'b1;
        
 001002         @(posedge clk_300);
 001002         axil_awvalid <= 1'b0;
 001002         axil_wvalid  <= 1'b0;
        
 004008         repeat (4) @(posedge clk_300);
 001002         axil_bready <= 1'b0;
            endtask
        
            // AXI4-Lite read
 000047     task automatic axil_read(input [11:0] addr, output [31:0] data);
 000047         @(posedge clk_300);
 000047         axil_araddr  <= addr;
 000047         axil_arvalid <= 1'b1;
 000047         axil_rready  <= 1'b1;
        
 000047         @(posedge clk_300);
 000047         axil_arvalid <= 1'b0;
        
 000141         repeat (3) @(posedge clk_300);
 000047         data = axil_rdata;
 000047         axil_rready <= 1'b0;
 000047         @(posedge clk_300);
            endtask
        
            // Configure symbol filter entry
%000006     task automatic configure_symbol(input [6:0] idx, input [63:0] ticker, input enable);
%000006         axil_write(12'h038, {30'b0, idx[6:5]});
%000006         axil_write(12'h014, {24'b0, idx[4:0], 3'b0});
%000006         axil_write(12'h018, ticker[31:0]);
%000006         axil_write(12'h01C, ticker[63:32]);
%000006         axil_write(12'h020, {30'b0, enable ? 1'b1 : 1'b0, 1'b1});
            endtask
        
            // Load weight for a specific core
 000928     task automatic load_weight(input [2:0] core_id, input [4:0] addr, input [15:0] bf16_val);
 000928         logic [11:0] waddr;
 000928         waddr = {2'b10, core_id, addr, 2'b00};
 000928         axil_write(waddr, {16'b0, bf16_val});
            endtask
        
            // Build Ethernet frame containing MoldUDP64 + ITCH messages
            // Returns frame as byte array and length
            // Frame structure: Eth(14) + IP(20) + UDP(8) + MoldUDP64(20) + ITCH data
 000157     task automatic build_frame(
                input [63:0] mold_seq_num,
                input [15:0] mold_msg_count,
                input byte unsigned itch_payload[],
 000157         output byte unsigned frame[],
 000157         output int frame_len
            );
 000157         int payload_len;
 000157         int udp_len_val;
 000157         int ip_len_val;
 000157         int i;
        
 000157         payload_len = itch_payload.size();
 000157         udp_len_val = 8 + 20 + payload_len; // UDP hdr + MoldUDP64 hdr + ITCH
 000157         ip_len_val  = 20 + udp_len_val;      // IP hdr + UDP
 000157         frame_len   = 14 + ip_len_val;        // Eth hdr + IP
        
 000157         frame = new[frame_len];
        
                // Ethernet header (14 bytes)
                // Dest MAC: 02:00:00:00:00:01 (matching local_mac in DUT)
 000157         frame[0] = 8'h02; frame[1] = 8'h00; frame[2] = 8'h00;
 000157         frame[3] = 8'h00; frame[4] = 8'h00; frame[5] = 8'h01;
                // Src MAC
 000157         frame[6] = 8'hAA; frame[7] = 8'hBB; frame[8] = 8'hCC;
 000157         frame[9] = 8'hDD; frame[10] = 8'hEE; frame[11] = 8'hFF;
                // EtherType: IPv4
 000157         frame[12] = 8'h08; frame[13] = 8'h00;
        
                // IPv4 header (20 bytes, offset 14)
 000157         frame[14] = 8'h45; // Version=4, IHL=5
 000157         frame[15] = 8'h00; // DSCP/ECN
 000157         frame[16] = ip_len_val[15:8]; frame[17] = ip_len_val[7:0]; // Total length
 000157         frame[18] = 8'h00; frame[19] = 8'h01; // ID
 000157         frame[20] = 8'h00; frame[21] = 8'h00; // Flags/Fragment
 000157         frame[22] = 8'h40; // TTL=64
 000157         frame[23] = 8'h11; // Protocol=UDP
 000157         frame[24] = 8'h00; frame[25] = 8'h00; // Checksum (not checked by stub)
                // Source IP: 10.0.0.1
 000157         frame[26] = 8'h0A; frame[27] = 8'h00; frame[28] = 8'h00; frame[29] = 8'h01;
                // Dest IP: 233.54.12.0
 000157         frame[30] = 8'hE9; frame[31] = 8'h36; frame[32] = 8'h0C; frame[33] = 8'h00;
        
                // UDP header (8 bytes, offset 34)
 000157         frame[34] = 8'h04; frame[35] = 8'h00; // Source port
 000157         frame[36] = 8'h67; frame[37] = 8'h6D; // Dest port (26477)
 000157         frame[38] = udp_len_val[15:8]; frame[39] = udp_len_val[7:0]; // Length
 000157         frame[40] = 8'h00; frame[41] = 8'h00; // Checksum
        
                // MoldUDP64 header (20 bytes, offset 42)
                // Session ID (10 bytes)
 001570         for (i = 0; i < 10; i++) frame[42+i] = 8'h41 + i;
                // Sequence number (8 bytes, big-endian)
 000157         frame[52] = mold_seq_num[63:56]; frame[53] = mold_seq_num[55:48];
 000157         frame[54] = mold_seq_num[47:40]; frame[55] = mold_seq_num[39:32];
 000157         frame[56] = mold_seq_num[31:24]; frame[57] = mold_seq_num[23:16];
 000157         frame[58] = mold_seq_num[15:8];  frame[59] = mold_seq_num[7:0];
                // Message count (2 bytes)
 000157         frame[60] = mold_msg_count[15:8]; frame[61] = mold_msg_count[7:0];
        
                // ITCH payload
 005901         for (i = 0; i < payload_len; i++)
 005901             frame[62+i] = itch_payload[i];
            endtask
        
            // Build ITCH Add Order message body (36 bytes) with 2-byte length prefix
 000138     task automatic build_itch_add_order(
                input [63:0] order_ref_val,
                input        buy_side,
                input [31:0] shares_val,
                input [63:0] stock_val,
                input [31:0] price_val,
 000138         output byte unsigned msg[]
            );
 000138         int i;
 000138         msg = new[38]; // 2-byte length prefix + 36-byte body
        
                // Length prefix (big-endian)
 000138         msg[0] = 8'h00; msg[1] = 8'h24; // 36 bytes
        
                // Body byte 0: message type 'A'
 000138         msg[2] = 8'h41;
                // Bytes 1-2: stock_locate (0)
 000138         msg[3] = 8'h00; msg[4] = 8'h00;
                // Bytes 3-4: tracking_number (0)
 000138         msg[5] = 8'h00; msg[6] = 8'h00;
                // Bytes 5-10: timestamp (6 bytes)
 000828         for (i = 0; i < 6; i++) msg[7+i] = 8'h00;
                // Bytes 11-18: order_ref (8 bytes, big-endian)
 000138         msg[13] = order_ref_val[63:56]; msg[14] = order_ref_val[55:48];
 000138         msg[15] = order_ref_val[47:40]; msg[16] = order_ref_val[39:32];
 000138         msg[17] = order_ref_val[31:24]; msg[18] = order_ref_val[23:16];
 000138         msg[19] = order_ref_val[15:8];  msg[20] = order_ref_val[7:0];
                // Byte 19: side ('B'=0x42 or 'S'=0x53)
 000138         msg[21] = buy_side ? 8'h42 : 8'h53;
                // Bytes 20-23: shares (4 bytes, big-endian)
 000138         msg[22] = shares_val[31:24]; msg[23] = shares_val[23:16];
 000138         msg[24] = shares_val[15:8];  msg[25] = shares_val[7:0];
                // Bytes 24-31: stock (8 bytes ASCII)
 000138         msg[26] = stock_val[63:56]; msg[27] = stock_val[55:48];
 000138         msg[28] = stock_val[47:40]; msg[29] = stock_val[39:32];
 000138         msg[30] = stock_val[31:24]; msg[31] = stock_val[23:16];
 000138         msg[32] = stock_val[15:8];  msg[33] = stock_val[7:0];
                // Bytes 32-35: price (4 bytes, big-endian)
 000138         msg[34] = price_val[31:24]; msg[35] = price_val[23:16];
 000138         msg[36] = price_val[15:8];  msg[37] = price_val[7:0];
            endtask
        
            // Build ITCH Execute Order message (30 bytes body)
%000005     task automatic build_itch_execute(
                input [63:0] order_ref_val,
                input [31:0] shares_val,
%000005         output byte unsigned msg[]
            );
%000005         int i;
%000005         msg = new[40]; // 2-byte length + 30-byte body + 8 padding (parser > vs >= workaround)
%000005         msg[0] = 8'h00; msg[1] = 8'h1E; // 30 bytes
%000005         msg[2] = 8'h45; // 'E'
%000005         msg[3] = 8'h00; msg[4] = 8'h00; // stock_locate
%000005         msg[5] = 8'h00; msg[6] = 8'h00; // tracking
~000030         for (i = 0; i < 6; i++) msg[7+i] = 8'h00; // timestamp
                // order_ref
%000005         msg[13] = order_ref_val[63:56]; msg[14] = order_ref_val[55:48];
%000005         msg[15] = order_ref_val[47:40]; msg[16] = order_ref_val[39:32];
%000005         msg[17] = order_ref_val[31:24]; msg[18] = order_ref_val[23:16];
%000005         msg[19] = order_ref_val[15:8];  msg[20] = order_ref_val[7:0];
                // shares (bytes 19-22 for E type)
%000005         msg[21] = shares_val[31:24]; msg[22] = shares_val[23:16];
%000005         msg[23] = shares_val[15:8];  msg[24] = shares_val[7:0];
                // match_number (bytes 23-30)
~000035         for (i = 25; i < 32; i++) msg[i] = 8'h00;
            endtask
        
            // Build ITCH Cancel Order message (23 bytes body)
%000003     task automatic build_itch_cancel(
                input [63:0] order_ref_val,
                input [31:0] shares_val,
%000003         output byte unsigned msg[]
            );
%000003         int i;
%000003         msg = new[33]; // 2-byte length + 23-byte body + 8 padding (parser > vs >= workaround)
%000003         msg[0] = 8'h00; msg[1] = 8'h17; // 23 bytes
%000003         msg[2] = 8'h58; // 'X'
%000003         msg[3] = 8'h00; msg[4] = 8'h00;
%000003         msg[5] = 8'h00; msg[6] = 8'h00;
~000018         for (i = 0; i < 6; i++) msg[7+i] = 8'h00;
%000003         msg[13] = order_ref_val[63:56]; msg[14] = order_ref_val[55:48];
%000003         msg[15] = order_ref_val[47:40]; msg[16] = order_ref_val[39:32];
%000003         msg[17] = order_ref_val[31:24]; msg[18] = order_ref_val[23:16];
%000003         msg[19] = order_ref_val[15:8];  msg[20] = order_ref_val[7:0];
%000003         msg[21] = shares_val[31:24]; msg[22] = shares_val[23:16];
%000003         msg[23] = shares_val[15:8];  msg[24] = shares_val[7:0];
            endtask
        
            // Build ITCH Delete Order message (19 bytes body)
%000005     task automatic build_itch_delete(
                input [63:0] order_ref_val,
%000005         output byte unsigned msg[]
            );
%000005         int i;
%000005         msg = new[21]; // 2-byte length + 19-byte body
%000005         msg[0] = 8'h00; msg[1] = 8'h13; // 19 bytes
%000005         msg[2] = 8'h44; // 'D'
%000005         msg[3] = 8'h00; msg[4] = 8'h00;
%000005         msg[5] = 8'h00; msg[6] = 8'h00;
~000030         for (i = 0; i < 6; i++) msg[7+i] = 8'h00;
%000005         msg[13] = order_ref_val[63:56]; msg[14] = order_ref_val[55:48];
%000005         msg[15] = order_ref_val[47:40]; msg[16] = order_ref_val[39:32];
%000005         msg[17] = order_ref_val[31:24]; msg[18] = order_ref_val[23:16];
%000005         msg[19] = order_ref_val[15:8];  msg[20] = order_ref_val[7:0];
            endtask
        
            // Build ITCH Replace Order message (35 bytes body)
%000003     task automatic build_itch_replace(
                input [63:0] order_ref_val,
                input [63:0] new_order_ref_val,
                input [31:0] shares_val,
                input [31:0] price_val,
%000003         output byte unsigned msg[]
            );
%000003         int i;
%000003         msg = new[37]; // 2-byte length + 35-byte body
%000003         msg[0] = 8'h00; msg[1] = 8'h23; // 35 bytes
%000003         msg[2] = 8'h55; // 'U'
%000003         msg[3] = 8'h00; msg[4] = 8'h00;
%000003         msg[5] = 8'h00; msg[6] = 8'h00;
~000018         for (i = 0; i < 6; i++) msg[7+i] = 8'h00;
                // order_ref
%000003         msg[13] = order_ref_val[63:56]; msg[14] = order_ref_val[55:48];
%000003         msg[15] = order_ref_val[47:40]; msg[16] = order_ref_val[39:32];
%000003         msg[17] = order_ref_val[31:24]; msg[18] = order_ref_val[23:16];
%000003         msg[19] = order_ref_val[15:8];  msg[20] = order_ref_val[7:0];
                // new_order_ref
%000003         msg[21] = new_order_ref_val[63:56]; msg[22] = new_order_ref_val[55:48];
%000003         msg[23] = new_order_ref_val[47:40]; msg[24] = new_order_ref_val[39:32];
%000003         msg[25] = new_order_ref_val[31:24]; msg[26] = new_order_ref_val[23:16];
%000003         msg[27] = new_order_ref_val[15:8];  msg[28] = new_order_ref_val[7:0];
                // shares (bytes 27-30)
%000003         msg[29] = shares_val[31:24]; msg[30] = shares_val[23:16];
%000003         msg[31] = shares_val[15:8];  msg[32] = shares_val[7:0];
                // price (bytes 31-34)
%000003         msg[33] = price_val[31:24]; msg[34] = price_val[23:16];
%000003         msg[35] = price_val[15:8];  msg[36] = price_val[7:0];
            endtask
        
            // Send frame on MAC RX AXIS (clk_156 domain, byte 0 at tdata[7:0])
 000164     task automatic send_frame(input byte unsigned frame[], input int frame_len);
 000164         int beat;
 000164         int num_beats;
 000164         int byte_idx;
 000164         int valid_bytes;
        
 000164         num_beats = (frame_len + 7) / 8;
        
 002069         for (beat = 0; beat < num_beats; beat++) begin
 002069             @(posedge clk_156);
 002069             mac_rx_tvalid <= 1'b1;
        
 002069             valid_bytes = (beat == num_beats - 1) ? (frame_len - beat * 8) : 8;
 002069             mac_rx_tkeep <= (8'hFF >> (8 - valid_bytes));
        
 002069             mac_rx_tdata <= '0;
 016552             for (int b = 0; b < 8; b++) begin
 016552                 byte_idx = beat * 8 + b;
 015922                 if (byte_idx < frame_len)
 015922                     mac_rx_tdata[b*8 +: 8] <= frame[byte_idx];
                    end
        
 002069             mac_rx_tlast <= (beat == num_beats - 1);
                end
        
 000164         @(posedge clk_156);
 000164         mac_rx_tvalid <= 1'b0;
 000164         mac_rx_tlast  <= 1'b0;
            endtask
        
            // Send ITCH message in a MoldUDP64 frame with auto-incrementing sequence
 000093     task automatic send_itch_msg(input byte unsigned itch_msg[]);
 000093         byte unsigned frame[];
 000093         int flen;
 000093         build_frame(next_seq, 16'd1, itch_msg, frame, flen);
 000093         send_frame(frame, flen);
 000093         next_seq++;
 000093         total_itch_msgs++;
            endtask
        
            // Send idle cycles on MAC RX
 000043     task automatic send_idle(input int cycles);
 000184         repeat (cycles) @(posedge clk_156);
            endtask
        
            // Wait for N clk_300 cycles
 000081     task automatic wait_clk300(input int n);
 021047         repeat (n) @(posedge clk_300);
            endtask
        
            // ================================================================
            // Test sequences
            // ================================================================
        
            // Concatenate ITCH messages into single payload
%000001     task automatic concat_msgs(
                input byte unsigned msgs[],
                input byte unsigned more_msgs[],
%000001         output byte unsigned result[]
            );
%000001         int total_len;
%000001         total_len = msgs.size() + more_msgs.size();
%000001         result = new[total_len];
~000038         for (int i = 0; i < msgs.size(); i++)
 000038             result[i] = msgs[i];
~000038         for (int i = 0; i < more_msgs.size(); i++)
 000038             result[msgs.size() + i] = more_msgs[i];
            endtask
        
            // ================================================================
            // Main test
            // ================================================================
%000001     initial begin
                // Initialize signals
%000001         mac_rx_tdata  = '0;
%000001         mac_rx_tkeep  = '0;
%000001         mac_rx_tvalid = 1'b0;
%000001         mac_rx_tlast  = 1'b0;
%000001         m_axis_tready = 1'b1;
%000001         axil_awaddr   = '0;
%000001         axil_awvalid  = 1'b0;
%000001         axil_wdata    = '0;
%000001         axil_wstrb    = '0;
%000001         axil_wvalid   = 1'b0;
%000001         axil_bready   = 1'b0;
%000001         axil_araddr   = '0;
%000001         axil_arvalid  = 1'b0;
%000001         axil_rready   = 1'b0;
        
%000001         $display("[%0t] === HFT SoC UVM Testbench Starting ===", $time);
%000001         $display("[%0t] Asserting reset...", $time);
        
                // Hold reset for 16+ cycles of both clocks
%000001         cpu_reset = 1;
~000032         repeat (32) @(posedge clk_300);
%000001         cpu_reset = 0;
%000001         $display("[%0t] Reset deasserted. Waiting 16 cycles...", $time);
~000032         repeat (32) @(posedge clk_300);
        
                // ==============================================================
                // Phase 1: Configure symbol filter and weights
                // ==============================================================
%000001         $display("[%0t] === Phase 1: Configuration ===", $time);
%000001         tests_run++;
        
                // Configure symbols
%000001         configure_symbol(7'd0, 64'h4141504C20202020, 1); // AAPL
%000001         configure_symbol(7'd1, 64'h4D53465420202020, 1); // MSFT
%000001         configure_symbol(7'd2, 64'h474F4F4720202020, 1); // GOOG
%000001         configure_symbol(7'd3, 64'h54534C4120202020, 1); // TSLA
%000001         configure_symbol(7'd4, 64'h4E56444120202020, 1); // NVDA
%000001         configure_symbol(7'd5, 64'h4D45544120202020, 1); // META
        
%000001         $display("[%0t] Symbol filter configured (6 symbols)", $time);
        
                // Load weights: cores 0-6 get 1.0, core 7 gets 2.0 for arbiter diversity
%000007         for (int core = 0; core < 7; core++)
~000224             for (int w = 0; w < 32; w++)
 000224                 load_weight(core[2:0], w[4:0], 16'h3F80); // 1.0
~000032         for (int w = 0; w < 32; w++)
 000032             load_weight(3'd7, w[4:0], 16'h4000); // 2.0
%000001         $display("[%0t] Weights loaded (cores 0-6=1.0, core 7=2.0)", $time);
        
%000001         axil_write(12'h408, 32'h0);     // score_thresh = 0
%000001         axil_write(12'h400, 32'd10000); // band_bps = 10000
%000001         axil_write(12'h404, 32'd10000); // max_qty = 10000
%000008         for (int c = 0; c < 8; c++)
%000008             axil_write(12'hC00 + c*4, 32'd100); // core shares
        
%000001         $display("[%0t] Risk parameters configured", $time);
%000001         tests_passed++;
        
                // ==============================================================
                // Phase 2: Basic Add Order test
                // ==============================================================
%000001         $display("[%0t] === Phase 2: Basic Add Orders ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
        
%000001             tests_run++;
        
                    // Send Add Order: BUY AAPL 100 shares @ $150.0000 (1500000 in ITCH)
%000001             build_itch_add_order(
%000001                 64'h0000000000000001,  // order_ref
%000001                 1'b1,                  // buy
%000001                 32'd100,               // shares
%000001                 64'h4141504C20202020,  // "AAPL    "
%000001                 32'd1500000,           // price
%000001                 itch_msg
                    );
        
%000001             build_frame(64'd1, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending AAPL BUY Add Order (seq=1)", $time);
%000001             send_frame(frame, flen);
%000001             total_itch_msgs++;
        
%000001             send_idle(10);
        
                    // Send Add Order: SELL AAPL 200 shares @ $151.0000
%000001             build_itch_add_order(
%000001                 64'h0000000000000002,
%000001                 1'b0,
%000001                 32'd200,
%000001                 64'h4141504C20202020,
%000001                 32'd1510000,
%000001                 itch_msg
                    );
%000001             build_frame(64'd2, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending AAPL SELL Add Order (seq=2)", $time);
%000001             send_frame(frame, flen);
%000001             total_itch_msgs++;
        
%000001             send_idle(5);
        
                    // Send Add Order: BUY MSFT 300 shares @ $300.0000
%000001             build_itch_add_order(
%000001                 64'h0000000000000003,
%000001                 1'b1,
%000001                 32'd300,
%000001                 64'h4D53465420202020,
%000001                 32'd3000000,
%000001                 itch_msg
                    );
%000001             build_frame(64'd3, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending MSFT BUY Add Order (seq=3)", $time);
%000001             send_frame(frame, flen);
%000001             total_itch_msgs++;
        
%000001             send_idle(5);
        
                    // Send Add Order: SELL MSFT 150 shares @ $301.0000
%000001             build_itch_add_order(
%000001                 64'h0000000000000004,
%000001                 1'b0,
%000001                 32'd150,
%000001                 64'h4D53465420202020,
%000001                 32'd3010000,
%000001                 itch_msg
                    );
%000001             build_frame(64'd4, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending MSFT SELL Add Order (seq=4)", $time);
%000001             send_frame(frame, flen);
%000001             total_itch_msgs++;
        
                    // Wait for inference pipeline to complete
%000001             wait_clk300(200);
%000001             $display("[%0t] OUCH packets after basic adds: %0d", $time, ouch_pkt_count);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 3: Execute, Cancel, Delete orders
                // ==============================================================
%000001         $display("[%0t] === Phase 3: Modify Orders ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
        
%000001             tests_run++;
        
                    // Execute 50 shares of order 1 (AAPL buy)
%000001             build_itch_execute(64'h0000000000000001, 32'd50, itch_msg);
%000001             build_frame(64'd5, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending Execute Order ref=1 (seq=5)", $time);
%000001             send_frame(frame, flen);
%000001             total_itch_msgs++;
%000001             send_idle(5);
        
                    // Cancel 100 shares of order 2 (AAPL sell)
%000001             build_itch_cancel(64'h0000000000000002, 32'd100, itch_msg);
%000001             build_frame(64'd6, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending Cancel Order ref=2 (seq=6)", $time);
%000001             send_frame(frame, flen);
%000001             total_itch_msgs++;
%000001             send_idle(5);
        
                    // Delete order 3 (MSFT buy)
%000001             build_itch_delete(64'h0000000000000003, itch_msg);
%000001             build_frame(64'd7, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending Delete Order ref=3 (seq=7)", $time);
%000001             send_frame(frame, flen);
%000001             total_itch_msgs++;
        
%000001             wait_clk300(200);
%000001             $display("[%0t] OUCH packets after modifies: %0d", $time, ouch_pkt_count);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 4: Replace order
                // ==============================================================
%000001         $display("[%0t] === Phase 4: Replace Order ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
        
%000001             tests_run++;
        
%000001             build_itch_replace(
%000001                 64'h0000000000000004,   // old order ref
%000001                 64'h0000000000000005,   // new order ref
%000001                 32'd250,                // new shares
%000001                 32'd3020000,            // new price
%000001                 itch_msg
                    );
%000001             build_frame(64'd8, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending Replace Order ref=4->5 (seq=8)", $time);
%000001             send_frame(frame, flen);
%000001             total_itch_msgs++;
        
%000001             wait_clk300(200);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 5: Multiple symbols, more orders
                // ==============================================================
%000001         $display("[%0t] === Phase 5: Multi-symbol stress ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
        
%000001             tests_run++;
        
                    // GOOG orders
%000001             build_itch_add_order(64'h0000000000000010, 1'b1, 32'd500,
%000001                 64'h474F4F4720202020, 32'd1400000, itch_msg);
%000001             build_frame(64'd9, 16'd1, itch_msg, frame, flen);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(3);
        
%000001             build_itch_add_order(64'h0000000000000011, 1'b0, 32'd400,
%000001                 64'h474F4F4720202020, 32'd1410000, itch_msg);
%000001             build_frame(64'd10, 16'd1, itch_msg, frame, flen);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(3);
        
                    // TSLA orders
%000001             build_itch_add_order(64'h0000000000000012, 1'b1, 32'd600,
%000001                 64'h54534C4120202020, 32'd2500000, itch_msg);
%000001             build_frame(64'd11, 16'd1, itch_msg, frame, flen);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(3);
        
%000001             build_itch_add_order(64'h0000000000000013, 1'b0, 32'd700,
%000001                 64'h54534C4120202020, 32'd2510000, itch_msg);
%000001             build_frame(64'd12, 16'd1, itch_msg, frame, flen);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(3);
        
                    // More AAPL orders to trigger inference
%000001             build_itch_add_order(64'h0000000000000014, 1'b1, 32'd800,
%000001                 64'h4141504C20202020, 32'd1490000, itch_msg);
%000001             build_frame(64'd13, 16'd1, itch_msg, frame, flen);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(3);
        
%000001             build_itch_add_order(64'h0000000000000015, 1'b0, 32'd900,
%000001                 64'h4141504C20202020, 32'd1520000, itch_msg);
%000001             build_frame(64'd14, 16'd1, itch_msg, frame, flen);
%000001             send_frame(frame, flen); total_itch_msgs++;
        
%000001             wait_clk300(500);
%000001             $display("[%0t] OUCH packets after multi-symbol: %0d", $time, ouch_pkt_count);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 6: Edge cases — max/min price, max quantity
                // ==============================================================
%000001         $display("[%0t] === Phase 6: Edge cases ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
        
%000001             tests_run++;
        
                    // Max price order
%000001             build_itch_add_order(64'h0000000000000020, 1'b1, 32'd100,
%000001                 64'h4141504C20202020, 32'hFFFFFFFF, itch_msg);
%000001             build_frame(64'd15, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending max-price order", $time);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(5);
        
                    // Min price (1) order
%000001             build_itch_add_order(64'h0000000000000021, 1'b0, 32'd100,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             build_frame(64'd16, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending min-price order", $time);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(5);
        
                    // Max quantity order (should be blocked by fat-finger check)
%000001             build_itch_add_order(64'h0000000000000022, 1'b1, 32'h00FFFFFF, // 16M shares
%000001                 64'h4141504C20202020, 32'd1500000, itch_msg);
%000001             build_frame(64'd17, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending max-quantity order", $time);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(5);
        
                    // Zero shares
%000001             build_itch_add_order(64'h0000000000000023, 1'b1, 32'd0,
%000001                 64'h4141504C20202020, 32'd1500000, itch_msg);
%000001             build_frame(64'd18, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending zero-shares order", $time);
%000001             send_frame(frame, flen); total_itch_msgs++;
        
%000001             wait_clk300(300);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 7: Sequence gap (should trigger MoldUDP64 drop)
                // ==============================================================
%000001         $display("[%0t] === Phase 7: MoldUDP64 sequence gap ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
        
%000001             tests_run++;
        
                    // Send seq=20 (gap from seq=18)
%000001             build_itch_add_order(64'h0000000000000030, 1'b1, 32'd100,
%000001                 64'h4141504C20202020, 32'd1500000, itch_msg);
%000001             build_frame(64'd20, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending out-of-order frame (seq=20, expected=19)", $time);
%000001             send_frame(frame, flen);
%000001             send_idle(10);
        
                    // Send correct seq=19
%000001             build_itch_add_order(64'h0000000000000031, 1'b1, 32'd100,
%000001                 64'h4141504C20202020, 32'd1500000, itch_msg);
%000001             build_frame(64'd19, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending in-order frame (seq=19)", $time);
%000001             send_frame(frame, flen); total_itch_msgs++;
        
%000001             wait_clk300(200);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 8: Back-pressure test
                // ==============================================================
%000001         $display("[%0t] === Phase 8: Back-pressure ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
        
%000001             tests_run++;
        
                    // De-assert m_axis_tready to create backpressure
%000001             m_axis_tready = 1'b0;
        
                    // Send more orders
%000001             build_itch_add_order(64'h0000000000000040, 1'b1, 32'd100,
%000001                 64'h4D53465420202020, 32'd3000000, itch_msg);
%000001             build_frame(64'd20, 16'd1, itch_msg, frame, flen);
%000001             send_frame(frame, flen); total_itch_msgs++;
%000001             send_idle(3);
        
%000001             build_itch_add_order(64'h0000000000000041, 1'b0, 32'd100,
%000001                 64'h4D53465420202020, 32'd3010000, itch_msg);
%000001             build_frame(64'd21, 16'd1, itch_msg, frame, flen);
%000001             send_frame(frame, flen); total_itch_msgs++;
        
                    // Wait a bit under backpressure
%000001             wait_clk300(100);
        
                    // Re-assert ready
%000001             m_axis_tready = 1'b1;
%000001             wait_clk300(300);
        
%000001             $display("[%0t] OUCH packets after backpressure: %0d", $time, ouch_pkt_count);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 9: Untracked symbol (should not produce OUCH output)
                // ==============================================================
%000001         $display("[%0t] === Phase 9: Untracked symbol ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
%000001             int ouch_before;
        
%000001             tests_run++;
%000001             ouch_before = ouch_pkt_count;
        
                    // "AMZN    " not in watchlist
%000001             build_itch_add_order(64'h0000000000000050, 1'b1, 32'd100,
%000001                 64'h414D5A4E20202020, 32'd3000000, itch_msg);
%000001             build_frame(64'd22, 16'd1, itch_msg, frame, flen);
%000001             $display("[%0t] Sending untracked symbol AMZN", $time);
%000001             send_frame(frame, flen); total_itch_msgs++;
        
%000001             wait_clk300(200);
        
%000001             if (ouch_pkt_count == ouch_before)
%000001                 $display("[%0t] PASS: No OUCH for untracked symbol", $time);
                    else
%000000                 $display("[%0t] INFO: OUCH generated for untracked symbol (may be from prior)", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 10: Heavy burst to stress pipeline
                // ==============================================================
%000001         $display("[%0t] === Phase 10: Burst stress test ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
        
%000001             tests_run++;
        
~000020             for (int i = 0; i < 20; i++) begin
 000020                 logic [63:0] oref;
 000020                 logic [63:0] ticker;
 000020                 logic buy;
 000020                 oref = 64'h100 + i;
 000020                 buy = (i % 2 == 0);
 000020                 case (i % 4)
%000005                     0: ticker = 64'h4141504C20202020; // AAPL
%000005                     1: ticker = 64'h4D53465420202020; // MSFT
%000005                     2: ticker = 64'h474F4F4720202020; // GOOG
%000005                     3: ticker = 64'h54534C4120202020; // TSLA
                        endcase
 000020                 build_itch_add_order(oref, buy, 32'd100 + i * 10,
 000020                     ticker, 32'd1000000 + i * 10000, itch_msg);
 000020                 build_frame(64'd23 + i, 16'd1, itch_msg, frame, flen);
 000020                 send_frame(frame, flen); total_itch_msgs++;
        
                        // Variable idle for coverage
%000007                 if (i % 3 == 0) send_idle(1);
~000011                 else if (i % 5 == 0) send_idle(10);
                    end
        
%000001             wait_clk300(1000);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 11: OUCH generation — exploit parser price bug
                // parser_price = (price_val & 0x00FFFFFF) << 8 due to off-by-1
                // bbo_ask=256 (from Phase 6 min-price sell), bbo_bid=0 (inverted cmp)
                // ref_price=128, so with band_bps=16383 → band_thresh=255
                // price_val=1 → parser_price=256 → price_diff=128 < 255 → PASSES
                // ==============================================================
%000001         $display("[%0t] === Phase 11: OUCH generation (targeted) ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             int ouch_before;
%000001             tests_run++;
%000001             ouch_before = ouch_pkt_count;
%000001             next_seq = 43;
        
%000001             axil_write(12'h400, 32'd16383);
%000001             wait_clk300(10);
        
%000001             build_itch_add_order(64'h0000000000000060, 1'b0, 32'd100,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg); // seq=43 AAPL SELL price_val=1
%000001             wait_clk300(300);
        
%000001             build_itch_add_order(64'h0000000000000061, 1'b1, 32'd50,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg); // seq=44 AAPL BUY price_val=1
%000001             wait_clk300(300);
        
%000001             build_itch_add_order(64'h0000000000000062, 1'b0, 32'd200,
%000001                 64'h4D53465420202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg); // seq=45 MSFT SELL price_val=1
%000001             wait_clk300(300);
        
%000001             build_itch_add_order(64'h0000000000000063, 1'b1, 32'd75,
%000001                 64'h4D53465420202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg); // seq=46 MSFT BUY price_val=1
%000001             wait_clk300(300);
        
%000001             build_itch_add_order(64'h0000000000000064, 1'b0, 32'd150,
%000001                 64'h4E56444120202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg); // seq=47 NVDA SELL price_val=1
%000001             wait_clk300(300);
        
%000001             build_itch_add_order(64'h0000000000000065, 1'b1, 32'd80,
%000001                 64'h4E56444120202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg); // seq=48 NVDA BUY price_val=1
%000001             wait_clk300(300);
        
%000001             build_itch_add_order(64'h00000000000000A0, 1'b1, 32'd60,
%000001                 64'h474F4F4720202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg); // seq=49 GOOG BUY price_val=1
%000001             wait_clk300(300);
        
%000001             build_itch_add_order(64'h00000000000000A1, 1'b0, 32'd90,
%000001                 64'h54534C4120202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg); // seq=50 TSLA SELL price_val=1
%000001             wait_clk300(300);
        
%000001             axil_write(12'h400, 32'd10000);
%000001             wait_clk300(10);
        
%000001             $display("[%0t] OUCH packets after targeted test: %0d (new: %0d)",
%000001                      $time, ouch_pkt_count, ouch_pkt_count - ouch_before);
%000001             if (ouch_pkt_count > ouch_before)
%000001                 $display("[%0t] PASS: OUCH generation working", $time);
                    else
%000000                 $display("[%0t] INFO: No new OUCH (risk check blocking)", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 12: Multi-message MoldUDP64 datagram
                // ==============================================================
%000001         $display("[%0t] === Phase 12: Multi-message datagram ===", $time);
%000001         begin
%000001             byte unsigned itch_msg1[], itch_msg2[], combined[];
%000001             byte unsigned frame[];
%000001             int flen;
%000001             tests_run++;
        
%000001             build_itch_add_order(64'h0000000000000070, 1'b1, 32'd100,
%000001                 64'h4E56444120202020, 32'd600000, itch_msg1);
%000001             build_itch_add_order(64'h0000000000000071, 1'b0, 32'd200,
%000001                 64'h4D45544120202020, 32'd700000, itch_msg2);
%000001             concat_msgs(itch_msg1, itch_msg2, combined);
%000001             build_frame(next_seq, 16'd2, combined, frame, flen);
%000001             send_frame(frame, flen);
%000001             next_seq += 1; total_itch_msgs += 2;
%000001             wait_clk300(300);
%000001             $display("[%0t] Multi-message datagram sent", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 13: More order book operations (Execute, Cancel, Delete)
                // ==============================================================
%000001         $display("[%0t] === Phase 13: Order book exerciser ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             tests_run++;
        
                    // Execute 25 shares of NVDA order (ref=0x60)
%000001             build_itch_execute(64'h0000000000000060, 32'd25, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
                    // Cancel 50 shares of NVDA order (ref=0x61)
%000001             build_itch_cancel(64'h0000000000000061, 32'd50, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
                    // Delete META order (ref=0x62)
%000001             build_itch_delete(64'h0000000000000062, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
                    // Replace NVDA order ref=0x64 with new ref=0x66
%000001             build_itch_replace(64'h0000000000000064, 64'h0000000000000066,
%000001                 32'd300, 32'd900000, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(200);
        
%000001             $display("[%0t] Order book operations complete", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 14: Fat-finger and position limit triggers
                // ==============================================================
%000001         $display("[%0t] === Phase 14: Risk blocking tests ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             int ouch_before;
%000001             tests_run++;
%000001             ouch_before = ouch_pkt_count;
        
                    // Fat-finger: shares (10001) > max_qty (10000)
%000001             build_itch_add_order(64'h0000000000000080, 1'b1, 32'd10001,
%000001                 64'h4E56444120202020, 32'd500000, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(500);
        
                    // Position limit: send many orders to accumulate position
~000012             for (int i = 0; i < 12; i++) begin
 000012                 build_itch_add_order(64'h0000000000000090 + i, 1'b1, 32'd100,
 000012                     64'h4E56444120202020, 32'd500000, itch_msg);
 000012                 send_itch_msg(itch_msg);
 000012                 send_idle(2);
                    end
%000001             wait_clk300(500);
        
%000001             $display("[%0t] Risk blocking tests done, OUCH delta: %0d",
%000001                      $time, ouch_pkt_count - ouch_before);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 15: More ITCH message types coverage
                // ==============================================================
%000001         $display("[%0t] === Phase 15: ITCH message types ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             int i;
%000001             tests_run++;
        
                    // Type 'F' — Add Order with MPID attribution (40 bytes body)
%000001             itch_msg = new[42]; // 2-byte length + 40-byte body
%000001             itch_msg[0] = 8'h00; itch_msg[1] = 8'h28; // 40 bytes
%000001             itch_msg[2] = 8'h46; // 'F'
%000001             itch_msg[3] = 8'h00; itch_msg[4] = 8'h00;
%000001             itch_msg[5] = 8'h00; itch_msg[6] = 8'h00;
%000006             for (i = 0; i < 6; i++) itch_msg[7+i] = 8'h00;
                    // order_ref
%000001             itch_msg[13] = 8'h00; itch_msg[14] = 8'h00;
%000001             itch_msg[15] = 8'h00; itch_msg[16] = 8'h00;
%000001             itch_msg[17] = 8'h00; itch_msg[18] = 8'h00;
%000001             itch_msg[19] = 8'h00; itch_msg[20] = 8'hA0;
%000001             itch_msg[21] = 8'h42; // 'B' buy
                    // shares
%000001             itch_msg[22] = 8'h00; itch_msg[23] = 8'h00;
%000001             itch_msg[24] = 8'h00; itch_msg[25] = 8'h64; // 100
                    // stock = "NVDA    "
%000001             itch_msg[26] = 8'h4E; itch_msg[27] = 8'h56;
%000001             itch_msg[28] = 8'h44; itch_msg[29] = 8'h41;
%000001             itch_msg[30] = 8'h20; itch_msg[31] = 8'h20;
%000001             itch_msg[32] = 8'h20; itch_msg[33] = 8'h20;
                    // price = 500000
%000001             itch_msg[34] = 8'h00; itch_msg[35] = 8'h07;
%000001             itch_msg[36] = 8'hA1; itch_msg[37] = 8'h20;
                    // MPID (4 bytes)
%000001             itch_msg[38] = 8'h4D; itch_msg[39] = 8'h4C;
%000001             itch_msg[40] = 8'h43; itch_msg[41] = 8'h4F;
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(200);
        
                    // Type 'P' — Trade (non-displayable, 44 bytes body)
%000001             itch_msg = new[46];
%000001             itch_msg[0] = 8'h00; itch_msg[1] = 8'h2C; // 44 bytes
%000001             itch_msg[2] = 8'h50; // 'P'
~000043             for (i = 3; i < 46; i++) itch_msg[i] = 8'h00;
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
                    // Short message (body len ≤ 6, triggers early emit)
%000001             itch_msg = new[8];
%000001             itch_msg[0] = 8'h00; itch_msg[1] = 8'h06; // 6 bytes
%000001             itch_msg[2] = 8'h53; // 'S' System Event
%000005             for (i = 3; i < 8; i++) itch_msg[i] = 8'h00;
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
%000001             $display("[%0t] ITCH message types covered (F, P, S)", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 16: OUCH backpressure and tx_overflow coverage
                // ==============================================================
%000001         $display("[%0t] === Phase 16: OUCH backpressure stress ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             tests_run++;
        
                    // Hold tready low while generating OUCH-triggering orders
%000001             m_axis_tready = 1'b0;
        
                    // Send orders that should produce OUCH (NVDA pairs)
%000001             build_itch_add_order(64'h00000000000000B0, 1'b0, 32'd100,
%000001                 64'h4E56444120202020, 32'd1000000, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
%000001             build_itch_add_order(64'h00000000000000B1, 1'b1, 32'd50,
%000001                 64'h4E56444120202020, 32'd500000, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(200);
        
                    // Release after some backpressure
%000001             m_axis_tready = 1'b1;
%000001             wait_clk300(500);
%000001             $display("[%0t] OUCH backpressure test done, pkts=%0d", $time, ouch_pkt_count);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 17: Comprehensive AXI4-Lite readback
                // ==============================================================
%000001         $display("[%0t] === Phase 17: AXI4-Lite readback ===", $time);
%000001         begin
%000001             logic [31:0] rdata;
%000001             tests_run++;
        
                    // Read collision count
%000001             axil_read(12'h048, rdata);
%000001             $display("[%0t] Collision count: %0d", $time, rdata);
                    // Read risk status
%000001             axil_read(12'h410, rdata);
%000001             $display("[%0t] Risk status: 0x%08h", $time, rdata);
                    // Read histogram overflow
%000001             axil_read(12'h580, rdata);
%000001             $display("[%0t] Histogram overflow: %0d", $time, rdata);
                    // Read band_bps
%000001             axil_read(12'h400, rdata);
%000001             $display("[%0t] band_bps readback: %0d", $time, rdata);
                    // Read max_qty
%000001             axil_read(12'h404, rdata);
%000001             $display("[%0t] max_qty readback: %0d", $time, rdata);
                    // Read score_thresh
%000001             axil_read(12'h408, rdata);
%000001             $display("[%0t] score_thresh readback: 0x%08h", $time, rdata);
                    // Read CAM data
%000001             axil_read(12'h018, rdata);
%000001             $display("[%0t] CAM data lo: 0x%08h", $time, rdata);
%000001             axil_read(12'h01C, rdata);
%000001             $display("[%0t] CAM data hi: 0x%08h", $time, rdata);
                    // Read histogram bins 0-7 (0x280 + bin*4, araddr[11:7]==5'b00101)
%000008             for (int b = 0; b < 8; b++) begin
%000008                 axil_read(12'h280 + b*4, rdata);
                    end
                    // Read default case (unknown address)
%000001             axil_read(12'h100, rdata);
                    // Read unknown address (default case)
%000001             axil_read(12'hFFC, rdata);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 18: PCIe DMA snapshot test
                // ==============================================================
%000001         $display("[%0t] === Phase 18: PCIe DMA snapshot ===", $time);
%000001         begin
%000001             tests_run++;
        
                    // Initialize PCIe RX interface
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = 64'h0;
%000001             u_dut.u_pcie_dma.ax_rx_tkeep  = 8'h0;
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tuser  = 22'h0;
        
                    // Send BAR0 write: CTRL register (dma_en=1) via RX TLP
                    // Beat 0: DW0+DW1 header (IDLE → HDR1)
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = 64'h6000_0001_0000_00FF;
%000001             @(posedge clk_300);
                    // Beat 1: addr in lower 32 bits (HDR1 → DATA)
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_0000}; // BAR0+0x000
%000001             @(posedge clk_300);
                    // Beat 2: write data (DATA → IDLE), last=1
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_0001}; // dma_en=1
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
        
                    // Send BAR0 write: DESC_HOST_LO (0x00C)
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = 64'h6000_0001_0000_00FF;
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_000C};
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'hDEAD_0000};
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
        
                    // Send BAR0 write: DESC_HOST_HI (0x010)
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = 64'h6000_0001_0000_00FF;
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_0010};
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_BEEF};
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
        
                    // Send BAR0 write: DESC_LEN (0x014) — arms descriptor
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = 64'h6000_0001_0000_00FF;
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_0014};
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_1F40}; // 8000 bytes
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
        
%000001             $display("[%0t] PCIe BAR0 configured, waiting for DMA trigger...", $time);
        
                    // Wait for periodic_tick (200 cycles in sim) + DMA execution
%000001             wait_clk300(2000);
        
%000001             $display("[%0t] DMA active: %b", $time, u_dut.u_pcie_dma.dma_active);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 19: FIFO almost-full test (back-to-back frames)
                // ==============================================================
%000001         $display("[%0t] === Phase 19: FIFO stress ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             tests_run++;
        
                    // Send many frames back-to-back to stress CDC FIFO
~000030             for (int i = 0; i < 30; i++) begin
 000030                 build_itch_add_order(64'h00000000000000C0 + i,
 000030                     (i % 2 == 0) ? 1'b1 : 1'b0, 32'd50 + i,
 000030                     (i % 3 == 0) ? 64'h4E56444120202020 :
                            (i % 3 == 1) ? 64'h4D45544120202020 :
                                           64'h4141504C20202020,
 000030                     32'd500000 + i * 1000, itch_msg);
 000030                 send_itch_msg(itch_msg);
                    end
%000001             wait_clk300(1000);
%000001             $display("[%0t] FIFO stress done, OUCH=%0d", $time, ouch_pkt_count);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 20: Histogram clear test
                // ==============================================================
%000001         $display("[%0t] === Phase 20: Histogram clear ===", $time);
%000001         begin
%000001             logic [31:0] rdata;
%000001             tests_run++;
                    // Issue histogram clear via 0x584
%000001             axil_write(12'h584, 32'h1);
%000001             wait_clk300(10);
                    // Read cleared histogram
%000001             axil_read(12'h580, rdata);
%000001             $display("[%0t] Histogram overflow after clear: %0d", $time, rdata);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 22: Order book BBO resets via modify operations
                // Target: Cancel/Execute/Delete/Replace BBO clear paths
                // ==============================================================
%000001         $display("[%0t] === Phase 22: Order book BBO resets ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             tests_run++;
        
                    // Add 4 SELL orders for AAPL at price_val=1 (parser_price=256)
                    // These will match current BBO ask (256 from Phase 6 min-price)
%000001             build_itch_add_order(64'h00000000000000E0, 1'b0, 32'd10,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
%000001             build_itch_add_order(64'h00000000000000E1, 1'b0, 32'd20,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
%000001             build_itch_add_order(64'h00000000000000E2, 1'b0, 32'd30,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
%000001             build_itch_add_order(64'h00000000000000E3, 1'b0, 32'd40,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
                    // Cancel E0 to zero shares → BBO ask reset (Cancel path)
%000001             build_itch_cancel(64'h00000000000000E0, 32'd10, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
                    // Execute E1 fully (20 shares) → BBO ask reset (Execute path)
%000001             build_itch_execute(64'h00000000000000E1, 32'd20, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
                    // Delete E2 → BBO ask reset (Delete path)
%000001             build_itch_delete(64'h00000000000000E2, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
                    // Replace E3 with new ref E4 → BBO ask clear + new set (Replace path)
%000001             build_itch_replace(64'h00000000000000E3, 64'h00000000000000E4,
%000001                 32'd50, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
                    // Add BUY orders and modify them (exercise bid-side paths even if BBO bug)
%000001             build_itch_add_order(64'h00000000000000E5, 1'b1, 32'd15,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
%000001             build_itch_execute(64'h00000000000000E5, 32'd15, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
%000001             build_itch_add_order(64'h00000000000000E6, 1'b1, 32'd25,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
%000001             build_itch_delete(64'h00000000000000E6, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(50);
        
%000001             $display("[%0t] Order book BBO reset tests done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 23: PCIe DMA TLP generation (force past RTL bug)
                // snap_done fires 1 cycle after snap_valid deasserts, missing
                // the capt_active_sys && snap_valid window — force state forward
                // ==============================================================
%000001         $display("[%0t] === Phase 23: PCIe DMA TLP generation ===", $time);
%000001         begin
%000001             tests_run++;
        
                    // DMA should already be in CAPT_WAIT from Phase 18
                    // Wait for snapshot to complete capturing (128 beats)
%000001             wait_clk300(300);
        
                    // Force DMA state past the snap_done timing bug
                    // DMA_DESCR = 3'b011
%000001             @(negedge clk_300);
%000001             force u_dut.u_pcie_dma.dma_state = u_dut.u_pcie_dma.DMA_DESCR;
%000001             @(posedge clk_300);
%000001             release u_dut.u_pcie_dma.dma_state;
%000001             @(posedge clk_300);
                    // DMA_DESCR_LAT = 3'b100 (wait 1 cycle for BRAM read)
%000001             wait_clk300(2);
                    // DMA should now be in DMA_TLP or DMA_IDLE (depending on desc_valid)
        
                    // Wait for DMA TLP generation to complete
                    // 63 TLPs × 18 beats = 1134 beats
%000001             wait_clk300(2000);
        
%000001             $display("[%0t] PCIe DMA TLP test done, active=%b",
%000001                      $time, u_dut.u_pcie_dma.dma_active);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 24: Strategy arbiter asymmetric validity paths
                // Load zero weights for specific cores to create single-valid
                // tournament paths at each level
                // ==============================================================
%000001         $display("[%0t] === Phase 24: Strategy arbiter asymmetry ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             tests_run++;
        
                    // Set score_thresh = 1 to gate out zero-score cores
%000001             axil_write(12'h408, 32'h1);
%000001             wait_clk300(10);
        
                    // Pattern 1: Only core 0 valid → "only left" at L0/L1/L2
%000007             for (int core = 1; core < 8; core++)
~000224                 for (int w = 0; w < 32; w++)
 000224                     load_weight(core[2:0], w[4:0], 16'h0000);
                    // Send BBO update to trigger scoring
%000001             build_itch_add_order(64'h0000000000000300, 1'b0, 32'd100,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(500);
        
                    // Pattern 2: Only core 1 valid → "only right" at L0
~000032             for (int w = 0; w < 32; w++)
 000032                 load_weight(3'd0, w[4:0], 16'h0000);
~000032             for (int w = 0; w < 32; w++)
 000032                 load_weight(3'd1, w[4:0], 16'h3F80);
%000001             build_itch_add_order(64'h0000000000000301, 1'b1, 32'd100,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(500);
        
                    // Pattern 3: Only core 2 valid → "only right" at L1
~000032             for (int w = 0; w < 32; w++)
 000032                 load_weight(3'd1, w[4:0], 16'h0000);
~000032             for (int w = 0; w < 32; w++)
 000032                 load_weight(3'd2, w[4:0], 16'h3F80);
%000001             build_itch_add_order(64'h0000000000000302, 1'b0, 32'd100,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(500);
        
                    // Pattern 4: Only core 4 valid → "only right" at L2
~000032             for (int w = 0; w < 32; w++)
 000032                 load_weight(3'd2, w[4:0], 16'h0000);
~000032             for (int w = 0; w < 32; w++)
 000032                 load_weight(3'd4, w[4:0], 16'h3F80);
%000001             build_itch_add_order(64'h0000000000000303, 1'b1, 32'd100,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(500);
        
                    // Restore: all cores get weight=1.0
%000008             for (int core = 0; core < 8; core++)
~000256                 for (int w = 0; w < 32; w++)
 000256                     load_weight(core[2:0], w[4:0], 16'h3F80);
%000001             axil_write(12'h408, 32'h0);  // score_thresh back to 0
%000001             wait_clk300(10);
        
%000001             $display("[%0t] Strategy arbiter asymmetry tests done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 25: Moldupp64 error paths
                // Truncated frames and short datagrams
                // ==============================================================
%000001         $display("[%0t] === Phase 25: MoldUDP64 error paths ===", $time);
%000001         begin
%000001             byte unsigned frame[];
%000001             int flen;
%000001             tests_run++;
        
                    // Truncated frame: only send first 2 beats of header (16 bytes)
                    // then tlast → triggers early termination in HEADER_B0/B1
%000001             frame = new[16];
~000016             for (int i = 0; i < 16; i++) frame[i] = 8'h00;
%000001             frame[0] = 8'h02; frame[5] = 8'h01; // dest MAC
%000001             frame[12] = 8'h08; frame[13] = 8'h00; // EtherType
%000001             send_frame(frame, 16);
%000001             send_idle(5);
        
                    // Short datagram: only header (no ITCH payload)
                    // 14 (eth) + 20 (IP) + 8 (UDP) + 20 (mold header) = 62 bytes
                    // After eth_axis_rx + udp_complete_64 stripping: just 20-byte mold header
                    // Beat 2 will have only 4 bytes of mold header in upper half, tlast=1
%000001             frame = new[62];
~000062             for (int i = 0; i < 62; i++) frame[i] = 8'h00;
%000001             frame[0] = 8'h02; frame[5] = 8'h01;
%000001             frame[12] = 8'h08; frame[13] = 8'h00;
%000001             frame[14] = 8'h45; frame[22] = 8'h40; frame[23] = 8'h11;
%000001             frame[16] = 8'h00; frame[17] = 8'h30; // IP len = 48
%000001             frame[38] = 8'h00; frame[39] = 8'h1C; // UDP len = 28
%000001             frame[36] = 8'h67; frame[37] = 8'h6D;
                    // Mold header: seq=next_seq
%000001             frame[59] = next_seq[7:0];
%000001             frame[60] = 8'h00; frame[61] = 8'h00; // msg_count=0
%000001             send_frame(frame, 62);
%000001             next_seq++;
%000001             send_idle(10);
        
                    // Truncated mold: send frame that ends mid-header-B2
                    // 14 + 20 + 8 = 42 bytes for eth+IP+UDP, + 16 bytes of mold header (not full 20)
%000001             frame = new[58];
~000058             for (int i = 0; i < 58; i++) frame[i] = 8'h00;
%000001             frame[0] = 8'h02; frame[5] = 8'h01;
%000001             frame[12] = 8'h08; frame[13] = 8'h00;
%000001             frame[14] = 8'h45; frame[22] = 8'h40; frame[23] = 8'h11;
%000001             frame[16] = 8'h00; frame[17] = 8'h2C; // IP len = 44
%000001             frame[38] = 8'h00; frame[39] = 8'h18; // UDP len = 24
%000001             frame[36] = 8'h67; frame[37] = 8'h6D;
%000001             send_frame(frame, 58);
%000001             send_idle(10);
        
%000001             $display("[%0t] MoldUDP64 error path tests done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 26: OUCH template writes + AXI config paths
                // ==============================================================
%000001         $display("[%0t] === Phase 26: OUCH template + AXI config ===", $time);
%000001         begin
%000001             logic [31:0] rdata;
%000001             tests_run++;
        
                    // Write OUCH template for symbol 0: 4 beat slots
                    // Beat 2 (b2): stock name bytes 0-3
%000001             axil_write(12'hE00, 32'h000);   // tmpl_addr = {sym=0, beat=0}
%000001             axil_write(12'hE04, 32'h41415000); // tmpl_data_lo
%000001             axil_write(12'hE08, 32'h4C202020); // tmpl_data_hi → triggers BRAM write
        
                    // Beat 3 (b3): stock name bytes 4-7
%000001             axil_write(12'hE00, 32'h001);   // tmpl_addr = {sym=0, beat=1}
%000001             axil_write(12'hE04, 32'h20202020);
%000001             axil_write(12'hE08, 32'h00000000);
        
                    // Beat 4 (b4): TIF + firm high
%000001             axil_write(12'hE00, 32'h002);   // tmpl_addr = {sym=0, beat=2}
%000001             axil_write(12'hE04, 32'h00003930);
%000001             axil_write(12'hE08, 32'h464F4F42);
        
                    // Beat 5 (b5): firm low + display
%000001             axil_write(12'hE00, 32'h003);   // tmpl_addr = {sym=0, beat=3}
%000001             axil_write(12'hE04, 32'h4152434F);
%000001             axil_write(12'hE08, 32'h59000000);
        
                    // Write per-core shares (0xC00-0xC1C)
%000008             for (int c = 0; c < 8; c++)
%000008                 axil_write(12'hC00 + c*4, 32'd200);
        
                    // Read risk_blocked_latch (0x410) — triggers clear-on-read
%000001             axil_read(12'h410, rdata);
%000001             $display("[%0t] Risk blocked latch: 0x%08h", $time, rdata);
                    // Read again to verify clear
%000001             axil_read(12'h410, rdata);
        
                    // Write DESC_WR_PTR (PCIe DMA 0x008 via BAR0)
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = 64'h6000_0001_0000_00FF;
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_0008};
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b1;
%000001             u_dut.u_pcie_dma.ax_rx_tdata  = {32'h0, 32'h0000_0001};
%000001             @(posedge clk_300);
%000001             u_dut.u_pcie_dma.ax_rx_tvalid = 1'b0;
%000001             u_dut.u_pcie_dma.ax_rx_tlast  = 1'b0;
%000001             wait_clk300(10);
        
%000001             $display("[%0t] OUCH template + AXI config done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 27: UDP stub error paths
                // Send frames that trigger RX_DROP and early termination
                // ==============================================================
%000001         $display("[%0t] === Phase 27: UDP error paths ===", $time);
%000001         begin
%000001             byte unsigned frame[];
%000001             int flen;
%000001             tests_run++;
        
                    // Frame with early tlast during UDP header parsing
                    // Just 14 (eth) + 8 (partial IP) = 22 bytes
%000001             frame = new[22];
~000022             for (int i = 0; i < 22; i++) frame[i] = 8'h00;
%000001             frame[0] = 8'h02; frame[5] = 8'h01;
%000001             frame[12] = 8'h08; frame[13] = 8'h00;
%000001             frame[14] = 8'h45;
%000001             send_frame(frame, 22);
%000001             send_idle(5);
        
                    // Frame that exercises eth_axis_rx flush path
                    // Need last beat to have 7+ valid bytes to trigger S_FLUSH
                    // 14-byte eth header + 7 payload bytes = 21 bytes = 3 beats
                    // Beat 0: 8 bytes
                    // Beat 1: 8 bytes (eth header ends at byte 13, payload starts at 14)
                    // Beat 2: 5 bytes (but we want 7+ in last beat's tkeep[7:6])
                    // Actually need frame_len = 14 + N where beat alignment triggers flush
                    // eth_axis_rx first beat: 8 bytes (eth[0..7])
                    // second beat: 6 bytes eth header (8..13) + 2 bytes payload → stage2
                    // The stub stages 2 bytes, then on tlast it checks if staged bytes need flush
                    // For flush: need tkeep[7:6] != 0 on last beat → 7 or 8 valid bytes
                    // Frame of 24 bytes: 3 beats of 8 bytes each. Last beat all 8 valid.
                    // eth_axis_rx: beat0(8B), beat1(8B), beat2(8B, tlast)
                    // After consuming 14-byte eth header, payload = 10 bytes
                    // beat1 carries: eth[8..13] + payload[0..1] → stages payload[0..1]
                    // beat2: payload[2..9] (8 bytes), tlast=1, tkeep=FF
                    // Output: {payload[2..9]} → but staged has payload[0..1]
                    // The stub outputs {beat2[47:0], staged} = 8 bytes at tkeep=FF
                    // Then checks: tkeep[7:6]=2'b11 → needs flush for remaining upper bytes
%000001             frame = new[24];
~000024             for (int i = 0; i < 24; i++) frame[i] = 8'hAA;
%000001             frame[0] = 8'h02; frame[5] = 8'h01;
%000001             frame[12] = 8'h08; frame[13] = 8'h00;
%000001             frame[14] = 8'h45; frame[22] = 8'h40; frame[23] = 8'h11;
%000001             send_frame(frame, 24);
%000001             send_idle(10);
        
%000001             $display("[%0t] UDP error path tests done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 28: Risk check block reasons
                // Fat-finger (block_reason=2'b10) and position limit (2'b11)
                // ==============================================================
%000001         $display("[%0t] === Phase 28: Risk block reasons ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             tests_run++;
        
                    // Restore band_bps for OUCH generation
%000001             axil_write(12'h400, 32'd16383);
%000001             axil_write(12'h404, 32'd5);  // max_qty=5 → fat-finger for shares > 5
%000001             wait_clk300(10);
        
                    // Send order with shares=10 > max_qty=5 → fat-finger block
%000001             build_itch_add_order(64'h0000000000000400, 1'b0, 32'd10,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(500);
        
                    // Restore max_qty
%000001             axil_write(12'h404, 32'd10000);
        
                    // Position limit: send orders to build up net position > 1000
                    // Each order adds core_shares (200) to position
                    // Need 1000/200 = 5 orders per direction, but it's per-symbol
                    // Actually position is tracked per core×symbol via pos_bram
                    // Need to send enough orders to exceed pos_limit=1000
%000008             for (int i = 0; i < 8; i++) begin
%000008                 build_itch_add_order(64'h0000000000000410 + i, 1'b1, 32'd3,
%000008                     64'h4141504C20202020, 32'd1, itch_msg);
%000008                 send_itch_msg(itch_msg);
%000008                 wait_clk300(100);
                    end
        
%000001             axil_write(12'h400, 32'd10000); // restore band_bps
%000001             wait_clk300(10);
        
%000001             $display("[%0t] Risk block reason tests done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 29: Additional coverage — misc paths
                // ==============================================================
%000001         $display("[%0t] === Phase 29: Misc coverage ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             logic [31:0] rdata;
%000001             tests_run++;
        
                    // Read more AXI registers for coverage
                    // Read ouch_engine counters
%000001             axil_read(12'h440, rdata);
                    // Read latency histogram bins 8-31
~000024             for (int b = 8; b < 32; b++)
 000024                 axil_read(12'h280 + b*4, rdata);
        
                    // Histogram clear and re-read
%000001             axil_write(12'h584, 32'h1);
%000001             wait_clk300(5);
%000001             axil_read(12'h580, rdata);
        
                    // Send P (Trade) message — handled as no-op by order_book
%000001             itch_msg = new[46];
%000001             itch_msg[0] = 8'h00; itch_msg[1] = 8'h2C;
%000001             itch_msg[2] = 8'h50;
~000043             for (int i = 3; i < 46; i++) itch_msg[i] = 8'h00;
                    // Set some fields for the trade
%000001             itch_msg[13] = 8'h00; itch_msg[20] = 8'hFF;
%000001             itch_msg[21] = 8'h42; // Buy side
%000001             itch_msg[26] = 8'h4E; itch_msg[27] = 8'h56;
%000001             itch_msg[28] = 8'h44; itch_msg[29] = 8'h41;
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
                    // Send orders to different symbols for diversity
%000001             build_itch_add_order(64'h0000000000000500, 1'b1, 32'd50,
%000001                 64'h4D45544120202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
%000001             build_itch_add_order(64'h0000000000000501, 1'b0, 32'd50,
%000001                 64'h4D45544120202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(100);
        
%000001             $display("[%0t] Misc coverage tests done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 30: OUCH backpressure overflow (ouch_engine bp_cnt/clr_cnt)
                // Hold tready=0 during S_SEND to trigger tx_ovf, then recover
                // ==============================================================
%000001         $display("[%0t] === Phase 30: OUCH backpressure overflow ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             tests_run++;
        
                    // Restore weights and ensure pipeline can produce OUCH
%000001             axil_write(12'h400, 32'd10000); // band_bps
%000001             axil_write(12'h404, 32'd10000); // max_qty
%000001             wait_clk300(10);
        
                    // Fork: wait for OUCH output then hold tready low
%000001             fork
%000001                 begin
                            // Wait for tvalid assertion (OUCH output starting)
 003534                     while (!m_axis_tvalid) @(posedge clk_300);
                            // Deassert tready to create backpressure during S_SEND
%000001                     m_axis_tready = 1'b0;
                            // Hold for 5 cycles — bp_cnt reaches 1 after 2 cycles → tx_ovf
%000001                     repeat (5) @(posedge clk_300);
%000001                     m_axis_tready = 1'b1;
                        end
                    join_none
        
                    // Send order pair at very small price so band check passes
                    // (Bug 2 + Bug 3: ref_price ≈ price/2, band check needs price_diff < thresh)
%000001             build_itch_add_order(64'h0000000000000600, 1'b0, 32'd100,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(200);
        
                    // AAPL buy at same price — triggers inference → risk_pass → OUCH
%000001             build_itch_add_order(64'h0000000000000601, 1'b1, 32'd100,
%000001                 64'h4141504C20202020, 32'd1, itch_msg);
%000001             send_itch_msg(itch_msg);
        
                    // Wait for pipeline + backpressure + recovery (256+ cycles for clr_cnt)
%000001             wait_clk300(1000);
        
%000001             $display("[%0t] OUCH BP overflow test done, tx_overflow=%b",
%000001                      $time, tx_overflow_out);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 31: Order book ref_empty on non-Add (delete non-existent order)
                // ==============================================================
%000001         $display("[%0t] === Phase 31: Order book ref_empty path ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             tests_run++;
        
                    // Delete an order_ref that was never Added — hits ref_empty_r path
%000001             build_itch_delete(64'hDEAD_BEEF_CAFE_0001, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(200);
        
                    // Execute an order_ref that was never Added
%000001             build_itch_execute(64'hDEAD_BEEF_CAFE_0002, 32'd50, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(200);
        
%000001             $display("[%0t] Order book ref_empty tests done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 32: MoldUDP64 truncated beat 0 header
                // ==============================================================
%000001         $display("[%0t] === Phase 32: Mold truncated B0 header ===", $time);
%000001         begin
%000001             byte unsigned frame[];
%000001             tests_run++;
        
                    // Send a very short UDP payload (< 8 bytes) so moldupp64_strip
                    // sees s_tlast during S_HEADER_B0
                    // Eth(14) + IP(20) + UDP(8) + 4 bytes mold = 46 bytes
                    // UDP stub outputs 4 bytes payload → single beat with tlast
                    // tkeep = 0x0F for 4 valid bytes → header_b0_valid checks tkeep[7:0]==FF
%000001             frame = new[46];
~000046             for (int i = 0; i < 46; i++) frame[i] = 8'h00;
%000001             frame[0] = 8'h02; frame[5] = 8'h01; // dest MAC
%000001             frame[12] = 8'h08; frame[13] = 8'h00; // IPv4
%000001             frame[14] = 8'h45; // IP version/IHL
%000001             frame[16] = 8'h00; frame[17] = 8'h20; // IP len = 32
%000001             frame[22] = 8'h40; frame[23] = 8'h11; // TTL + proto=UDP
%000001             frame[26] = 8'h0A; // src IP
%000001             frame[34] = 8'h04; frame[35] = 8'h00; // src port
%000001             frame[36] = 8'h67; frame[37] = 8'h6D; // dst port 26477
%000001             frame[38] = 8'h00; frame[39] = 8'h0C; // UDP len = 12 (8 hdr + 4 payload)
                    // 4 bytes of mold session — short, will hit header_b0 truncation
%000001             frame[42] = 8'h41; frame[43] = 8'h42; frame[44] = 8'h43; frame[45] = 8'h44;
%000001             send_frame(frame, 46);
%000001             send_idle(10);
        
                    // Also send a frame where header_b2_valid is false:
                    // Need 3 beats of UDP payload but beat 2 has tkeep < required
                    // This requires the UDP payload to be exactly 17-19 bytes (2 full beats + partial)
                    // where beat 2's tkeep doesn't have all required header bytes
                    // UDP payload = 17 bytes: beat0(8), beat1(8), beat2(1, tlast)
                    // On beat 2: tkeep=0x01, header_b2_valid checks for enough bytes
%000001             frame = new[59]; // 42 + 17
~000059             for (int i = 0; i < 59; i++) frame[i] = 8'h00;
%000001             frame[0] = 8'h02; frame[5] = 8'h01;
%000001             frame[12] = 8'h08; frame[13] = 8'h00;
%000001             frame[14] = 8'h45;
%000001             frame[16] = 8'h00; frame[17] = 8'h2D; // IP len = 45
%000001             frame[22] = 8'h40; frame[23] = 8'h11;
%000001             frame[26] = 8'h0A;
%000001             frame[34] = 8'h04; frame[35] = 8'h00;
%000001             frame[36] = 8'h67; frame[37] = 8'h6D;
%000001             frame[38] = 8'h00; frame[39] = 8'h19; // UDP len = 25 (8 hdr + 17 payload)
%000001             send_frame(frame, 59);
%000001             send_idle(10);
        
%000001             $display("[%0t] Mold truncated header tests done", $time);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 33: eth_axis_rx_wrap dropped frame counter
                // Force FIFO almost_full to trigger frame drop
                // ==============================================================
%000001         $display("[%0t] === Phase 33: Frame drop counter ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             byte unsigned frame[];
%000001             int flen;
%000001             tests_run++;
        
                    // Rapidly burst many frames to fill the CDC FIFO
                    // The FIFO almost_full signal gates new frames
~000020             for (int i = 0; i < 20; i++) begin
 000020                 build_itch_add_order(64'h0000000000000700 + i, (i & 1) ? 1'b1 : 1'b0, 32'd10,
 000020                     64'h4141504C20202020, 32'd1500000, itch_msg);
 000020                 build_frame(next_seq, 16'd1, itch_msg, frame, flen);
 000020                 send_frame(frame, flen);
 000020                 next_seq++;
 000020                 total_itch_msgs++;
                        // No idle between frames — back-to-back to stress FIFO
                    end
%000001             wait_clk300(500);
        
%000001             $display("[%0t] Frame drop counter test done, dropped=%0d", $time, dropped_frames_out);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Phase 21: Kill switch test (must be last)
                // ==============================================================
%000001         $display("[%0t] === Phase 21: Kill switch ===", $time);
%000001         begin
%000001             byte unsigned itch_msg[];
%000001             int ouch_before;
%000001             tests_run++;
%000001             ouch_before = ouch_pkt_count;
        
%000001             axil_write(12'h40C, 32'h1); // bit[0] = kill_switch (write-one-to-set)
%000001             $display("[%0t] Kill switch engaged", $time);
        
%000001             build_itch_add_order(64'h0000000000000200, 1'b1, 32'd100,
%000001                 64'h4141504C20202020, 32'd1500000, itch_msg);
%000001             send_itch_msg(itch_msg);
%000001             wait_clk300(500);
        
%000001             $display("[%0t] OUCH after kill switch: %0d (before: %0d)",
%000001                      $time, ouch_pkt_count, ouch_before);
%000001             tests_passed++;
                end
        
                // ==============================================================
                // Final summary
                // ==============================================================
%000001         wait_clk300(200);
        
%000001         $display("");
%000001         $display("============================================");
%000001         $display("  HFT SoC Testbench Summary");
%000001         $display("============================================");
%000001         $display("  Tests run:    %0d", tests_run);
%000001         $display("  Tests passed: %0d", tests_passed);
%000001         $display("  Tests failed: %0d", tests_failed);
%000001         $display("  ITCH messages sent: %0d", total_itch_msgs);
%000001         $display("  OUCH packets received: %0d", ouch_pkt_count);
%000001         $display("  Dropped frames: %0d", dropped_frames_out);
%000001         $display("  Dropped datagrams: %0d", dropped_datagrams_out);
%000001         $display("  Collision count: %0d", collision_count_out);
%000001         $display("  TX overflow: %0d", tx_overflow_out);
%000001         $display("============================================");
        
%000001         $finish;
            end
        
            // Simulation timeout
%000000     initial begin
%000000         #15_000_000_000ps; // 15ms max sim time
%000000         $display("[%0t] ERROR: Simulation timeout!", $time);
%000000         $finish;
            end
        
            // Debug traces (limited to first N events to reduce noise)
%000001     int dbg_parser = 0;
 031960     always @(posedge clk_300) begin
 031806         if (!cpu_reset && u_dut.u_lliu.parser_fields_valid && dbg_parser < 200) begin
 000154             $display("[%0t] DBG parser: type=0x%02h ref=0x%016h price=%0d side=%b shares=%0d",
 000154                 $time, u_dut.u_lliu.parser_msg_type, u_dut.u_lliu.parser_order_ref,
 000154                 u_dut.u_lliu.parser_price, u_dut.u_lliu.parser_side,
 000154                 u_dut.u_lliu.parser_shares);
 000154             dbg_parser++;
                end
            end
        
%000001     int dbg_arb = 0;
 031960     always @(posedge clk_300) begin
 024513         if (!cpu_reset && dbg_arb < 20) begin
 007427             if (u_dut.u_lliu.best_valid) begin
 000020                 $display("[%0t] DBG best_valid! core=%0d score=0x%08h",
 000020                     $time, u_dut.u_lliu.best_core_id, u_dut.u_lliu.best_score);
 000020                 dbg_arb++;
                    end
                end
            end
        
%000001     int dbg_risk = 0;
 031960     always @(posedge clk_300) begin
 031929         if (!cpu_reset && dbg_risk < 20) begin
 031916             if (u_dut.u_lliu.risk_pass) begin
 000013                 $display("[%0t] DBG risk_pass!", $time);
 000013                 dbg_risk++;
                    end
                end
            end
        
%000001     int dbg_mold = 0;
 016649     always @(posedge clk_156) begin
 015512         if (!cpu_reset && dbg_mold < 5) begin
~001132             if (u_dut.u_moldupp64.header_accept_b2) begin
%000005                 $display("[%0t] DBG mold: seq=%0d exp=%0d inorder=%b",
%000005                     $time,
%000005                     u_dut.u_moldupp64.header_seq_num_b2,
%000005                     u_dut.u_moldupp64.expected_seq_num,
%000005                     u_dut.u_moldupp64.header_in_order_b2);
%000005                 dbg_mold++;
                    end
                end
            end
        
        endmodule
        
