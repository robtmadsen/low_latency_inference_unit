// tx_backpressure_kill_seq.sv — TX backpressure auto-kill sequence
//
// DUT target: kc705_top (KINTEX7_SIM_GTX_BYPASS)
// Spec ref:   .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.7
//
// The DUT monitors m_axis_tready (downstream MAC TX backpressure).
// If tready is deasserted for > 64 consecutive cycles, the kill switch
// auto-asserts inside risk_check.  The kill switch self-clears once
// tready has been continuously asserted for ≥ 256 consecutive cycles.
//
// Test sequence:
//   1. Verify baseline: send a watched order → m_axis_tvalid fires within PASS_WINDOW.
//   2. Deassert m_axis_tready and hold for BACKPRESSURE_HOLD cycles (> 64).
//   3. Send another watched order → verify m_axis_tvalid does NOT fire (kill armed).
//   4. Reassert m_axis_tready for RECOVERY_HOLD cycles (≥ 256).
//   5. Send another watched order → verify m_axis_tvalid fires (kill cleared).
//
// Usage:
//   tx_backpressure_kill_seq bp_seq;
//   bp_seq = tx_backpressure_kill_seq::type_id::create("bp_seq");
//   bp_seq.kc705_vif      = kc705_vif;
//   bp_seq.m_axis_agent_sqr = m_env.m_axis_agent.m_sequencer;
//   bp_seq.start(m_env.m_axil_agent.m_sequencer);

class tx_backpressure_kill_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(tx_backpressure_kill_seq)

    // ── Handles ────────────────────────────────────────────────────
    virtual kc705_ctrl_if              kc705_vif;
    uvm_sequencer #(axi4_stream_transaction) m_axis_agent_sqr;

    // ── Backpressure timing parameters (spec §4.7) ─────────────────
    // Hold > 64 cycles to trigger auto-kill
    localparam int BACKPRESSURE_HOLD = 72;
    // Hold ≥ 256 cycles to self-clear
    localparam int RECOVERY_HOLD     = 270;

    // ── Observation windows ────────────────────────────────────────
    localparam int PASS_WINDOW  = 300;
    localparam int BLOCK_WINDOW = 200;

    // ── Symbol (must match watchlist in kc705_init_seq) ────────────
    byte unsigned aapl_sym[8] = '{8'h41,8'h41,8'h50,8'h4C,8'h20,8'h20,8'h20,8'h20};

    // ── Result metrics ─────────────────────────────────────────────
    bit baseline_ok   = 1'b0;
    bit kill_ok       = 1'b0;
    bit recovery_ok   = 1'b0;

    function new(string name = "tx_backpressure_kill_seq");
        super.new(name);
    endfunction

    // ── Frame-building helpers (private copies, same as risk_fuzz_seq) ──

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
        msg[1]  = 8'h00; msg[2]  = 8'h00; msg[3]  = 8'h00; msg[4]  = 8'h00;
        msg[5]  = 8'h00; msg[6]  = 8'h00; msg[7]  = 8'h00; msg[8]  = 8'h00;
        msg[9]  = 8'h00; msg[10] = 8'h00;
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
        // dst MAC = 02:00:00:00:00:01 (matches kc705_top local_mac)
        frame_bytes[0]=8'h02; frame_bytes[1]=8'h00; frame_bytes[2]=8'h00;
        frame_bytes[3]=8'h00; frame_bytes[4]=8'h00; frame_bytes[5]=8'h01;
        frame_bytes[6]=8'h00; frame_bytes[7]=8'h01; frame_bytes[8]=8'h02;
        frame_bytes[9]=8'h03; frame_bytes[10]=8'h04; frame_bytes[11]=8'h05;
        frame_bytes[12]=8'h08; frame_bytes[13]=8'h00;
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
        frame_bytes[34]=8'h55; frame_bytes[35]=8'hB5;
        frame_bytes[36]=8'h55; frame_bytes[37]=8'hB5;
        frame_bytes[38]=udp_total_len[15:8]; frame_bytes[39]=udp_total_len[7:0];
        frame_bytes[40]=8'h00; frame_bytes[41]=8'h00;
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

    task _send_frame(bit [63:0] beats[]);
        axis_raw_seq s;
        s = axis_raw_seq::type_id::create("raw_sq");
        s.beats = new[beats.size()](beats);
        s.start(m_axis_agent_sqr);
    endtask

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
        longint unsigned seq = 64'd500;  // well above risk_fuzz range

        // ── Ensure tready is asserted (normal condition) ──────────
        kc705_vif.driver_cb.m_axis_tready <= 1'b1;
        repeat(4) @(kc705_vif.driver_cb);

        // ── Step 1: Baseline — order must pass ────────────────────
        `uvm_info("BP_KILL", "STEP 1: baseline — send AAPL order, expect OUCH tvalid", UVM_LOW)
        _make_add_order(msg, 8'h42, 100, aapl_sym, 1_500_000, seq++);
        beats = _build_kc705_frame(seq, msg);
        _send_frame(beats);
        _wait_ouch_tvalid(fired, PASS_WINDOW);
        if (!fired) begin
            `uvm_error("BP_KILL",
                "STEP 1 FAIL: baseline order was not processed — check watchlist and init")
        end else begin
            `uvm_info("BP_KILL", "STEP 1 PASS: baseline order processed", UVM_LOW)
            baseline_ok = 1'b1;
        end

        // ── Step 2: Assert backpressure for > 64 cycles ──────────
        `uvm_info("BP_KILL", $sformatf(
            "STEP 2: deassert m_axis_tready for %0d cycles (threshold=64)", BACKPRESSURE_HOLD),
            UVM_LOW)
        kc705_vif.driver_cb.m_axis_tready <= 1'b0;
        repeat(BACKPRESSURE_HOLD) @(kc705_vif.driver_cb);

        // ── Step 3: Send order while kill is armed — must be blocked ──
        `uvm_info("BP_KILL", "STEP 3: send order with kill armed — expect block", UVM_LOW)
        _make_add_order(msg, 8'h42, 100, aapl_sym, 1_500_000, seq++);
        beats = _build_kc705_frame(seq, msg);
        _send_frame(beats);
        _wait_ouch_tvalid(fired, BLOCK_WINDOW);
        if (fired) begin
            `uvm_error("BP_KILL",
                "STEP 3 FAIL: order passed while backpressure kill should be armed")
        end else begin
            `uvm_info("BP_KILL", "STEP 3 PASS: order correctly blocked by backpressure kill",
                UVM_LOW)
            kill_ok = 1'b1;
        end

        // ── Step 4: Reassert tready for ≥ 256 cycles (self-clear) ─
        `uvm_info("BP_KILL", $sformatf(
            "STEP 4: assert m_axis_tready for %0d cycles (recovery=256)", RECOVERY_HOLD),
            UVM_LOW)
        kc705_vif.driver_cb.m_axis_tready <= 1'b1;
        repeat(RECOVERY_HOLD) @(kc705_vif.driver_cb);

        // ── Step 5: Send order after self-clear — must pass ──────
        `uvm_info("BP_KILL", "STEP 5: send order after self-clear — expect OUCH tvalid",
            UVM_LOW)
        _make_add_order(msg, 8'h42, 100, aapl_sym, 1_500_000, seq++);
        beats = _build_kc705_frame(seq, msg);
        _send_frame(beats);
        _wait_ouch_tvalid(fired, PASS_WINDOW);
        if (!fired) begin
            `uvm_error("BP_KILL",
                "STEP 5 FAIL: kill did not self-clear after tready reasserted for 256 cycles")
        end else begin
            `uvm_info("BP_KILL", "STEP 5 PASS: kill self-cleared, order processed", UVM_LOW)
            recovery_ok = 1'b1;
        end

        // ── Summary ───────────────────────────────────────────────
        `uvm_info("BP_KILL", $sformatf(
            "Summary: baseline=%0b  kill=%0b  recovery=%0b",
            baseline_ok, kill_ok, recovery_ok), UVM_LOW)
        if (!baseline_ok || !kill_ok || !recovery_ok)
            `uvm_error("BP_KILL", "One or more backpressure-kill steps FAILED")
        else
            `uvm_info("BP_KILL", "All backpressure-kill steps PASSED", UVM_LOW)
    endtask

endclass
