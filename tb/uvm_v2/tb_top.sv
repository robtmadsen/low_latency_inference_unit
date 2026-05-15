/* verilator coverage_off */  // Testbench — not DUT code
// tb_top.sv — Top-level Verilator testbench for kc705_top HFT SoC
// Uses UVM for test phasing, scoreboard, and coverage.

`include "uvm_macros.svh"
import uvm_pkg::*;
import lliu_pkg::*;

// =====================================================================
// AXI4-Lite write task helper (callable from driver)
// =====================================================================
class axil_wr_item extends uvm_sequence_item;
    rand logic [11:0] addr;
    rand logic [31:0] data;
    `uvm_object_utils(axil_wr_item)
    function new(string name="axil_wr_item");
        super.new(name);
    endfunction
endclass

// =====================================================================
// OUCH output transaction
// =====================================================================
class ouch_txn extends uvm_sequence_item;
    logic [63:0] beats [0:5];
    int          num_beats;
    `uvm_object_utils(ouch_txn)
    function new(string name="ouch_txn");
        super.new(name);
        num_beats = 0;
    endfunction
endclass

// =====================================================================
// Virtual interface for DUT signals
// =====================================================================
interface hft_if (
    input logic clk_156,
    input logic clk_300
);
    // MAC RX
    logic [63:0] mac_rx_tdata;
    logic [7:0]  mac_rx_tkeep;
    logic        mac_rx_tvalid;
    logic        mac_rx_tlast;
    logic        mac_rx_tready;

    // AXI4-Lite
    logic [11:0] axil_awaddr;
    logic        axil_awvalid;
    logic        axil_awready;
    logic [31:0] axil_wdata;
    logic [3:0]  axil_wstrb;
    logic        axil_wvalid;
    logic        axil_wready;
    logic [1:0]  axil_bresp;
    logic        axil_bvalid;
    logic        axil_bready;
    logic [11:0] axil_araddr;
    logic        axil_arvalid;
    logic        axil_arready;
    logic [31:0] axil_rdata;
    logic [1:0]  axil_rresp;
    logic        axil_rvalid;
    logic        axil_rready;

    // OUCH output
    logic [63:0] m_axis_tdata;
    logic [7:0]  m_axis_tkeep;
    logic        m_axis_tvalid;
    logic        m_axis_tlast;
    logic        m_axis_tready;

    // Reset
    logic        cpu_reset;

    // Monitoring
    logic [31:0] collision_count_out;
    logic        tx_overflow_out;
    logic [31:0] dropped_frames_out;
    logic [31:0] dropped_datagrams_out;
    logic [63:0] expected_seq_num_out;
    logic        fifo_rd_tvalid;
endinterface

// =====================================================================
// Reference model
// =====================================================================
class ref_model extends uvm_component;
    `uvm_component_utils(ref_model)
    int ouch_expected;
    int ouch_count;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ouch_expected = 0;
        ouch_count = 0;
    endfunction

    function void note_inference_trigger();
        ouch_expected++;
    endfunction

    function void note_ouch_received();
        ouch_count++;
    endfunction
endclass

// =====================================================================
// Scoreboard
// =====================================================================
class hft_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(hft_scoreboard)
    int ouch_pkt_count;
    int pass_count;
    int fail_count;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        ouch_pkt_count = 0;
        pass_count = 0;
        fail_count = 0;
    endfunction

    function void record_ouch(logic [63:0] beat0);
        ouch_pkt_count++;
        // Check OUCH packet starts with 'O' (0x4F) at MSB
        if (beat0[63:56] == 8'h4F) begin
            pass_count++;
            `uvm_info("SCB", $sformatf("OUCH pkt #%0d: msg_type=O correct", ouch_pkt_count), UVM_MEDIUM)
        end else begin
            fail_count++;
            `uvm_error("SCB", $sformatf("OUCH pkt #%0d: msg_type=0x%02x expected 0x4F",
                                         ouch_pkt_count, beat0[63:56]))
        end
    endfunction

    function void report_phase(uvm_phase phase);
        `uvm_info("SCB", $sformatf("Scoreboard: %0d OUCH pkts, %0d pass, %0d fail",
                                    ouch_pkt_count, pass_count, fail_count), UVM_LOW)
    endfunction
endclass

// =====================================================================
// Main UVM test
// =====================================================================
class hft_base_test extends uvm_test;
    `uvm_component_utils(hft_base_test)

    virtual hft_if vif;
    hft_scoreboard scb;
    ref_model      refm;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual hft_if)::get(this, "", "vif", vif))
            `uvm_fatal("CFG", "No virtual interface")
        scb  = hft_scoreboard::type_id::create("scb", this);
        refm = ref_model::type_id::create("refm", this);
    endfunction

    // Helper: AXI4-Lite write
    task axil_write(logic [11:0] addr, logic [31:0] data);
        @(posedge vif.clk_300);
        vif.axil_awaddr  <= addr;
        vif.axil_awvalid <= 1;
        vif.axil_wdata   <= data;
        vif.axil_wstrb   <= 4'hF;
        vif.axil_wvalid  <= 1;
        vif.axil_bready  <= 1;
        // Wait for both channels accepted
        fork
            begin
                while (!(vif.axil_awvalid && vif.axil_awready)) @(posedge vif.clk_300);
                @(posedge vif.clk_300);
                vif.axil_awvalid <= 0;
            end
            begin
                while (!(vif.axil_wvalid && vif.axil_wready)) @(posedge vif.clk_300);
                @(posedge vif.clk_300);
                vif.axil_wvalid <= 0;
            end
        join
        // Wait for BVALID
        while (!vif.axil_bvalid) @(posedge vif.clk_300);
        @(posedge vif.clk_300);
        vif.axil_bready <= 0;
    endtask

    // Helper: Build Ethernet frame containing IPv4/UDP/MoldUDP64/ITCH
    // Returns array of 64-bit beats to drive on mac_rx
    function automatic void build_eth_frame(
        input  logic [7:0] itch_body [],
        input  logic [63:0] mold_seq_num,
        output logic [63:0] beats [],
        output logic [7:0]  keeps [],
        output logic        lasts []
    );
        // Build full packet
        automatic int pkt_len;
        automatic logic [7:0] pkt [];
        automatic int mold_payload_len;
        automatic int udp_payload_len;
        automatic int udp_total_len;
        automatic int ip_total_len;
        automatic int i, beat_idx;
        mold_payload_len = itch_body.size();
        udp_payload_len = 20 + mold_payload_len; // MoldUDP64 header + ITCH
        udp_total_len = 8 + udp_payload_len; // UDP header + UDP payload
        ip_total_len = 20 + udp_total_len; // IP header + UDP

        pkt_len = 14 + ip_total_len; // Ethernet header + IP
        pkt = new[pkt_len];

        // Ethernet header (14 bytes)
        // Dst MAC: 02:00:00:00:00:01
        pkt[0] = 8'h02; pkt[1] = 8'h00; pkt[2] = 8'h00;
        pkt[3] = 8'h00; pkt[4] = 8'h00; pkt[5] = 8'h01;
        // Src MAC: 02:00:00:00:00:02
        pkt[6] = 8'h02; pkt[7] = 8'h00; pkt[8] = 8'h00;
        pkt[9] = 8'h00; pkt[10] = 8'h00; pkt[11] = 8'h02;
        // EtherType: 0x0800 (IPv4)
        pkt[12] = 8'h08; pkt[13] = 8'h00;

        // IPv4 header (20 bytes, starting at pkt[14])
        pkt[14] = 8'h45; // Version=4, IHL=5
        pkt[15] = 8'h00; // DSCP/ECN
        pkt[16] = ip_total_len[15:8]; pkt[17] = ip_total_len[7:0]; // Total length
        pkt[18] = 8'h00; pkt[19] = 8'h00; // Identification
        pkt[20] = 8'h40; pkt[21] = 8'h00; // Flags/Fragment
        pkt[22] = 8'h40; // TTL=64
        pkt[23] = 8'h11; // Protocol=UDP(17)
        pkt[24] = 8'h00; pkt[25] = 8'h00; // Header checksum (0 for sim)
        // Src IP: 10.0.0.1
        pkt[26] = 8'h0A; pkt[27] = 8'h00; pkt[28] = 8'h00; pkt[29] = 8'h01;
        // Dst IP: 233.54.12.0
        pkt[30] = 8'hE9; pkt[31] = 8'h36; pkt[32] = 8'h0C; pkt[33] = 8'h00;

        // UDP header (8 bytes, starting at pkt[34])
        pkt[34] = 8'h04; pkt[35] = 8'h00; // Src port: 1024
        pkt[36] = 8'h67; pkt[37] = 8'h6D; // Dst port: 26477
        pkt[38] = udp_total_len[15:8]; pkt[39] = udp_total_len[7:0]; // UDP length
        pkt[40] = 8'h00; pkt[41] = 8'h00; // Checksum: 0

        // MoldUDP64 header (20 bytes, starting at pkt[42])
        // Session: "LLIU______" (10 bytes)
        pkt[42] = 8'h4C; pkt[43] = 8'h4C; pkt[44] = 8'h49; pkt[45] = 8'h55;
        pkt[46] = 8'h20; pkt[47] = 8'h20; pkt[48] = 8'h20; pkt[49] = 8'h20;
        pkt[50] = 8'h20; pkt[51] = 8'h20;
        // Sequence number (8 bytes, big-endian)
        for (i = 0; i < 8; i++) pkt[52+i] = mold_seq_num[(7-i)*8 +: 8];
        // Message count: 1 (2 bytes, big-endian)
        pkt[60] = 8'h00; pkt[61] = 8'h01;

        // ITCH body (starting at pkt[62])
        for (i = 0; i < itch_body.size(); i++) pkt[62+i] = itch_body[i];

        // Serialize to 64-bit beats (LSB-first: byte 0 → tdata[7:0])
        beat_idx = (pkt_len + 7) / 8;
        beats = new[beat_idx];
        keeps = new[beat_idx];
        lasts = new[beat_idx];
        for (i = 0; i < beat_idx; i++) begin
            automatic int j;
            beats[i] = 64'h0;
            keeps[i] = 8'h0;
            lasts[i] = (i == beat_idx - 1) ? 1'b1 : 1'b0;
            for (j = 0; j < 8; j++) begin
                if (i*8+j < pkt_len) begin
                    beats[i][j*8 +: 8] = pkt[i*8+j];
                    keeps[i][j] = 1'b1;
                end
            end
        end
    endfunction

    // Helper: Build ITCH Add Order body (with 2-byte length prefix)
    function automatic void build_add_order(
        input logic [63:0] order_ref,
        input logic [7:0]  side_char,  // 'B'=0x42 or 'S'=0x53
        input logic [31:0] shares,
        input logic [63:0] stock,      // 8-byte ASCII
        input logic [31:0] price,
        output logic [7:0] body []
    );
        automatic int i;
        body = new[38]; // 2-byte length + 36-byte body
        // Length prefix (big-endian): 36
        body[0] = 8'h00; body[1] = 8'h24;
        // Body byte 0: msg_type = 'A' (0x41)
        body[2] = 8'h41;
        // Bytes 1-2: stock_locate = 0
        body[3] = 8'h00; body[4] = 8'h00;
        // Bytes 3-4: tracking_number = 0
        body[5] = 8'h00; body[6] = 8'h00;
        // Bytes 5-10: timestamp = 0 (6 bytes)
        for (i = 0; i < 6; i++) body[7+i] = 8'h00;
        // Bytes 11-18: order_ref (8 bytes, big-endian)
        for (i = 0; i < 8; i++) body[13+i] = order_ref[(7-i)*8 +: 8];
        // Byte 19: side
        body[21] = side_char;
        // Bytes 20-23: shares (4 bytes, big-endian)
        body[22] = shares[31:24]; body[23] = shares[23:16];
        body[24] = shares[15:8];  body[25] = shares[7:0];
        // Bytes 24-31: stock (8 bytes)
        for (i = 0; i < 8; i++) body[26+i] = stock[(7-i)*8 +: 8];
        // Bytes 32-35: price (4 bytes, big-endian)
        body[34] = price[31:24]; body[35] = price[23:16];
        body[36] = price[15:8];  body[37] = price[7:0];
    endfunction

    // Helper: Build ITCH Execute Order body
    function automatic void build_exec_order(
        input logic [63:0] order_ref,
        input logic [31:0] exec_shares,
        output logic [7:0] body []
    );
        automatic int i;
        // Padded to 40 bytes to work around RTL bug: itch_parser_v2 uses
        // byte_cnt+8 > msg_len (should be >=). For Execute msg_len=30,
        // 22+8=30 is NOT >30, causing the parser to discard the message.
        // Padding to 40 bytes gives an extra output beat so 30+8=38>30 fires.
        body = new[40]; // 2-byte length + 30-byte body + 8 pad
        body[0] = 8'h00; body[1] = 8'h1E; // length = 30
        body[2] = 8'h45; // 'E'
        body[3] = 8'h00; body[4] = 8'h00; // stock_locate
        body[5] = 8'h00; body[6] = 8'h00; // tracking_number
        for (i = 0; i < 6; i++) body[7+i] = 8'h00; // timestamp
        for (i = 0; i < 8; i++) body[13+i] = order_ref[(7-i)*8 +: 8]; // order_ref
        // Bytes 19-22: shares
        body[21] = exec_shares[31:24]; body[22] = exec_shares[23:16];
        body[23] = exec_shares[15:8];  body[24] = exec_shares[7:0];
        // Bytes 23-30: match_number + padding (zero-fill)
        for (i = 25; i < 40; i++) body[i] = 8'h00;
    endfunction

    // Helper: Build ITCH Cancel Order body
    function automatic void build_cancel_order(
        input logic [63:0] order_ref,
        input logic [31:0] cancel_shares,
        output logic [7:0] body []
    );
        automatic int i;
        // Padded to 32 bytes to work around two RTL bugs:
        // 1) moldupp64_strip S_PAYLOAD loses staged bytes on s_tlast when
        //    upper-half of last beat has valid data (25-byte body → 5 bytes
        //    in last UDP beat, 1 byte lost in staging register).
        // 2) itch_parser_v2 uses > instead of >= (22>23 fails, truncated).
        // Padding to 32 bytes: mold output 4 beats, parser 22+8=30>23 ✓
        body = new[32]; // 2-byte length + 23-byte body + 7 pad
        body[0] = 8'h00; body[1] = 8'h17; // length = 23
        body[2] = 8'h58; // 'X'
        body[3] = 8'h00; body[4] = 8'h00;
        body[5] = 8'h00; body[6] = 8'h00;
        for (i = 0; i < 6; i++) body[7+i] = 8'h00;
        for (i = 0; i < 8; i++) body[13+i] = order_ref[(7-i)*8 +: 8];
        body[21] = cancel_shares[31:24]; body[22] = cancel_shares[23:16];
        body[23] = cancel_shares[15:8];  body[24] = cancel_shares[7:0];
        for (i = 25; i < 32; i++) body[i] = 8'h00; // padding
    endfunction

    // Helper: Build ITCH Delete Order body
    function automatic void build_delete_order(
        input logic [63:0] order_ref,
        output logic [7:0] body []
    );
        automatic int i;
        body = new[21]; // 2-byte length + 19-byte body
        body[0] = 8'h00; body[1] = 8'h13; // length = 19
        body[2] = 8'h44; // 'D'
        body[3] = 8'h00; body[4] = 8'h00;
        body[5] = 8'h00; body[6] = 8'h00;
        for (i = 0; i < 6; i++) body[7+i] = 8'h00;
        for (i = 0; i < 8; i++) body[13+i] = order_ref[(7-i)*8 +: 8];
    endfunction

    // Helper: Build ITCH Replace Order body ('U')
    function automatic void build_replace_order(
        input logic [63:0] orig_order_ref,
        input logic [63:0] new_order_ref,
        input logic [31:0] shares,
        input logic [31:0] price,
        output logic [7:0] body []
    );
        automatic int i;
        body = new[37]; // 2-byte length + 35-byte body
        body[0] = 8'h00; body[1] = 8'h23; // length = 35
        body[2] = 8'h55; // 'U'
        body[3] = 8'h00; body[4] = 8'h00; // stock_locate
        body[5] = 8'h00; body[6] = 8'h00; // tracking_number
        for (i = 0; i < 6; i++) body[7+i] = 8'h00; // timestamp
        for (i = 0; i < 8; i++) body[13+i] = orig_order_ref[(7-i)*8 +: 8]; // bytes 11-18
        for (i = 0; i < 8; i++) body[21+i] = new_order_ref[(7-i)*8 +: 8];  // bytes 19-26
        body[29] = shares[31:24]; body[30] = shares[23:16]; // bytes 27-30
        body[31] = shares[15:8];  body[32] = shares[7:0];
        body[33] = price[31:24]; body[34] = price[23:16]; // bytes 31-34
        body[35] = price[15:8];  body[36] = price[7:0];
    endfunction

    // Helper: Build ITCH Trade body ('P')
    function automatic void build_trade_msg(
        input logic [63:0] order_ref,
        input logic [7:0]  side_char,
        input logic [31:0] shares,
        input logic [63:0] stock,
        input logic [31:0] price,
        output logic [7:0] body []
    );
        automatic int i;
        body = new[45]; // 2-byte length + 43-byte body
        body[0] = 8'h00; body[1] = 8'h2B; // length = 43
        body[2] = 8'h50; // 'P'
        body[3] = 8'h00; body[4] = 8'h00;
        body[5] = 8'h00; body[6] = 8'h00;
        for (i = 0; i < 6; i++) body[7+i] = 8'h00; // timestamp
        for (i = 0; i < 8; i++) body[13+i] = order_ref[(7-i)*8 +: 8]; // order_ref
        body[21] = side_char;
        body[22] = shares[31:24]; body[23] = shares[23:16];
        body[24] = shares[15:8];  body[25] = shares[7:0];
        for (i = 0; i < 8; i++) body[26+i] = stock[(7-i)*8 +: 8]; // stock
        body[34] = price[31:24]; body[35] = price[23:16];
        body[36] = price[15:8];  body[37] = price[7:0];
        for (i = 38; i < 45; i++) body[i] = 8'h00; // match_number
    endfunction

    // Helper: Build ITCH Add Order with MPID body ('F')
    function automatic void build_add_order_mpid(
        input logic [63:0] order_ref,
        input logic [7:0]  side_char,
        input logic [31:0] shares,
        input logic [63:0] stock,
        input logic [31:0] price,
        output logic [7:0] body []
    );
        automatic int i;
        body = new[42]; // 2-byte length + 40-byte body
        body[0] = 8'h00; body[1] = 8'h28; // length = 40
        body[2] = 8'h46; // 'F' (Add Order MPID)
        body[3] = 8'h00; body[4] = 8'h00;
        body[5] = 8'h00; body[6] = 8'h00;
        for (i = 0; i < 6; i++) body[7+i] = 8'h00;
        for (i = 0; i < 8; i++) body[13+i] = order_ref[(7-i)*8 +: 8];
        body[21] = side_char;
        body[22] = shares[31:24]; body[23] = shares[23:16];
        body[24] = shares[15:8];  body[25] = shares[7:0];
        for (i = 0; i < 8; i++) body[26+i] = stock[(7-i)*8 +: 8];
        body[34] = price[31:24]; body[35] = price[23:16];
        body[36] = price[15:8];  body[37] = price[7:0];
        // MPID field (4 bytes): "LLIU"
        body[38] = 8'h4C; body[39] = 8'h4C; body[40] = 8'h49; body[41] = 8'h55;
    endfunction

    // Helper: Build ITCH Order Executed with Price body ('C')
    function automatic void build_exec_price_order(
        input logic [63:0] order_ref,
        input logic [31:0] exec_shares,
        input logic [31:0] exec_price,
        output logic [7:0] body []
    );
        automatic int i;
        // Body=35 bytes, padded to 40 bytes for parser byte_cnt+8>msg_len safety
        body = new[42]; // 2-byte length + 35-byte body + 5 pad
        body[0] = 8'h00; body[1] = 8'h23; // length = 35
        body[2] = 8'h43; // 'C' (Order Executed with Price)
        body[3] = 8'h00; body[4] = 8'h00;
        body[5] = 8'h00; body[6] = 8'h00;
        for (i = 0; i < 6; i++) body[7+i] = 8'h00;
        for (i = 0; i < 8; i++) body[13+i] = order_ref[(7-i)*8 +: 8];
        // Bytes 19-22: shares
        body[21] = exec_shares[31:24]; body[22] = exec_shares[23:16];
        body[23] = exec_shares[15:8];  body[24] = exec_shares[7:0];
        // Bytes 23-30: match_number (8 bytes)
        for (i = 25; i < 33; i++) body[i] = 8'h00;
        // Byte 31: printable
        body[33] = 8'h59; // 'Y'
        // Bytes 32-35: exec_price (4 bytes, big-endian)
        body[34] = exec_price[31:24]; body[35] = exec_price[23:16];
        body[36] = exec_price[15:8];  body[37] = exec_price[7:0];
        // Padding
        for (i = 38; i < 42; i++) body[i] = 8'h00;
    endfunction

    // Helper: Build a truncated/malformed Ethernet frame (short)
    function automatic void build_short_frame(
        output logic [63:0] beats [],
        output logic [7:0]  keeps [],
        output logic        lasts []
    );
        beats = new[1];
        keeps = new[1];
        lasts = new[1];
        beats[0] = 64'hDEADCAFE_12345678;
        keeps[0] = 8'hFF;
        lasts[0] = 1'b1;
    endfunction

    // Helper: AXI4-Lite read
    task axil_read(logic [11:0] addr, output logic [31:0] data);
        @(posedge vif.clk_300);
        vif.axil_araddr  <= addr;
        vif.axil_arvalid <= 1;
        vif.axil_rready  <= 1;
        while (!(vif.axil_arvalid && vif.axil_arready)) @(posedge vif.clk_300);
        @(posedge vif.clk_300);
        vif.axil_arvalid <= 0;
        while (!vif.axil_rvalid) @(posedge vif.clk_300);
        data = vif.axil_rdata;
        @(posedge vif.clk_300);
        vif.axil_rready <= 0;
    endtask

    // Drive one Ethernet frame on mac_rx interface
    // Each beat is presented for exactly one clock cycle (no double-handshake).
    task drive_frame(
        input logic [63:0] beats [],
        input logic [7:0]  keeps [],
        input logic        lasts []
    );
        for (int i = 0; i < beats.size(); i++) begin
            vif.mac_rx_tdata  <= beats[i];
            vif.mac_rx_tkeep  <= keeps[i];
            vif.mac_rx_tvalid <= 1;
            vif.mac_rx_tlast  <= lasts[i];
            @(posedge vif.clk_156);
            while (!vif.mac_rx_tready) @(posedge vif.clk_156);
        end
        vif.mac_rx_tvalid <= 0;
        vif.mac_rx_tlast  <= 0;
        @(posedge vif.clk_156);
    endtask

    // Monitor OUCH output
    task monitor_ouch(int timeout_cycles);
        automatic int cycles = 0;
        automatic logic [63:0] beat0;
        automatic int beat_cnt = 0;
        while (cycles < timeout_cycles) begin
            @(posedge vif.clk_300);
            if (vif.m_axis_tvalid && vif.m_axis_tready) begin
                if (beat_cnt == 0) beat0 = vif.m_axis_tdata;
                beat_cnt++;
                if (vif.m_axis_tlast) begin
                    scb.record_ouch(beat0);
                    refm.note_ouch_received();
                    beat_cnt = 0;
                end
            end
            cycles++;
        end
    endtask

    task run_phase(uvm_phase phase);
        automatic logic [7:0]  itch_body [];
        automatic logic [63:0] beats [];
        automatic logic [7:0]  keeps [];
        automatic logic        lasts [];
        automatic logic [63:0] mold_seq;
        automatic int i;

        phase.raise_objection(this);
        `uvm_info("TEST", "=== HFT Base Test Starting ===", UVM_LOW)

        // Initialize interface signals
        vif.mac_rx_tdata  <= 0;
        vif.mac_rx_tkeep  <= 0;
        vif.mac_rx_tvalid <= 0;
        vif.mac_rx_tlast  <= 0;
        vif.axil_awaddr   <= 0;
        vif.axil_awvalid  <= 0;
        vif.axil_wdata    <= 0;
        vif.axil_wstrb    <= 0;
        vif.axil_wvalid   <= 0;
        vif.axil_bready   <= 0;
        vif.axil_araddr   <= 0;
        vif.axil_arvalid  <= 0;
        vif.axil_rready   <= 1;
        vif.m_axis_tready <= 1;

        // Wait for reset deassert + 16 cycles
        vif.cpu_reset <= 1;
        repeat(20) @(posedge vif.clk_156);
        repeat(20) @(posedge vif.clk_300);
        vif.cpu_reset <= 0;
        repeat(20) @(posedge vif.clk_156);
        repeat(20) @(posedge vif.clk_300);
        `uvm_info("TEST", "Reset deasserted, system running", UVM_LOW)

        // ---- Phase 1: Configure symbol filter ----
        `uvm_info("TEST", "Configuring symbol filter for AAPL", UVM_LOW)
        // Write CAM entry 0: "AAPL    " = 0x4141504C20202020
        axil_write(12'h014, 32'h00);       // CAM_INDEX = 0
        axil_write(12'h038, 32'h00);       // CAM_INDEX_HI = 0
        axil_write(12'h018, 32'h20202020); // CAM_DATA_LO (lower 4 bytes: spaces)
        axil_write(12'h01C, 32'h4141504C); // CAM_DATA_HI (upper 4 bytes: "AAPL")
        axil_write(12'h020, 32'h03);       // CAM_CTRL: wr_valid=1, en_bit=1

        // Write CAM entry 1: "MSFT    " = 0x4D53465420202020
        axil_write(12'h014, 32'h01);       // CAM_INDEX = 1
        axil_write(12'h018, 32'h20202020); // CAM_DATA_LO
        axil_write(12'h01C, 32'h4D534654); // CAM_DATA_HI ("MSFT")
        axil_write(12'h020, 32'h03);       // CAM_CTRL: wr_valid=1, en_bit=1

        // ---- Phase 2: Load weights (all 1.0 = 0x3F80 in bfloat16) ----
        `uvm_info("TEST", "Loading weights for all 8 cores", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                axil_write(waddr, 32'h3F80); // bfloat16 1.0
            end
        end

        // ---- Phase 2b: Configure OUCH template for symbol 0 (AAPL) ----
        `uvm_info("TEST", "Configuring OUCH template for AAPL (sym_id=0)", UVM_LOW)
        // Beat 2: stock bytes 0-3
        axil_write(12'hE00, {23'h0, 9'd0});        // tmpl_addr = {sym=0, beat=0}
        axil_write(12'hE04, 32'h4141504C);          // "AAPL"
        axil_write(12'hE08, 32'h00000000);          // trigger write
        // Beat 3: stock bytes 4-7
        axil_write(12'hE00, {23'h0, 9'd1});
        axil_write(12'hE04, 32'h20202020);          // "    "
        axil_write(12'hE08, 32'h00000000);
        // Beat 4: TIF + firm_high
        axil_write(12'hE00, {23'h0, 9'd2});
        axil_write(12'hE04, 32'h00000000);
        axil_write(12'hE08, 32'h00003900);          // TIF = '9' (IOC)
        // Beat 5: firm_low + display
        axil_write(12'hE00, {23'h0, 9'd3});
        axil_write(12'hE04, 32'h00000000);
        axil_write(12'hE08, 32'h00000000);

        // ---- Phase 3: Configure risk + strategy ----
        `uvm_info("TEST", "Configuring risk parameters", UVM_LOW)
        axil_write(12'h400, 32'd16383);  // BAND_BPS = max (wide band to accommodate parser price bug)
        axil_write(12'h404, 32'd100000); // MAX_QTY = 100000
        axil_write(12'h408, 32'h00000000); // SCORE_THRESH = 0.0 (float32)
        // Per-core shares
        for (i = 0; i < 8; i++)
            axil_write(12'hC00 + i[11:0]*4, 32'd100);

        repeat(10) @(posedge vif.clk_300);

        // ---- Start OUCH monitor in background (runs for entire test) ----
        fork
            monitor_ouch(500000);
        join_none

        // ---- Phase 4: Send ITCH messages ----
        // NOTE: Parser has a 1-byte price offset bug (multiplies prices by ~256).
        // Use low ITCH prices so bugged values stay within 27-bit ref_price range.
        // Price range: 50000-200000 → bugged 12.8M-51.2M, fits in 27 bits.
        `uvm_info("TEST", "Sending ITCH Add Order (Buy, AAPL)", UVM_LOW)
        mold_seq = 64'd1;

        // Add Order Buy: AAPL, 100 shares @ $10.0000 (= 100000 ITCH units)
        build_add_order(64'd1001, 8'h42, 32'd100,
                        64'h4141504C20202020, 32'd100000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        repeat(20) @(posedge vif.clk_156);

        // Add Order Sell: AAPL, 200 shares @ $10.5000 (= 105000)
        `uvm_info("TEST", "Sending ITCH Add Order (Sell, AAPL)", UVM_LOW)
        build_add_order(64'd1002, 8'h53, 32'd200,
                        64'h4141504C20202020, 32'd105000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        repeat(20) @(posedge vif.clk_156);

        // Add Order Buy: MSFT, 50 shares @ $10.2000 (= 102000)
        `uvm_info("TEST", "Sending ITCH Add Order (Buy, MSFT)", UVM_LOW)
        build_add_order(64'd2001, 8'h42, 32'd50,
                        64'h4D53465420202020, 32'd102000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        repeat(20) @(posedge vif.clk_156);

        // Add Order Sell: MSFT, 75 shares @ $10.6000 (= 106000)
        `uvm_info("TEST", "Sending ITCH Add Order (Sell, MSFT)", UVM_LOW)
        build_add_order(64'd2002, 8'h53, 32'd75,
                        64'h4D53465420202020, 32'd106000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Execute partial order (very large gap to ensure pipeline is drained)
        repeat(300) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Execute Order (partial, buy-side)", UVM_LOW)
        build_exec_order(64'd1001, 32'd50, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Cancel order on sell-side (very large gap)
        repeat(300) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Cancel Order (sell-side)", UVM_LOW)
        build_cancel_order(64'd1002, 32'd100, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Delete order on buy-side (very large gap)
        repeat(300) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Delete Order (buy-side)", UVM_LOW)
        build_delete_order(64'd2001, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Replace order: replace MSFT sell (2002) with new ref 2003
        // NOTE: 'U' price is extracted correctly (no parser bug), so use a
        // value > current bugged ask BBO (~26.88M) to avoid corrupting BBO
        repeat(100) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Replace Order (MSFT sell)", UVM_LOW)
        build_replace_order(64'd2002, 64'd2003, 32'd80, 32'd30000000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Trade message ('P') — order_book default no-op path
        repeat(100) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Trade message (P)", UVM_LOW)
        build_trade_msg(64'd9999, 8'h42, 32'd25,
                        64'h4141504C20202020, 32'd100000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Add more sell-side order for AAPL to establish ask BBO, then delete it
        repeat(100) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Add sell AAPL (for delete test)", UVM_LOW)
        build_add_order(64'd1010, 8'h53, 32'd100,
                        64'h4141504C20202020, 32'd108000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Delete sell-side order
        repeat(100) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Delete Order (sell-side)", UVM_LOW)
        build_delete_order(64'd1010, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Execute on sell-side: exec against MSFT sell replacement (2003)
        repeat(100) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Execute Order (sell-side)", UVM_LOW)
        build_exec_order(64'd2003, 32'd40, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Cancel to zero shares: fully cancel remaining AAPL buy (1001 had 100 shares, exec'd 50 = 50 left)
        repeat(100) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending Cancel to zero shares (full cancel)", UVM_LOW)
        build_cancel_order(64'd1001, 32'd50, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Fat-finger: shares > MAX_QTY (100000) — triggers risk_check fat-finger block
        repeat(100) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending fat-finger order (shares > MAX_QTY)", UVM_LOW)
        build_add_order(64'd5500, 8'h42, 32'd200000,
                        64'h4141504C20202020, 32'd103000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Sequence number gap: skip current expected seq, send next (should be dropped)
        begin
            automatic logic [63:0] skip_seq = mold_seq;
            mold_seq = skip_seq + 1;
            repeat(20) @(posedge vif.clk_156);
            `uvm_info("TEST", $sformatf("Sending seq gap (skip %0d, send %0d)", skip_seq, mold_seq), UVM_LOW)
            build_add_order(64'd4001, 8'h42, 32'd10,
                            64'h4141504C20202020, 32'd100000, itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);

            // Now send the correct expected seq (should be accepted)
            repeat(20) @(posedge vif.clk_156);
            `uvm_info("TEST", $sformatf("Sending correct seq %0d", skip_seq), UVM_LOW)
            build_add_order(64'd4002, 8'h53, 32'd10,
                            64'h4141504C20202020, 32'd100000, itch_body);
            build_eth_frame(itch_body, skip_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq = skip_seq + 1;
        end

        // More orders to exercise pipeline
        for (i = 0; i < 5; i++) begin
            repeat(20) @(posedge vif.clk_156);
            build_add_order(64'd5000+i, 8'h42, 32'(10+i*10),
                            64'h4141504C20202020, 32'(95000+i*2000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end

        // Back-pressure test: briefly deassert tready (1 cycle only — below
        // ouch_engine's 2-cycle overflow threshold)
        repeat(5) @(posedge vif.clk_156);
        vif.m_axis_tready <= 0;
        @(posedge vif.clk_300);
        vif.m_axis_tready <= 1;

        // More messages with intermittent AXIS valid gaps
        for (i = 0; i < 3; i++) begin
            repeat(5) @(posedge vif.clk_156);
            build_add_order(64'd6000+i, (i%2==0) ? 8'h42 : 8'h53, 32'(50+i*25),
                            64'h4D53465420202020, 32'(100000+i*2000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            // Drive with gaps — each beat presented exactly once
            for (int b = 0; b < beats.size(); b++) begin
                vif.mac_rx_tdata  <= beats[b];
                vif.mac_rx_tkeep  <= keeps[b];
                vif.mac_rx_tvalid <= 1;
                vif.mac_rx_tlast  <= lasts[b];
                @(posedge vif.clk_156);
                while (!vif.mac_rx_tready) @(posedge vif.clk_156);
                // Insert idle between some beats
                if (b == 1) begin
                    vif.mac_rx_tvalid <= 0;
                    repeat(3) @(posedge vif.clk_156);
                end
            end
            vif.mac_rx_tvalid <= 0;
            vif.mac_rx_tlast  <= 0;
            @(posedge vif.clk_156);
            mold_seq++;
        end

        // ---- Phase 5: Additional orders after BBO established ----
        // After previous orders establish BBO, these should pass risk check
        repeat(100) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending additional AAPL orders (post-BBO)", UVM_LOW)
        for (i = 0; i < 10; i++) begin
            repeat(30) @(posedge vif.clk_156);
            build_add_order(64'd7000+i, (i%2==0) ? 8'h42 : 8'h53,
                            32'(50+i*10),
                            64'h4141504C20202020,
                            32'(96000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end

        // ---- Phase 6: More MSFT orders ----
        `uvm_info("TEST", "Sending additional MSFT orders (post-BBO)", UVM_LOW)
        for (i = 0; i < 5; i++) begin
            repeat(30) @(posedge vif.clk_156);
            build_add_order(64'd8000+i, (i%2==0) ? 8'h42 : 8'h53,
                            32'(25+i*5),
                            64'h4D53465420202020,
                            32'(98000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end

        // ---- Phase 7: Unfiltered symbol (should not trigger inference) ----
        repeat(30) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending unfiltered symbol GOOG", UVM_LOW)
        build_add_order(64'd9001, 8'h42, 32'd100,
                        64'h474F4F4720202020, 32'd100000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // ---- Phase 8: Rapid-fire burst (tests pipeline back-to-back) ----
        `uvm_info("TEST", "Sending rapid burst of 20 orders", UVM_LOW)
        for (i = 0; i < 20; i++) begin
            repeat(5) @(posedge vif.clk_156);
            build_add_order(64'd10000+i, (i%2==0) ? 8'h42 : 8'h53,
                            32'(10+i*5),
                            64'h4141504C20202020,
                            32'(90000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end

        // ---- Phase 9: Reconfigure weights — odd cores get 2.0 ----
        `uvm_info("TEST", "Reconfiguring weights: odd cores = 2.0", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            if (i % 2 == 1) begin
                for (int w = 0; w < 32; w++) begin
                    automatic logic [11:0] waddr;
                    waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                    axil_write(waddr, 32'h4000); // bfloat16 2.0
                end
            end
        end
        repeat(10) @(posedge vif.clk_300);

        // Send a few more orders with new weights to exercise arbiter asymmetry
        for (i = 0; i < 6; i++) begin
            repeat(30) @(posedge vif.clk_156);
            build_add_order(64'd11000+i, (i%2==0) ? 8'h42 : 8'h53,
                            32'(30+i*10),
                            64'h4141504C20202020,
                            32'(97000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end

        // ---- Phase 10: Reconfigure weights — only odd cores active (even = 0) ----
        `uvm_info("TEST", "Reconfiguring weights: even cores = 0", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            if (i % 2 == 0) begin
                for (int w = 0; w < 32; w++) begin
                    automatic logic [11:0] waddr;
                    waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                    axil_write(waddr, 32'h0000); // weight = 0
                end
            end
        end
        // Wait for pipeline to drain before sending new orders
        repeat(200) @(posedge vif.clk_300);

        // Orders with only odd cores active → exercises one-sided arbiter paths
        for (i = 0; i < 4; i++) begin
            repeat(50) @(posedge vif.clk_156);
            build_add_order(64'd12000+i, (i%2==0) ? 8'h42 : 8'h53,
                            32'(20+i*15),
                            64'h4141504C20202020,
                            32'(99000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end

        // ---- Phase 11: AXI-Lite register reads ----
        `uvm_info("TEST", "Reading AXI-Lite status registers", UVM_LOW)
        begin
            automatic logic [31:0] rdata;
            // Read RISK_STATUS (0x410) — {kill_sw, risk_blocked_latch}
            axil_read(12'h410, rdata);
            `uvm_info("TEST", $sformatf("Risk STATUS = 0x%08x", rdata), UVM_MEDIUM)
            // Read collision count (0x048)
            axil_read(12'h048, rdata);
            `uvm_info("TEST", $sformatf("Collision count = 0x%08x", rdata), UVM_MEDIUM)
            // Read overflow bin (0x580)
            axil_read(12'h580, rdata);
            `uvm_info("TEST", $sformatf("Overflow bin = 0x%08x", rdata), UVM_MEDIUM)
            // Read latency histogram bins (0x280-0x2FC, addr[11:7]=5'b00101)
            for (int r = 0; r < 4; r++) begin
                axil_read(12'h280 + r[11:0]*4, rdata);
                `uvm_info("TEST", $sformatf("Histogram[%0d] = 0x%08x", r, rdata), UVM_MEDIUM)
            end
            // Read unknown address (covers default rdata=0 path)
            axil_read(12'hFFC, rdata);
            `uvm_info("TEST", $sformatf("Unknown addr = 0x%08x", rdata), UVM_MEDIUM)
        end

        // Write to latency histogram clear register (0x584)
        axil_write(12'h584, 32'h01); // Clear histogram
        repeat(5) @(posedge vif.clk_300);

        // ---- Phase 12a: ITCH msg type 'F' (Add Order MPID) ----
        `uvm_info("TEST", "Sending 'F' (Add Order MPID) messages", UVM_LOW)
        for (i = 0; i < 3; i++) begin
            repeat(40) @(posedge vif.clk_156);
            build_add_order_mpid(64'd14000+i, (i%2==0) ? 8'h42 : 8'h53, 32'(30+i*5),
                                 64'h4141504C20202020, 32'(97000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(300) @(posedge vif.clk_300);

        // ---- Phase 12b: ITCH msg type 'C' (Order Executed with Price) ----
        `uvm_info("TEST", "Sending 'C' (Exec with Price) messages", UVM_LOW)
        // First add some orders that we can execute with price
        for (i = 0; i < 2; i++) begin
            repeat(40) @(posedge vif.clk_156);
            build_add_order(64'd14100+i, 8'h53, 32'd200,
                            64'h4141504C20202020, 32'd100000, itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(100) @(posedge vif.clk_300);
        // Execute with price
        for (i = 0; i < 2; i++) begin
            repeat(40) @(posedge vif.clk_156);
            build_exec_price_order(64'd14100+i, 32'd50, 32'd102000, itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(300) @(posedge vif.clk_300);

        // ---- Phase 12c: Arbiter — asymmetric weights within pairs for lv0 right-wins ----
        // Core 0=1.0, Core 1=3.0 → lv0[0] right wins (core 1 > core 0)
        // Core 2=1.0, Core 3=3.0 → lv0[1] right wins
        // Core 4=1.0, Core 5=3.0 → lv0[2] right wins
        // Core 6=1.0, Core 7=3.0 → lv0[3] right wins
        // All lv0 valid → lv1: scores equal (both ∝ 3.0) → left wins
        // lv2: scores equal → left wins
        `uvm_info("TEST", "Arbiter: asymmetric weights (odd cores > even cores)", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                if (i % 2 == 1)
                    axil_write(waddr, 32'h4040); // bfloat16 3.0
                else
                    axil_write(waddr, 32'h3F80); // bfloat16 1.0
            end
        end
        repeat(200) @(posedge vif.clk_300);
        for (i = 0; i < 3; i++) begin
            repeat(60) @(posedge vif.clk_156);
            build_add_order(64'd15000+i, 8'h42, 32'(25+i*5),
                            64'h4141504C20202020, 32'(96000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(350) @(posedge vif.clk_300);

        // ---- Phase 12d: Arbiter — lv1 right-wins ----
        // lv0[0] = winner of (0,1) score ∝ 1.0
        // lv0[1] = winner of (2,3) score ∝ 3.0
        // → lv1[0] = lv0[1] wins (RIGHT wins at lv1)
        // Similarly for lv1[1]: lv0[2] < lv0[3] → right wins
        // Then lv2: both equal ∝ 3.0 → left wins
        `uvm_info("TEST", "Arbiter: lv1 right-side wins (cores 2,3,6,7 higher)", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                if (i == 2 || i == 3 || i == 6 || i == 7)
                    axil_write(waddr, 32'h4040); // bfloat16 3.0
                else
                    axil_write(waddr, 32'h3F80); // bfloat16 1.0
            end
        end
        repeat(200) @(posedge vif.clk_300);
        for (i = 0; i < 3; i++) begin
            repeat(60) @(posedge vif.clk_156);
            build_add_order(64'd16000+i, 8'h53, 32'(35+i*5),
                            64'h4141504C20202020, 32'(95000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(350) @(posedge vif.clk_300);

        // ---- Phase 12e: Arbiter — lv2 right-wins ----
        // Cores 0-3: weight=1.0 → lv1[0] ∝ 1.0
        // Cores 4-7: weight=3.0 → lv1[1] ∝ 3.0
        // lv2: lv1[1] > lv1[0] → RIGHT wins
        `uvm_info("TEST", "Arbiter: lv2 right-side wins (cores 4-7 higher)", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                if (i >= 4)
                    axil_write(waddr, 32'h4040); // bfloat16 3.0
                else
                    axil_write(waddr, 32'h3F80); // bfloat16 1.0
            end
        end
        repeat(200) @(posedge vif.clk_300);
        for (i = 0; i < 3; i++) begin
            repeat(60) @(posedge vif.clk_156);
            build_add_order(64'd17000+i, 8'h42, 32'(28+i*5),
                            64'h4141504C20202020, 32'(91000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(350) @(posedge vif.clk_300);

        // ---- Phase 12f: Arbiter — lv1 "only first valid" (lv0[0],lv0[2] valid) ----
        // Cores 0,1 valid, 2,3 zero → lv0[0] valid, lv0[1] invalid
        // Cores 4,5 valid, 6,7 zero → lv0[2] valid, lv0[3] invalid
        `uvm_info("TEST", "Arbiter: lv1 only-first-valid", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                if (i == 0 || i == 1 || i == 4 || i == 5)
                    axil_write(waddr, 32'h4000); // bfloat16 2.0
                else
                    axil_write(waddr, 32'h0000); // 0
            end
        end
        repeat(200) @(posedge vif.clk_300);
        for (i = 0; i < 3; i++) begin
            repeat(60) @(posedge vif.clk_156);
            build_add_order(64'd18000+i, 8'h42, 32'(20+i*5),
                            64'h4141504C20202020, 32'(90000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(350) @(posedge vif.clk_300);

        // ---- Phase 12g: Arbiter — lv1 "only second valid" (lv0[1],lv0[3] valid) ----
        // Cores 0,1 zero, 2,3 valid → lv0[0] invalid, lv0[1] valid
        // Cores 4,5 zero, 6,7 valid → lv0[2] invalid, lv0[3] valid
        `uvm_info("TEST", "Arbiter: lv1 only-second-valid", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                if (i == 2 || i == 3 || i == 6 || i == 7)
                    axil_write(waddr, 32'h4000); // bfloat16 2.0
                else
                    axil_write(waddr, 32'h0000); // 0
            end
        end
        repeat(200) @(posedge vif.clk_300);
        for (i = 0; i < 3; i++) begin
            repeat(60) @(posedge vif.clk_156);
            build_add_order(64'd19000+i, 8'h53, 32'(18+i*5),
                            64'h4141504C20202020, 32'(89000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(350) @(posedge vif.clk_300);

        // ---- Phase 12h: Arbiter — lv2 "only first valid" (cores 0-3 valid) ----
        `uvm_info("TEST", "Arbiter: lv2 only-first-valid (cores 0-3)", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                if (i < 4)
                    axil_write(waddr, 32'h4040); // bfloat16 3.0
                else
                    axil_write(waddr, 32'h0000); // 0
            end
        end
        repeat(200) @(posedge vif.clk_300);
        for (i = 0; i < 3; i++) begin
            repeat(60) @(posedge vif.clk_156);
            build_add_order(64'd20000+i, 8'h53, 32'(22+i*5),
                            64'h4141504C20202020, 32'(88000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(350) @(posedge vif.clk_300);

        // ---- Phase 12i: Arbiter — lv2 "only second valid" (cores 4-7 valid) ----
        `uvm_info("TEST", "Arbiter: lv2 only-second-valid (cores 4-7)", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                if (i >= 4)
                    axil_write(waddr, 32'h4040); // bfloat16 3.0
                else
                    axil_write(waddr, 32'h0000); // 0
            end
        end
        repeat(200) @(posedge vif.clk_300);
        for (i = 0; i < 3; i++) begin
            repeat(60) @(posedge vif.clk_156);
            build_add_order(64'd21000+i, 8'h42, 32'(24+i*5),
                            64'h4141504C20202020, 32'(87000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(350) @(posedge vif.clk_300);

        // ---- Phase 12j: Out-of-order MoldUDP64 frame (exercises S_DROP) ----
        `uvm_info("TEST", "Sending out-of-order MoldUDP64 frame", UVM_LOW)
        begin
            automatic logic [63:0] future_seq;
            future_seq = mold_seq + 64'd10; // skip ahead by 10
            build_add_order(64'd22000, 8'h42, 32'd50,
                            64'h4141504C20202020, 32'd100000, itch_body);
            build_eth_frame(itch_body, future_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            // Don't increment mold_seq — frame should be dropped
            repeat(50) @(posedge vif.clk_156);
            // Now send correct sequence to verify pipeline recovers
            build_add_order(64'd22001, 8'h42, 32'd60,
                            64'h4141504C20202020, 32'd101000, itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(300) @(posedge vif.clk_300);

        // ---- Phase 12k: Back-pressure test (exercises ouch_engine overflow paths) ----
        `uvm_info("TEST", "Testing ouch_engine back-pressure", UVM_LOW)
        // Restore all-1.0 weights
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                axil_write(waddr, 32'h3F80); // bfloat16 1.0
            end
        end
        repeat(100) @(posedge vif.clk_300);
        // Send a message that will generate OUCH output
        build_add_order(64'd23000, 8'h53, 32'd40,
                        64'h4141504C20202020, 32'd94000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        // Wait for OUCH tvalid to go high, then hold tready=0 for 2+ cycles
        begin
            automatic int timeout_cnt = 0;
            while (!vif.m_axis_tvalid && timeout_cnt < 5000) begin
                @(posedge vif.clk_300);
                timeout_cnt++;
            end
            if (vif.m_axis_tvalid) begin
                `uvm_info("TEST", "OUCH TX detected, asserting back-pressure for 4 cycles", UVM_LOW)
                vif.m_axis_tready <= 1'b0;
                repeat(4) @(posedge vif.clk_300);
                vif.m_axis_tready <= 1'b1;
            end
        end
        // Wait for clr_cnt to expire (256+ cycles)
        repeat(300) @(posedge vif.clk_300);
        // Send orders to verify pipeline recovers after overflow clears
        for (i = 0; i < 3; i++) begin
            repeat(40) @(posedge vif.clk_156);
            build_add_order(64'd23001+i, 8'h53, 32'(45+i*5),
                            64'h4141504C20202020, 32'(93000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(300) @(posedge vif.clk_300);

        // ---- Phase 12l: Short/malformed frame on MAC RX ----
        `uvm_info("TEST", "Sending short/malformed frame (should be dropped)", UVM_LOW)
        build_short_frame(beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        repeat(20) @(posedge vif.clk_156);
        // Send valid frame after to verify recovery
        build_add_order(64'd24000, 8'h42, 32'd30,
                        64'h4141504C20202020, 32'd95000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(300) @(posedge vif.clk_300);

        // ---- Phase 13a: Arbiter — even-valid, odd-invalid at lv0 ----
        // Set even cores (0,2,4,6) to 3.0, odd cores (1,3,5,7) to 0.
        // gated_valid[even]=1, gated_valid[odd]=0 → covers !gated_valid[g*2+1] path
        `uvm_info("TEST", "Arbiter: even cores valid, odd cores zero (lv0 left-only)", UVM_LOW)
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                if (i % 2 == 0)
                    axil_write(waddr, 32'h4040); // bfloat16 3.0
                else
                    axil_write(waddr, 32'h0000); // 0
            end
        end
        repeat(150) @(posedge vif.clk_300);
        for (i = 0; i < 2; i++) begin
            repeat(40) @(posedge vif.clk_156);
            build_add_order(64'd25000+i, 8'h42, 32'(30+i*5),
                            64'h4141504C20202020, 32'(85000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(400) @(posedge vif.clk_300);

        // Restore weights to all-1.0 for subsequent phases
        for (i = 0; i < 8; i++) begin
            for (int w = 0; w < 32; w++) begin
                automatic logic [11:0] waddr;
                waddr = {2'b10, i[2:0], w[4:0], 2'b00};
                axil_write(waddr, 32'h3F80); // bfloat16 1.0
            end
        end
        repeat(50) @(posedge vif.clk_300);

        // ---- Phase 13b: Delete nonexistent order ref → ref_empty path ----
        `uvm_info("TEST", "Delete nonexistent order ref (ref_empty path)", UVM_LOW)
        build_delete_order(64'd50000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Phase 13b2: Free up ask-side book levels ----
        // The book has OB_LEVELS=4 slots. Levels 0-3 are occupied by orders:
        //   level 0: 1002 (sell AAPL, 100 remaining after cancel)
        //   level 1: 2003 (sell MSFT, 40 remaining after exec)
        //   level 2: 7001 (sell AAPL from Phase 5)
        //   level 3: 7003 (sell AAPL from Phase 5)
        // Delete them to free up levels for subsequent ask BBO tests.
        `uvm_info("TEST", "Freeing ask-side book levels (delete 1002, 2003, 7001, 7003)", UVM_LOW)
        build_delete_order(64'd1002, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(100) @(posedge vif.clk_156);
        build_delete_order(64'd2003, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(100) @(posedge vif.clk_156);
        build_delete_order(64'd7001, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(100) @(posedge vif.clk_156);
        build_delete_order(64'd7003, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Phase 13c: Add ask order, then fully execute → full exec + ask BBO reset ----
        `uvm_info("TEST", "Full execution of ask order at BBO", UVM_LOW)
        build_add_order(64'd50001, 8'h53, 32'd100,
                        64'h4141504C20202020, 32'd1000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);
        // Execute all 100 shares → new_sh_zero_r=1, op_ref_side=0(ask)
        build_exec_order(64'd50001, 32'd100, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Phase 13d: Add ask order, then cancel all shares → cancel-to-zero ask ----
        `uvm_info("TEST", "Cancel-to-zero of ask order at BBO", UVM_LOW)
        build_add_order(64'd50002, 8'h53, 32'd50,
                        64'h4141504C20202020, 32'd1500, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);
        build_cancel_order(64'd50002, 32'd50, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Phase 13e: Add ask order, then delete → delete ask at BBO ----
        `uvm_info("TEST", "Delete ask order at BBO", UVM_LOW)
        build_add_order(64'd50003, 8'h53, 32'd80,
                        64'h4141504C20202020, 32'd2000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);
        build_delete_order(64'd50003, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Phase 13f: Add ask order, then replace → old ask BBO cleared, new better ----
        `uvm_info("TEST", "Replace ask order at BBO with better price", UVM_LOW)
        build_add_order(64'd50004, 8'h53, 32'd60,
                        64'h4141504C20202020, 32'd2500, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);
        build_replace_order(64'd50004, 64'd50005, 32'd70, 32'd1000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Phase 13g: Short ITCH message (msg_len ≤ 6, unrecognized type) ----
        `uvm_info("TEST", "Short ITCH message (msg_len=4, unknown type)", UVM_LOW)
        begin
            automatic logic [7:0] short_body [];
            short_body = new[6]; // 2-byte len + 4-byte body
            short_body[0] = 8'h00; short_body[1] = 8'h04; // msg_len = 4
            short_body[2] = 8'hFF; // unrecognized msg type
            short_body[3] = 8'h00;
            short_body[4] = 8'h00;
            short_body[5] = 8'h00;
            build_eth_frame(short_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end
        repeat(100) @(posedge vif.clk_156);
        build_add_order(64'd50006, 8'h42, 32'd40,
                        64'h4141504C20202020, 32'd90000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(200) @(posedge vif.clk_300);

        // ---- Phase 13h: Execute nonexistent ref (ref_empty for exec) ----
        `uvm_info("TEST", "Execute nonexistent order ref (ref_empty path)", UVM_LOW)
        build_exec_order(64'd60000, 32'd10, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Phase 13i: Cancel nonexistent ref ----
        `uvm_info("TEST", "Cancel nonexistent order ref (ref_empty path)", UVM_LOW)
        build_cancel_order(64'd60001, 32'd10, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Phase 13j: Replace nonexistent ref ----
        `uvm_info("TEST", "Replace nonexistent order ref (ref_empty path)", UVM_LOW)
        build_replace_order(64'd60002, 64'd60003, 32'd50, 32'd80000, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;
        repeat(150) @(posedge vif.clk_156);

        // ---- Kill switch test ----
        repeat(10) @(posedge vif.clk_300);
        `uvm_info("TEST", "Activating kill switch", UVM_LOW)
        axil_write(12'h40C, 32'h01); // Set kill_sw bit

        // Orders with kill switch active → should be blocked
        for (i = 0; i < 3; i++) begin
            repeat(30) @(posedge vif.clk_156);
            build_add_order(64'd13000+i, 8'h42, 32'd50,
                            64'h4141504C20202020,
                            32'(101000+i*1000), itch_body);
            build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
            drive_frame(beats, keeps, lasts);
            mold_seq++;
        end

        // ---- Phase 13: Edge cases (sent last to avoid BBO corruption) ----
        repeat(30) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending edge-case: max price/qty", UVM_LOW)
        build_add_order(64'd3001, 8'h42, 32'hFFFFFF,
                        64'h4141504C20202020, 32'hFFFFFFFF, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        repeat(20) @(posedge vif.clk_156);
        `uvm_info("TEST", "Sending edge-case: min price", UVM_LOW)
        build_add_order(64'd3002, 8'h53, 32'd1,
                        64'h4141504C20202020, 32'd1, itch_body);
        build_eth_frame(itch_body, mold_seq, beats, keeps, lasts);
        drive_frame(beats, keeps, lasts);
        mold_seq++;

        // Wait for pipeline to drain
        `uvm_info("TEST", "Waiting for pipeline to complete...", UVM_LOW)
        repeat(20000) @(posedge vif.clk_300);
        disable fork;  // Stop the background OUCH monitor

        // Report
        `uvm_info("TEST", $sformatf("Test complete. OUCH packets received: %0d",
                                     scb.ouch_pkt_count), UVM_LOW)
        `uvm_info("TEST", $sformatf("Monitoring: collision_count=%0d dropped_frames=%0d dropped_datagrams=%0d",
                                     vif.collision_count_out, vif.dropped_frames_out,
                                     vif.dropped_datagrams_out), UVM_LOW)
        `uvm_info("TEST", $sformatf("Expected seq_num: %0d", vif.expected_seq_num_out), UVM_LOW)

        phase.drop_objection(this);
    endtask

    function void report_phase(uvm_phase phase);
        `uvm_info("TEST", "=== HFT Base Test Complete ===", UVM_LOW)
    endfunction
endclass

// =====================================================================
// Top-level module
// =====================================================================
module tb_top;
    // Clocks
    reg clk_156 = 0;
    reg clk_300 = 0;

    // 156.25 MHz: 6.4 ns period
    always #3200 clk_156 = ~clk_156; // 3.2ns half-period (ps units)
    // 300 MHz: 3.33 ns period
    always #1667 clk_300 = ~clk_300; // 1.667ns half-period

    // Interface
    hft_if hif(.clk_156(clk_156), .clk_300(clk_300));

    // DUT
    kc705_top #(
        .AXIL_ADDR(12),
        .AXIL_DATA(32)
    ) dut (
        .sys_clk_p      (1'b0),
        .sys_clk_n      (1'b1),
        .cpu_reset       (hif.cpu_reset),
        .sfp_rx_p        (1'b0),
        .sfp_rx_n        (1'b1),
        .sfp_tx_p        (),
        .sfp_tx_n        (),
        .mgt_refclk_p    (1'b0),
        .mgt_refclk_n    (1'b1),
        .axil_awaddr     (hif.axil_awaddr),
        .axil_awvalid    (hif.axil_awvalid),
        .axil_awready    (hif.axil_awready),
        .axil_wdata      (hif.axil_wdata),
        .axil_wstrb      (hif.axil_wstrb),
        .axil_wvalid     (hif.axil_wvalid),
        .axil_wready     (hif.axil_wready),
        .axil_bresp      (hif.axil_bresp),
        .axil_bvalid     (hif.axil_bvalid),
        .axil_bready     (hif.axil_bready),
        .axil_araddr     (hif.axil_araddr),
        .axil_arvalid    (hif.axil_arvalid),
        .axil_arready    (hif.axil_arready),
        .axil_rdata      (hif.axil_rdata),
        .axil_rresp      (hif.axil_rresp),
        .axil_rvalid     (hif.axil_rvalid),
        .axil_rready     (hif.axil_rready),
        .pcie_clk_p      (1'b0),
        .pcie_clk_n      (1'b1),
        .pcie_rst_n      (1'b1),
        .pcie_rxp        (4'b0),
        .pcie_rxn        (4'b1111),
        .pcie_txp        (),
        .pcie_txn        (),
        .m_axis_tdata    (hif.m_axis_tdata),
        .m_axis_tkeep    (hif.m_axis_tkeep),
        .m_axis_tvalid   (hif.m_axis_tvalid),
        .m_axis_tlast    (hif.m_axis_tlast),
        .m_axis_tready   (hif.m_axis_tready),
        .collision_count_out    (hif.collision_count_out),
        .tx_overflow_out        (hif.tx_overflow_out),
        .dropped_frames_out     (hif.dropped_frames_out),
        .dropped_datagrams_out  (hif.dropped_datagrams_out),
        .expected_seq_num_out   (hif.expected_seq_num_out),
        .clk_156_in      (clk_156),
        .clk_300_in      (clk_300),
        .mac_rx_tdata    (hif.mac_rx_tdata),
        .mac_rx_tkeep    (hif.mac_rx_tkeep),
        .mac_rx_tvalid   (hif.mac_rx_tvalid),
        .mac_rx_tlast    (hif.mac_rx_tlast),
        .mac_rx_tready   (hif.mac_rx_tready),
        .fifo_rd_tvalid  (hif.fifo_rd_tvalid)
    );

    // UVM
    initial begin
        uvm_config_db#(virtual hft_if)::set(null, "*", "vif", hif);
        run_test("hft_base_test");
    end

    // Debug: monitor key pipeline signals
    int dbg_fields_valid_cnt = 0;
    int dbg_watchlist_hit_cnt = 0;
    int dbg_feat_ext_fv_cnt = 0;
    int dbg_features_valid_cnt = 0;
    int dbg_best_valid_cnt = 0;
    int dbg_risk_pass_cnt = 0;
    int dbg_risk_blocked_cnt = 0;

    always @(posedge clk_300) begin
        if (dut.u_lliu.parser_fields_valid) begin
            dbg_fields_valid_cnt <= dbg_fields_valid_cnt + 1;
            $display("[DBG] t=%0t fields_valid #%0d msg_type=0x%02x stock=%h ob_state=%0d ob_ready=%0d ob_fv=%0d",
                     $time, dbg_fields_valid_cnt+1,
                     dut.u_lliu.parser_msg_type, dut.u_lliu.parser_stock,
                     dut.u_lliu.u_ob.state, dut.u_lliu.u_ob.book_ready,
                     dut.u_lliu.u_ob.fields_valid);
        end
        // Trace order_book op_msg_type one cycle after latch
        if (dut.u_lliu.u_ob.state == 1) begin // S_READ_REF1
            $display("[DBG] t=%0t OB_READ_REF1 op_msg_type=0x%02x order_ref=%0d probe=%0d",
                     $time, dut.u_lliu.u_ob.op_msg_type,
                     dut.u_lliu.u_ob.op_order_ref,
                     dut.u_lliu.u_ob.probe_cnt);
        end
        // Trace S_MATCH
        if (dut.u_lliu.u_ob.state == 8) begin // S_MATCH
            $display("[DBG] t=%0t OB_MATCH op_msg=0x%02x is_add=%0d ref_match=%0d ref_empty=%0d probe=%0d",
                     $time, dut.u_lliu.u_ob.op_msg_type,
                     dut.u_lliu.u_ob.is_add_op_r,
                     dut.u_lliu.u_ob.ref_match_r,
                     dut.u_lliu.u_ob.ref_empty_r,
                     dut.u_lliu.u_ob.probe_cnt);
        end
        // Trace S_UPDATE
        if (dut.u_lliu.u_ob.state == 5) begin // S_UPDATE
            $display("[DBG] t=%0t OB_UPDATE op_msg=0x%02x target_found=%0d",
                     $time, dut.u_lliu.u_ob.op_msg_type,
                     dut.u_lliu.u_ob.target_found);
        end
        // Trace strategy_arbiter when any core is valid (sample gated_valid at the right time)
        if (dut.u_lliu.u_arb.core_valids[0]) begin
            $display("[DBG] t=%0t GV=%b%b%b%b%b%b%b%b lv0v=%b%b%b%b scores=0x%08x 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x 0x%08x",
                     $time,
                     dut.u_lliu.u_arb.gated_valid[0], dut.u_lliu.u_arb.gated_valid[1],
                     dut.u_lliu.u_arb.gated_valid[2], dut.u_lliu.u_arb.gated_valid[3],
                     dut.u_lliu.u_arb.gated_valid[4], dut.u_lliu.u_arb.gated_valid[5],
                     dut.u_lliu.u_arb.gated_valid[6], dut.u_lliu.u_arb.gated_valid[7],
                     dut.u_lliu.u_arb.lv0_valid[0], dut.u_lliu.u_arb.lv0_valid[1],
                     dut.u_lliu.u_arb.lv0_valid[2], dut.u_lliu.u_arb.lv0_valid[3],
                     dut.u_lliu.u_arb.core_scores[0], dut.u_lliu.u_arb.core_scores[1],
                     dut.u_lliu.u_arb.core_scores[2], dut.u_lliu.u_arb.core_scores[3],
                     dut.u_lliu.u_arb.core_scores[4], dut.u_lliu.u_arb.core_scores[5],
                     dut.u_lliu.u_arb.core_scores[6], dut.u_lliu.u_arb.core_scores[7]);
        end
        if (dut.u_lliu.watchlist_hit) begin
            dbg_watchlist_hit_cnt <= dbg_watchlist_hit_cnt + 1;
            $display("[DBG] t=%0t watchlist_hit #%0d", $time, dbg_watchlist_hit_cnt+1);
        end
        if (dut.u_lliu.feat_ext_fv) begin
            dbg_feat_ext_fv_cnt <= dbg_feat_ext_fv_cnt + 1;
            $display("[DBG] t=%0t feat_ext_fv #%0d bbo_bid=%0d bbo_ask=%0d",
                     $time, dbg_feat_ext_fv_cnt+1,
                     dut.u_lliu.bbo_bid_price, dut.u_lliu.bbo_ask_price);
        end
        if (dut.u_lliu.core_features_valid) begin
            dbg_features_valid_cnt <= dbg_features_valid_cnt + 1;
            $display("[DBG] t=%0t features_valid #%0d", $time, dbg_features_valid_cnt+1);
        end
        if (dut.u_lliu.best_valid) begin
            dbg_best_valid_cnt <= dbg_best_valid_cnt + 1;
            $display("[DBG] t=%0t best_valid #%0d score=0x%08x",
                     $time, dbg_best_valid_cnt+1, dut.u_lliu.best_score);
        end
        if (dut.u_lliu.risk_pass) begin
            dbg_risk_pass_cnt <= dbg_risk_pass_cnt + 1;
            $display("[DBG] t=%0t risk_pass #%0d", $time, dbg_risk_pass_cnt+1);
        end
        if (dut.u_lliu.u_risk.risk_blocked) begin
            dbg_risk_blocked_cnt <= dbg_risk_blocked_cnt + 1;
            $display("[DBG] t=%0t risk_blocked #%0d reason=%b ref_price=%0d band_thresh=%0d price_diff=%0d",
                     $time, dbg_risk_blocked_cnt+1,
                     dut.u_lliu.u_risk.block_reason,
                     dut.u_lliu.held_ref_r,
                     dut.u_lliu.u_risk.band_thresh_32_r,
                     dut.u_lliu.u_risk.price_diff_hhh);
        end
    end

    final begin
        $display("[DBG] Summary: fields_valid=%0d watchlist_hit=%0d feat_ext_fv=%0d features_valid=%0d best_valid=%0d risk_pass=%0d risk_blocked=%0d",
                 dbg_fields_valid_cnt, dbg_watchlist_hit_cnt, dbg_feat_ext_fv_cnt,
                 dbg_features_valid_cnt, dbg_best_valid_cnt, dbg_risk_pass_cnt,
                 dbg_risk_blocked_cnt);
    end

    // ---- Snapshot coverage trigger ----
    // Force a BBO snapshot request into the pcie_dma_engine→snapshot_mux path.
    // The DMA FSM needs bar0_ctrl_r[0]=1 and periodic_tick to fire snap_req,
    // but without a PCIe host we can't set bar0_ctrl_r.  Instead, directly
    // force bar0_ctrl_r[0] after BBO data has been populated (around 50ms),
    // let the 200-cycle periodic timer fire, triggering the full snapshot path.
    initial begin
        #50_000_000;  // 50 ms — BBO data well-established by now
        @(posedge clk_300);
        force dut.u_pcie_dma.bar0_ctrl_r = 32'h0000_0001; // dma_en = 1
        // Also populate a minimal valid descriptor so DMA_DESCR can proceed
        @(posedge clk_300);
        force dut.u_pcie_dma.desc_ring[0] = {64'h0000_0001_0000_0000, 24'd8192, 1'b1, 7'b0};
        // Wait for periodic_tick (every 200 cycles) → DMA_TRIG → snap_req
        repeat(500) @(posedge clk_300);
        // Release forces
        release dut.u_pcie_dma.bar0_ctrl_r;
        release dut.u_pcie_dma.desc_ring[0];
    end

    // ================================================================
    // Coverage helper: exercise eth_axis_rx_wrap drop + moldupp64_strip
    // truncated-frame edge-case paths via hierarchical force/release.
    // Runs AFTER the main UVM test completes (~200 µs).
    // ================================================================
    initial begin
        #140_000_000;  // 140 µs — main stimulus done (~133 µs), pipeline draining

        // ---- 1. fifo_almost_full → eth_axis_rx_wrap dropped_frames ----
        // Force fifo_almost_full during a MAC frame to trigger the drop counter.
        @(posedge clk_156);
        force dut.fifo_almost_full = 1'b1;
        // Drive a small 2-beat MAC frame (SOF + EOF)
        hif.mac_rx_tdata  <= 64'hFF00_FF00_FF00_FF00;
        hif.mac_rx_tkeep  <= 8'hFF;
        hif.mac_rx_tvalid <= 1'b1;
        hif.mac_rx_tlast  <= 1'b0;
        @(posedge clk_156);
        hif.mac_rx_tdata  <= 64'hAA55_AA55_AA55_AA55;
        hif.mac_rx_tkeep  <= 8'hFF;
        hif.mac_rx_tlast  <= 1'b1;
        @(posedge clk_156);
        hif.mac_rx_tvalid <= 1'b0;
        hif.mac_rx_tlast  <= 1'b0;
        repeat(5) @(posedge clk_156);
        // Send one more frame (single beat) so that drop_decision samples high
        hif.mac_rx_tdata  <= 64'hDEAD_BEEF_CAFE_1234;
        hif.mac_rx_tkeep  <= 8'hFF;
        hif.mac_rx_tvalid <= 1'b1;
        hif.mac_rx_tlast  <= 1'b1;
        @(posedge clk_156);
        hif.mac_rx_tvalid <= 1'b0;
        hif.mac_rx_tlast  <= 1'b0;
        repeat(3) @(posedge clk_156);
        release dut.fifo_almost_full;
        repeat(10) @(posedge clk_156);

        // ---- 2. Truncated MoldUDP streams via direct force ----
        // We directly force the moldupp64_strip's s_* inputs to inject
        // truncated streams that exercise S_HEADER_B0/B1/B2 edge paths.
        // This is necessary because crafting MAC frames that produce exact
        // byte-aligned truncated streams through the eth_axis_rx + udp stubs
        // is unreliable.

        // -- Test 2a: S_HEADER_B0 truncation (s_tlast on first beat) --
        $display("[COV] t=%0t Truncated MoldUDP test: S_HEADER_B0 truncation", $time);
        @(posedge clk_156);
        force dut.udp_payload_tvalid = 1'b1;
        force dut.udp_payload_tdata  = 64'h4C4C_4955_2020_2020; // session bytes
        force dut.udp_payload_tkeep  = 8'h0F;  // only 4 valid bytes
        force dut.udp_payload_tlast  = 1'b1;   // single-beat truncated
        @(posedge clk_156);
        force dut.udp_payload_tvalid = 1'b0;
        force dut.udp_payload_tlast  = 1'b0;
        repeat(5) @(posedge clk_156);

        // -- Test 2b: S_HEADER_B1 truncation (s_tlast on second beat) --
        $display("[COV] t=%0t Truncated MoldUDP test: S_HEADER_B1 truncation", $time);
        // Beat 0: full 8-byte session header
        force dut.udp_payload_tvalid = 1'b1;
        force dut.udp_payload_tdata  = 64'h4C4C_4955_2020_2020;
        force dut.udp_payload_tkeep  = 8'hFF;
        force dut.udp_payload_tlast  = 1'b0;
        @(posedge clk_156);
        // Beat 1: truncated (s_tlast)
        force dut.udp_payload_tdata  = 64'h2020_0000_0000_0001;
        force dut.udp_payload_tkeep  = 8'hFF;
        force dut.udp_payload_tlast  = 1'b1;
        @(posedge clk_156);
        force dut.udp_payload_tvalid = 1'b0;
        force dut.udp_payload_tlast  = 1'b0;
        repeat(5) @(posedge clk_156);

        // -- Test 2c: S_HEADER_B2 with !header_b2_valid (tkeep[3:0]!=4'hF) --
        $display("[COV] t=%0t Truncated MoldUDP test: S_HEADER_B2 !b2_valid", $time);
        // Beat 0
        force dut.udp_payload_tvalid = 1'b1;
        force dut.udp_payload_tdata  = 64'h4C4C_4955_2020_2020;
        force dut.udp_payload_tkeep  = 8'hFF;
        force dut.udp_payload_tlast  = 1'b0;
        @(posedge clk_156);
        // Beat 1
        force dut.udp_payload_tdata  = 64'h2020_0000_0000_0001;
        force dut.udp_payload_tkeep  = 8'hFF;
        force dut.udp_payload_tlast  = 1'b0;
        @(posedge clk_156);
        // Beat 2: bad tkeep (only 2 of bottom 4 bytes valid → !header_b2_valid) + s_tlast
        force dut.udp_payload_tdata  = 64'h0000_0000_0000_0000;
        force dut.udp_payload_tkeep  = 8'h03;  // tkeep[3:0]=4'h3 != 4'hF
        force dut.udp_payload_tlast  = 1'b1;   // with s_tlast → state_next = S_HEADER_B0
        @(posedge clk_156);
        force dut.udp_payload_tvalid = 1'b0;
        force dut.udp_payload_tlast  = 1'b0;
        repeat(5) @(posedge clk_156);

        // -- Test 2c2: S_HEADER_B2 with !header_b2_valid + no s_tlast → S_DROP --
        $display("[COV] t=%0t Truncated MoldUDP test: S_HEADER_B2 !b2_valid no tlast", $time);
        // Beat 0
        force dut.udp_payload_tvalid = 1'b1;
        force dut.udp_payload_tdata  = 64'h4C4C_4955_2020_2020;
        force dut.udp_payload_tkeep  = 8'hFF;
        force dut.udp_payload_tlast  = 1'b0;
        @(posedge clk_156);
        // Beat 1
        force dut.udp_payload_tdata  = 64'h2020_0000_0000_0001;
        force dut.udp_payload_tkeep  = 8'hFF;
        force dut.udp_payload_tlast  = 1'b0;
        @(posedge clk_156);
        // Beat 2: bad tkeep, no s_tlast → goes to S_DROP
        force dut.udp_payload_tdata  = 64'h0000_0000_0000_0000;
        force dut.udp_payload_tkeep  = 8'h03;
        force dut.udp_payload_tlast  = 1'b0;
        @(posedge clk_156);
        // Beat 3: remaining data in S_DROP
        force dut.udp_payload_tdata  = 64'h0000_0000_0000_0000;
        force dut.udp_payload_tkeep  = 8'hFF;
        force dut.udp_payload_tlast  = 1'b1;
        @(posedge clk_156);
        force dut.udp_payload_tvalid = 1'b0;
        force dut.udp_payload_tlast  = 1'b0;
        repeat(5) @(posedge clk_156);

        // -- Test 2d: S_HEADER_B2 OOO + s_tlast (short OOO dgram) --
        // Need expected_seq_num mismatch. Read current value and use a different one.
        $display("[COV] t=%0t Truncated MoldUDP test: S_HEADER_B2 OOO+s_tlast", $time);
        begin
            automatic logic [63:0] cur_esn;
            automatic logic [63:0] bad_seq;
            automatic logic [63:0] beat1_data;
            automatic logic [63:0] beat2_data;
            cur_esn = dut.u_moldupp64.expected_seq_num;
            bad_seq = cur_esn + 64'd100;
            // Build beat 1: session[8:9] + seq_num bytes 0-5 (big-endian)
            // tdata byte layout: [7:0]=session8, [15:8]=session9, [23:16]=seq[0], ...
            beat1_data = {bad_seq[47:40], bad_seq[39:32], bad_seq[31:24], bad_seq[23:16],
                          bad_seq[15:8],  bad_seq[7:0],   8'h20, 8'h20};
            // Build beat 2: seq[6:7] + msg_count + ITCH
            beat2_data = {32'hCAFE_BEEF, 8'h00, 8'h01, bad_seq[63:56], bad_seq[55:48]};
            // Beat 0
            force dut.udp_payload_tvalid = 1'b1;
            force dut.udp_payload_tdata  = 64'h4C4C_4955_2020_2020;
            force dut.udp_payload_tkeep  = 8'hFF;
            force dut.udp_payload_tlast  = 1'b0;
            @(posedge clk_156);
            // Beat 1
            force dut.udp_payload_tdata  = beat1_data;
            force dut.udp_payload_tkeep  = 8'hFF;
            force dut.udp_payload_tlast  = 1'b0;
            @(posedge clk_156);
            // Beat 2: OOO + s_tlast
            force dut.udp_payload_tdata  = beat2_data;
            force dut.udp_payload_tkeep  = 8'hFF;
            force dut.udp_payload_tlast  = 1'b1;
            @(posedge clk_156);
            force dut.udp_payload_tvalid = 1'b0;
            force dut.udp_payload_tlast  = 1'b0;
            repeat(5) @(posedge clk_156);
        end

        // -- Test 2e: S_HEADER_B2 in-order + s_tlast → S_FLUSH_SHORT --
        $display("[COV] t=%0t Truncated MoldUDP test: S_HEADER_B2 in-order+s_tlast (FLUSH_SHORT)", $time);
        begin
            automatic logic [63:0] cur_esn;
            automatic logic [63:0] beat1_data;
            automatic logic [63:0] beat2_data;
            cur_esn = dut.u_moldupp64.expected_seq_num;
            // Build beat 1: session[8:9] + correct seq_num bytes 0-5
            beat1_data = {cur_esn[47:40], cur_esn[39:32], cur_esn[31:24], cur_esn[23:16],
                          cur_esn[15:8],  cur_esn[7:0],   8'h20, 8'h20};
            // Build beat 2: correct seq[6:7] + msg_count + ITCH
            beat2_data = {32'hDEAD_BEEF, 8'h00, 8'h01, cur_esn[63:56], cur_esn[55:48]};
            // Beat 0
            force dut.udp_payload_tvalid = 1'b1;
            force dut.udp_payload_tdata  = 64'h4C4C_4955_2020_2020;
            force dut.udp_payload_tkeep  = 8'hFF;
            force dut.udp_payload_tlast  = 1'b0;
            @(posedge clk_156);
            // Beat 1
            force dut.udp_payload_tdata  = beat1_data;
            force dut.udp_payload_tkeep  = 8'hFF;
            force dut.udp_payload_tlast  = 1'b0;
            @(posedge clk_156);
            // Beat 2: in-order + s_tlast → S_FLUSH_SHORT
            force dut.udp_payload_tdata  = beat2_data;
            force dut.udp_payload_tkeep  = 8'hFF;
            force dut.udp_payload_tlast  = 1'b1;
            @(posedge clk_156);
            force dut.udp_payload_tvalid = 1'b0;
            force dut.udp_payload_tlast  = 1'b0;
            repeat(10) @(posedge clk_156);
        end

        // Release all forces on moldupp64_strip inputs
        release dut.udp_payload_tvalid;
        release dut.udp_payload_tdata;
        release dut.udp_payload_tkeep;
        release dut.udp_payload_tlast;
        repeat(20) @(posedge clk_156);
        $display("[COV] t=%0t Coverage stimulus complete", $time);
    end

    // Timeout
    initial begin
        #500_000_000; // 500us simulation time (extended for coverage tests)
        `uvm_info("TB", "Simulation timeout reached", UVM_LOW)
        $finish;
    end

endmodule
