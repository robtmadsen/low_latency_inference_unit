// risk_fuzz_seq.sv — Constrained-random risk-check fuzz sequence
//
// DUT target: kc705_top (KINTEX7_SIM_GTX_BYPASS)
// Spec ref:   .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.6, §4.10
//
// This sequence exercises all three structural risk-check boundaries:
//   1. Price band (BAND_BPS): |proposed_price − bbo_mid| > BAND_BPS × bbo_mid / 10000
//   2. Fat-finger (MAX_QTY):  proposed_shares > MAX_QTY
//   3. Kill switch (CTRL):    bit[2] of CTRL register (write-once-to-arm)
//
// For each OOB case the sequence verifies that m_axis_tvalid never asserts
// within BLOCK_WINDOW cycles.  For in-band cases it verifies that
// m_axis_tvalid *does* assert within PASS_WINDOW cycles.
//
// The caller must:
//   1. Run kc705_init_seq first (watchlist must include the test symbols).
//   2. Pass kc705_vif (virtual kc705_ctrl_if) via the field.
//   3. Run this sequence on m_axil_agent.m_sequencer.
//
// Usage:
//   risk_fuzz_seq rf_seq;
//   rf_seq = risk_fuzz_seq::type_id::create("rf_seq");
//   rf_seq.kc705_vif = kc705_vif;
//   rf_seq.m_axis_agent_sqr = m_env.m_axis_agent.m_sequencer;
//   rf_seq.start(m_env.m_axil_agent.m_sequencer);

typedef byte unsigned byte_darr_t   [];  // may already exist in kc705_test
typedef bit [63:0]    qword_darr_t  [];  // ditto

class risk_fuzz_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(risk_fuzz_seq)

    // ── Handles ────────────────────────────────────────────────────
    virtual kc705_ctrl_if              kc705_vif;
    uvm_sequencer #(axi4_stream_transaction) m_axis_agent_sqr;

    // ── AXI4-Lite register addresses (MAS §4.10) ───────────────────
    localparam bit [31:0] REG_CTRL       = 32'h000;
    localparam bit [31:0] REG_BAND_BPS   = 32'h400;
    localparam bit [31:0] REG_MAX_QTY    = 32'h404;
    localparam bit [31:0] REG_SCORE_THR  = 32'h408;

    // ── Kill-switch control bit (MAS §4.10 CTRL register) ──────────
    localparam bit [31:0] CTRL_KILL_BIT  = 32'h4;   // bit[2]

    // ── Observation windows (cycles) ───────────────────────────────
    localparam int BLOCK_WINDOW = 200;   // no tvalid expected (OOB)
    localparam int PASS_WINDOW  = 300;   // tvalid expected (in-band)

    // ── Default risk thresholds ─────────────────────────────────────
    // BAND_BPS = 10  →  ±0.10% band around BBO mid
    // MAX_QTY  = 1000 shares fat-finger limit
    // SCORE_THR = 0   →  any score fires (threshold off in sim)
    int unsigned band_bps = 10;
    int unsigned max_qty  = 1000;

    // ── Symbols (must match kc705_init_seq watchlist) ──────────────
    // Default watchlist must contain "AAPL    "
    byte unsigned aapl_sym[8] = '{8'h41,8'h41,8'h50,8'h4C,8'h20,8'h20,8'h20,8'h20};

    // ── BBO mid price for band tests (ITCH price × 10000 = cents×10000) ──
    // ITCH price field is in units of 10^-4 dollars (i.e. multiplied by 10000).
    // bbo_mid_f4 = 1_500_000 → $150.00
    int unsigned bbo_mid_f4 = 1_500_000;

    // ── Metrics ────────────────────────────────────────────────────
    int unsigned oob_blocked   = 0;   // out-of-band orders correctly blocked
    int unsigned oob_leaked    = 0;   // ERROR: out-of-band orders that passed
    int unsigned inband_passed = 0;   // in-band orders correctly processed
    int unsigned inband_missed = 0;   // ERROR: in-band orders that were blocked

    function new(string name = "risk_fuzz_seq");
        super.new(name);
    endfunction

    // ── AXI4-Lite helpers ──────────────────────────────────────────
    task axil_write(bit [31:0] addr, bit [31:0] data);
        axi4_lite_transaction tx;
        tx = axi4_lite_transaction::type_id::create("tx");
        start_item(tx);
        tx.is_write = 1'b1;
        tx.addr     = addr;
        tx.data     = data;
        tx.wstrb    = 4'hF;
        finish_item(tx);
    endtask

    // ── Frame-building helpers (duplicated from lliu_kc705_test) ───
    // These build ITCH Add Order (36 bytes) inside a full Ethernet/IPv4/UDP/MoldUDP64 frame.

    function automatic void _make_add_order(
        ref    byte_darr_t      msg,
        input  byte unsigned    side,
        input  int unsigned     qty,
        input  byte unsigned    symbol[8],
        input  int unsigned     price_f4,
        input  longint unsigned order_ref = 1
    );
        msg = new[36];
        msg[0]  = 8'h41;
        // timestamps (bytes 1-10): zero
        msg[1]  = 8'h00; msg[2]  = 8'h00; msg[3]  = 8'h00; msg[4]  = 8'h00;
        msg[5]  = 8'h00; msg[6]  = 8'h00; msg[7]  = 8'h00; msg[8]  = 8'h00;
        msg[9]  = 8'h00; msg[10] = 8'h00;
        // order reference (bytes 11-18)
        msg[11] = order_ref[63:56]; msg[12] = order_ref[55:48];
        msg[13] = order_ref[47:40]; msg[14] = order_ref[39:32];
        msg[15] = order_ref[31:24]; msg[16] = order_ref[23:16];
        msg[17] = order_ref[15:8];  msg[18] = order_ref[7:0];
        msg[19] = side;
        msg[20] = qty[31:24]; msg[21] = qty[23:16];
        msg[22] = qty[15:8];  msg[23] = qty[7:0];
        for (int i = 0; i < 8; i++) msg[24+i] = symbol[i];
        msg[32] = price_f4[31:24]; msg[33] = price_f4[23:16];
        msg[34] = price_f4[15:8];  msg[35] = price_f4[7:0];
    endfunction

    function automatic bit [15:0] _ip_checksum(byte unsigned hdr[]);
        bit [31:0] acc = 32'h0;
        for (int i = 0; i < hdr.size(); i += 2)
            acc += {hdr[i], hdr[i+1]};
        while (acc[31:16]) acc = acc[15:0] + acc[31:16];
        return ~acc[15:0];
    endfunction

    function automatic qword_darr_t _build_kc705_frame(
        longint unsigned seq_num,
        byte_darr_t      msg_bytes
    );
        int unsigned msg_len         = msg_bytes.size();
        int unsigned udp_payload_len = 22 + msg_len;
        int unsigned ip_total_len    = 28 + udp_payload_len;
        int unsigned udp_total_len   = 8  + udp_payload_len;
        int unsigned total_bytes     = 14 + ip_total_len;
        int unsigned padded          = (total_bytes + 7) / 8 * 8;
        byte unsigned frame_bytes[];
        qword_darr_t  beats;
        byte unsigned ip_hdr[];
        bit [15:0] cksum;
        frame_bytes = new[padded];
        for (int i = 0; i < padded; i++) frame_bytes[i] = 8'h00;
        // Ethernet (14 B)
        // dst MAC = 02:00:00:00:00:01 (matches kc705_top local_mac)
        frame_bytes[0]=8'h02; frame_bytes[1]=8'h00; frame_bytes[2]=8'h00;
        frame_bytes[3]=8'h00; frame_bytes[4]=8'h00; frame_bytes[5]=8'h01;
        frame_bytes[6]=8'h00; frame_bytes[7]=8'h01; frame_bytes[8]=8'h02;
        frame_bytes[9]=8'h03; frame_bytes[10]=8'h04; frame_bytes[11]=8'h05;
        frame_bytes[12]=8'h08; frame_bytes[13]=8'h00;
        // IPv4 (20 B)
        frame_bytes[14]=8'h45; frame_bytes[15]=8'h00;
        frame_bytes[16]=ip_total_len[15:8]; frame_bytes[17]=ip_total_len[7:0];
        frame_bytes[18]=8'h00; frame_bytes[19]=8'h01;
        frame_bytes[20]=8'h00; frame_bytes[21]=8'h00;
        frame_bytes[22]=8'h40; frame_bytes[23]=8'h11;
        frame_bytes[24]=8'h00; frame_bytes[25]=8'h00; // checksum placeholder
        frame_bytes[26]=8'hC0; frame_bytes[27]=8'hA8;
        frame_bytes[28]=8'h01; frame_bytes[29]=8'h01;
        // dst IP = 233.54.12.0 = E9:36:0C:00 (matches kc705_top local_ip)
        frame_bytes[30]=8'hE9; frame_bytes[31]=8'h36;
        frame_bytes[32]=8'h0C; frame_bytes[33]=8'h00;
        // Compute and write valid IP header checksum
        ip_hdr = new[20];
        for (int i = 0; i < 20; i++) ip_hdr[i] = frame_bytes[14+i];
        cksum = _ip_checksum(ip_hdr);
        frame_bytes[24]=cksum[15:8]; frame_bytes[25]=cksum[7:0];
        // UDP (8 B)
        frame_bytes[34]=8'h55; frame_bytes[35]=8'hB5;
        frame_bytes[36]=8'h55; frame_bytes[37]=8'hB5;
        frame_bytes[38]=udp_total_len[15:8]; frame_bytes[39]=udp_total_len[7:0];
        frame_bytes[40]=8'h00; frame_bytes[41]=8'h00;
        // MoldUDP64 header (20 B)
        frame_bytes[42]=8'h54; frame_bytes[43]=8'h45;
        frame_bytes[44]=8'h53; frame_bytes[45]=8'h54;
        frame_bytes[46]=8'h53; frame_bytes[47]=8'h45;
        frame_bytes[48]=8'h53; frame_bytes[49]=8'h53;
        frame_bytes[50]=8'h20; frame_bytes[51]=8'h20;
        frame_bytes[52]=seq_num[63:56]; frame_bytes[53]=seq_num[55:48];
        frame_bytes[54]=seq_num[47:40]; frame_bytes[55]=seq_num[39:32];
        frame_bytes[56]=seq_num[31:24]; frame_bytes[57]=seq_num[23:16];
        frame_bytes[58]=seq_num[15:8];  frame_bytes[59]=seq_num[7:0];
        frame_bytes[60]=8'h00; frame_bytes[61]=8'h01;
        // Message length + body
        frame_bytes[62]=msg_len[15:8]; frame_bytes[63]=msg_len[7:0];
        for (int i = 0; i < msg_len; i++) frame_bytes[64+i] = msg_bytes[i];
        beats = new[padded/8];
        for (int b = 0; b < padded/8; b++) begin
            beats[b] = 64'h0;
            for (int k = 0; k < 8; k++)
                beats[b][k*8 +: 8] = frame_bytes[b*8+k];
        end
        return beats;
    endfunction

    // ── Send a frame via the AXI4-S MAC RX sequencer ───────────────
    // Use a wrapper sequence to cross sequencer boundaries correctly.
    task _send_frame(bit [63:0] beats[]);
        axis_raw_seq s;
        s = axis_raw_seq::type_id::create("raw_sq");
        s.beats = new[beats.size()](beats);
        s.start(m_axis_agent_sqr);
    endtask

    // ── Wait for m_axis_tvalid pulse or timeout ─────────────────────
    // Returns 1 if tvalid asserted within window, 0 on timeout.
    task _wait_ouch_tvalid(output bit fired, input int window);
        fired = 1'b0;
        for (int i = 0; i < window; i++) begin
            @(kc705_vif.monitor_cb);
            if (kc705_vif.monitor_cb.m_axis_tvalid) begin
                fired = 1'b1;
                return;
            end
        end
    endtask

    // ── body ────────────────────────────────────────────────────────
    task body();
        byte_darr_t      msg;
        bit [63:0]       beats[];
        bit              fired;
        longint unsigned seq = 64'd200;   // start well above init_seq range
        int unsigned oob_price_high;
        int unsigned oob_price_low;
        int unsigned inband_price;
        int unsigned oob_qty;
        int unsigned inband_qty;

        // ── Step 1: Program risk thresholds ───────────────────────
        `uvm_info("RISK_FUZZ", $sformatf(
            "Programming: BAND_BPS=%0d  MAX_QTY=%0d  SCORE_THR=0",
            band_bps, max_qty), UVM_LOW)
        axil_write(REG_BAND_BPS,  band_bps);
        axil_write(REG_MAX_QTY,   max_qty);
        axil_write(REG_SCORE_THR, 32'h0);     // threshold=0 → any score passes

        // ── Step 2: Compute price boundaries ─────────────────────
        // Price band: |price − mid| must be ≤ (band_bps × mid) / 10000
        // OOB: price = mid + (band_bps + 1) × mid / 10000 + 100  (safely outside)
        // In-band: price = mid (exactly at mid → always passes)
        oob_price_high = bbo_mid_f4 + (((band_bps + 1) * bbo_mid_f4) / 10000) + 100;
        oob_price_low  = bbo_mid_f4 - (((band_bps + 1) * bbo_mid_f4) / 10000) - 100;
        inband_price   = bbo_mid_f4;
        oob_qty        = max_qty + 1;
        inband_qty     = max_qty;   // exactly at limit — must pass

        // ── Step 3: Price band OOB HIGH ───────────────────────────
        `uvm_info("RISK_FUZZ",
            $sformatf("CASE 1: price_band_oob_high price=0x%08h (mid=0x%08h band=%0d bps)",
                oob_price_high, bbo_mid_f4, band_bps), UVM_LOW)
        _make_add_order(msg, 8'h42 /*Buy*/, inband_qty, aapl_sym, oob_price_high, seq++);
        beats = _build_kc705_frame(seq, msg);
        _send_frame(beats);
        _wait_ouch_tvalid(fired, BLOCK_WINDOW);
        if (fired) begin
            `uvm_error("RISK_FUZZ", "CASE 1 FAIL: OOB price_high leaked through risk check")
            oob_leaked++;
        end else begin
            `uvm_info("RISK_FUZZ", "CASE 1 PASS: OOB price_high correctly blocked", UVM_LOW)
            oob_blocked++;
        end

        // ── Step 4: Price band OOB LOW ────────────────────────────
        `uvm_info("RISK_FUZZ",
            $sformatf("CASE 2: price_band_oob_low price=0x%08h", oob_price_low), UVM_LOW)
        _make_add_order(msg, 8'h53 /*Sell*/, inband_qty, aapl_sym, oob_price_low, seq++);
        beats = _build_kc705_frame(seq, msg);
        _send_frame(beats);
        _wait_ouch_tvalid(fired, BLOCK_WINDOW);
        if (fired) begin
            `uvm_error("RISK_FUZZ", "CASE 2 FAIL: OOB price_low leaked through risk check")
            oob_leaked++;
        end else begin
            `uvm_info("RISK_FUZZ", "CASE 2 PASS: OOB price_low correctly blocked", UVM_LOW)
            oob_blocked++;
        end

        // ── Step 5: Fat-finger OOB ────────────────────────────────
        `uvm_info("RISK_FUZZ",
            $sformatf("CASE 3: fat_finger_oob qty=%0d (max=%0d)", oob_qty, max_qty), UVM_LOW)
        _make_add_order(msg, 8'h42, oob_qty, aapl_sym, inband_price, seq++);
        beats = _build_kc705_frame(seq, msg);
        _send_frame(beats);
        _wait_ouch_tvalid(fired, BLOCK_WINDOW);
        if (fired) begin
            `uvm_error("RISK_FUZZ", "CASE 3 FAIL: fat-finger OOB qty leaked through risk check")
            oob_leaked++;
        end else begin
            `uvm_info("RISK_FUZZ", "CASE 3 PASS: fat-finger OOB correctly blocked", UVM_LOW)
            oob_blocked++;
        end

        // ── Step 6: In-band price + valid qty → must pass ─────────
        `uvm_info("RISK_FUZZ",
            $sformatf("CASE 4: in_band_pass price=0x%08h qty=%0d", inband_price, inband_qty),
            UVM_LOW)
        _make_add_order(msg, 8'h42, inband_qty, aapl_sym, inband_price, seq++);
        beats = _build_kc705_frame(seq, msg);
        _send_frame(beats);
        _wait_ouch_tvalid(fired, PASS_WINDOW);
        if (!fired) begin
            `uvm_error("RISK_FUZZ", "CASE 4 FAIL: in-band order was incorrectly blocked")
            inband_missed++;
        end else begin
            `uvm_info("RISK_FUZZ", "CASE 4 PASS: in-band order correctly processed", UVM_LOW)
            inband_passed++;
        end

        // ── Step 7: Kill switch ───────────────────────────────────
        `uvm_info("RISK_FUZZ", "CASE 5: kill switch arm + verify block", UVM_LOW)
        axil_write(REG_CTRL, CTRL_KILL_BIT);   // assert kill bit (write-once)
        repeat(4) @(kc705_vif.driver_cb);       // allow register to propagate

        _make_add_order(msg, 8'h42, inband_qty, aapl_sym, inband_price, seq++);
        beats = _build_kc705_frame(seq, msg);
        _send_frame(beats);
        _wait_ouch_tvalid(fired, BLOCK_WINDOW);
        if (fired) begin
            `uvm_error("RISK_FUZZ", "CASE 5 FAIL: kill switch armed but order passed through")
            oob_leaked++;
        end else begin
            `uvm_info("RISK_FUZZ", "CASE 5 PASS: kill switch correctly blocking orders", UVM_LOW)
            oob_blocked++;
        end

        // ── Summary ───────────────────────────────────────────────
        `uvm_info("RISK_FUZZ", $sformatf(
            "Summary: oob_blocked=%0d  oob_leaked=%0d  inband_passed=%0d  inband_missed=%0d",
            oob_blocked, oob_leaked, inband_passed, inband_missed), UVM_LOW)

        if (oob_leaked > 0 || inband_missed > 0)
            `uvm_error("RISK_FUZZ", "One or more risk-check cases FAILED")
        else
            `uvm_info("RISK_FUZZ", "All risk-check cases PASSED", UVM_LOW)
    endtask

endclass
