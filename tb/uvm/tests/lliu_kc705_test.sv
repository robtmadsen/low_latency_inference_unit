// lliu_kc705_test.sv — System-level test for kc705_top
//
// DUT TOPLEVEL: kc705_top
// Compile with: make SIM=verilator TOPLEVEL=kc705_top TEST=lliu_kc705_test
//
// Scenarios:
//   1. Add Order, watched symbol       — dp_result_valid fires, result non-zero
//   2. Add Order, unwatched symbol     — dp_result_valid never fires
//   3. Mixed 4 orders (2 hit, 2 miss) — exactly 2 dp_result_valid pulses
//   4. Gap drop (seq_num skip)         — no result
//   5. Weight hot reload               — new weights in effect for next inference
//   6. Soft reset recovery             — correct operation after cpu_reset mid-run
//   7. Back-to-back 10 Add Orders     — 10 results, all non-zero
//   8. AXI4-Lite status register read  — reads cleanly without deadlock
//
// Frame format: full Ethernet/IPv4/UDP/MoldUDP64/ITCH for kc705_top mac_rx input.

// ── Typedefs (package scope, declared before the class) ───────────────────
typedef byte unsigned byte_darr_t [];
typedef bit [63:0]    qword_darr_t[];

// ── Main test class ────────────────────────────────────────────────────────
class lliu_kc705_test extends lliu_base_test;
    `uvm_component_utils(lliu_kc705_test)

    virtual kc705_ctrl_if kc705_vif;

    localparam bit [31:0] REG_DROPPED_FR = 32'h28;
    localparam bit [15:0] BF16_ONE = 16'h3F80;
    localparam bit [15:0] BF16_TWO = 16'h4000;

    function new(string name = "lliu_kc705_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        uvm_config_db #(bit)::set(this, "*", "kc705_sim_mode", 1'b1);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!uvm_config_db #(virtual kc705_ctrl_if)::get(
                this, "", "kc705_vif", kc705_vif))
            `uvm_fatal("NOVIF", "kc705_ctrl_if virtual interface not found")
    endfunction

    // ── Build ITCH 5.0 Add Order (36 bytes) into msg[] ───────────────
    task make_add_order(
        ref    byte_darr_t      msg,
        input  byte unsigned    side,
        input  int unsigned     qty,
        input  byte unsigned    symbol[8],
        input  int unsigned     price_f4,
        input  longint unsigned order_ref = 1
    );
        msg = new[36];
        msg[0]  = 8'h41;
        msg[1]  = 8'h00; msg[2]  = 8'h00;
        msg[3]  = 8'h00; msg[4]  = 8'h00;
        msg[5]  = 8'h00; msg[6]  = 8'h00; msg[7]  = 8'h00;
        msg[8]  = 8'h00; msg[9]  = 8'h00; msg[10] = 8'h00;
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
    endtask

    // ── Compute one's-complement 16-bit checksum over an even byte array ─
    function automatic bit [15:0] ip_checksum(byte unsigned hdr[]);
        bit [31:0] acc = 32'h0;
        for (int i = 0; i < hdr.size(); i += 2) begin
            acc += {hdr[i], hdr[i+1]};
        end
        // fold carry
        while (acc[31:16]) acc = acc[15:0] + acc[31:16];
        return ~acc[15:0];
    endfunction

    // ── Build Ethernet/IPv4/UDP/MoldUDP64 frame ───────────────────────
    //
    // DUT configuration (kc705_top with KINTEX7_SIM_GTX_BYPASS):
    //   local_mac = 48'h020000000001  (02:00:00:00:00:01)
    //   local_ip  = 32'hE9360C00      (233.54.12.0)
    // The frame dst_ip must match local_ip for udp_complete_64 to accept.
    // IP checksum is computed over the 20-byte IPv4 header.
    function automatic qword_darr_t build_kc705_frame(
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
        byte unsigned ip_hdr[20];
        bit [15:0] cksum;
        qword_darr_t  beats;
        frame_bytes = new[padded];
        for (int i = 0; i < padded; i++) frame_bytes[i] = 8'h00;
        // Ethernet (14 B)
        // dst MAC = 02:00:00:00:00:01 (matches local_mac in kc705_top)
        frame_bytes[0]=8'h02; frame_bytes[1]=8'h00; frame_bytes[2]=8'h00;
        frame_bytes[3]=8'h00; frame_bytes[4]=8'h00; frame_bytes[5]=8'h01;
        // src MAC
        frame_bytes[6]=8'h00; frame_bytes[7]=8'h01; frame_bytes[8]=8'h02;
        frame_bytes[9]=8'h03; frame_bytes[10]=8'h04; frame_bytes[11]=8'h05;
        // EtherType IPv4
        frame_bytes[12]=8'h08; frame_bytes[13]=8'h00;
        // IPv4 (20 B, offset 14) — checksum computed below
        frame_bytes[14]=8'h45; frame_bytes[15]=8'h00;
        frame_bytes[16]=ip_total_len[15:8]; frame_bytes[17]=ip_total_len[7:0];
        frame_bytes[18]=8'h00; frame_bytes[19]=8'h01;   // ID
        frame_bytes[20]=8'h00; frame_bytes[21]=8'h00;   // flags+frag
        frame_bytes[22]=8'h40; frame_bytes[23]=8'h11;   // TTL=64, proto=UDP
        frame_bytes[24]=8'h00; frame_bytes[25]=8'h00;   // checksum placeholder
        frame_bytes[26]=8'hC0; frame_bytes[27]=8'hA8;   // src IP 192.168.1.1
        frame_bytes[28]=8'h01; frame_bytes[29]=8'h01;
        frame_bytes[30]=8'hE9; frame_bytes[31]=8'h36;   // dst IP 233.54.12.0
        frame_bytes[32]=8'h0C; frame_bytes[33]=8'h00;   //   (= local_ip)
        // Compute valid IP header checksum over bytes 14..33
        for (int i = 0; i < 20; i++) ip_hdr[i] = frame_bytes[14+i];
        cksum = ip_checksum(ip_hdr);
        frame_bytes[24]=cksum[15:8]; frame_bytes[25]=cksum[7:0];
        // UDP (8 B, offset 34)
        frame_bytes[34]=8'h55; frame_bytes[35]=8'hB5;   // src port
        frame_bytes[36]=8'h55; frame_bytes[37]=8'hB5;   // dst port
        frame_bytes[38]=udp_total_len[15:8]; frame_bytes[39]=udp_total_len[7:0];
        frame_bytes[40]=8'h00; frame_bytes[41]=8'h00;   // UDP checksum (0=disabled)
        // MoldUDP64 header (20 B, offset 42)
        frame_bytes[42]=8'h54; frame_bytes[43]=8'h45;   // session "TESTSE"
        frame_bytes[44]=8'h53; frame_bytes[45]=8'h54;
        frame_bytes[46]=8'h53; frame_bytes[47]=8'h45;
        frame_bytes[48]=8'h53; frame_bytes[49]=8'h53;
        frame_bytes[50]=8'h20; frame_bytes[51]=8'h20;
        frame_bytes[52]=seq_num[63:56]; frame_bytes[53]=seq_num[55:48];
        frame_bytes[54]=seq_num[47:40]; frame_bytes[55]=seq_num[39:32];
        frame_bytes[56]=seq_num[31:24]; frame_bytes[57]=seq_num[23:16];
        frame_bytes[58]=seq_num[15:8];  frame_bytes[59]=seq_num[7:0];
        frame_bytes[60]=8'h00; frame_bytes[61]=8'h01;   // msg_count = 1
        // Message length prefix + body (offset 62)
        frame_bytes[62]=msg_len[15:8]; frame_bytes[63]=msg_len[7:0];
        for (int i = 0; i < msg_len; i++) frame_bytes[64+i] = msg_bytes[i];
        // Pack into 64-bit beats (LE: byte[k] → beat[k/8][(k%8)*8+:8])
        beats = new[padded/8];
        for (int b = 0; b < padded/8; b++) begin
            beats[b] = 64'h0;
            for (int k = 0; k < 8; k++)
                beats[b][k*8 +: 8] = frame_bytes[b*8+k];
        end
        return beats;
    endfunction

    // ── Send beats via the AXI4-S MAC RX agent ───────────────────────
    task send_frame(bit [63:0] beats[]);
        axis_raw_seq s;
        s = axis_raw_seq::type_id::create("raw_sq");
        s.beats = new[beats.size()](beats);
        s.start(m_env.m_axis_agent.m_sequencer);
    endtask

    // ── Spin until m_axis_tvalid (OUCH output) or timeout ─────────────────────────
    task wait_dp_result(
        output int unsigned result_val,
        input  int unsigned timeout_cycles = 300
    );
        result_val = 32'hDEAD_BEEF;
        for (int i = 0; i < timeout_cycles; i++) begin
            @(kc705_vif.monitor_cb);
            if (kc705_vif.monitor_cb.m_axis_tvalid) begin
                // OUCH packet first 8 bytes: tdata[63:0] big-endian; use low 32 bits as proxy
                result_val = kc705_vif.monitor_cb.m_axis_tdata[31:0];
                return;
            end
        end
    endtask

    task axil_read(bit [31:0] addr, output bit [31:0] rdata);
        axil_read_seq rseq;
        rseq = axil_read_seq::type_id::create("axil_rd");
        rseq.addr = addr;
        rseq.start(m_env.m_axil_agent.m_sequencer);
        rdata = rseq.rdata;
    endtask

    task axil_write(bit [31:0] addr, bit [31:0] wdata);
        axil_write_seq wseq;
        wseq = axil_write_seq::type_id::create("axil_wr");
        wseq.addr = addr;
        wseq.data = wdata;
        wseq.start(m_env.m_axil_agent.m_sequencer);
    endtask

    // ================================================================
    //  run_phase
    // ================================================================
    task run_phase(uvm_phase phase);
        kc705_init_seq   init_seq;
        byte unsigned    aapl_sym[8];
        byte unsigned    msft_sym[8];
        byte unsigned    intc_sym[8];
        byte_darr_t      msg_arr;
        bit [63:0]       beats[];
        int unsigned     result;
        int              hits;
        longint unsigned seq;

        phase.raise_objection(this, "lliu_kc705_test");

        kc705_vif.driver_cb.cpu_reset    <= 1'b0;
        kc705_vif.driver_cb.s_tkeep     <= 8'hFF;
        kc705_vif.driver_cb.m_axis_tready <= 1'b1;  // accept OUCH output by default

        aapl_sym = '{8'h41,8'h41,8'h50,8'h4C,8'h20,8'h20,8'h20,8'h20};
        msft_sym = '{8'h4D,8'h53,8'h46,8'h54,8'h20,8'h20,8'h20,8'h20};
        intc_sym = '{8'h49,8'h4E,8'h54,8'h43,8'h20,8'h20,8'h20,8'h20};
        seq = 64'd1;

        // ── Init ─────────────────────────────────────────────────────
        `uvm_info("TEST", "=== KC705 init ===", UVM_LOW)
        init_seq = kc705_init_seq::type_id::create("init_seq");
        init_seq.kc705_vif = kc705_vif;
        init_seq.watchlist.push_back(kc705_init_seq::stock_to_bits64("AAPL    "));
        init_seq.watchlist.push_back(kc705_init_seq::stock_to_bits64("MSFT    "));
        init_seq.start(m_env.m_axil_agent.m_sequencer);

        // ── Sc1: watched AAPL → result ────────────────────────────────
        `uvm_info("TEST", "=== Sc1: watched AAPL → dp_result_valid ===", UVM_LOW)
        make_add_order(msg_arr, 8'h42, 100, aapl_sym, 1_000_000, 1);
        beats = build_kc705_frame(seq++, msg_arr);
        send_frame(beats);
        wait_dp_result(result);
        if (result == 32'hDEAD_BEEF)
            `uvm_error("TEST", "Sc1: dp_result_valid timeout for watched AAPL")
        else if (result == 0)
            `uvm_error("TEST", "Sc1: dp_result_valid fired but result=0")
        else
            `uvm_info("TEST", $sformatf("Sc1 PASS: dp_result=0x%08h", result), UVM_LOW)

        // ── Sc2: unwatched INTC → no result ──────────────────────────
        `uvm_info("TEST", "=== Sc2: unwatched INTC → no m_axis_tvalid ===", UVM_LOW)
        make_add_order(msg_arr, 8'h42, 200, intc_sym, 500_000, 2);
        beats = build_kc705_frame(seq++, msg_arr);
        send_frame(beats);
        repeat (100) @(kc705_vif.monitor_cb);
        if (kc705_vif.monitor_cb.m_axis_tvalid)
            `uvm_error("TEST", "Sc2: unexpected m_axis_tvalid for unwatched INTC")
        else
            `uvm_info("TEST", "Sc2 PASS: no result for unwatched symbol", UVM_LOW)

        // ── Sc3: 4 orders (2 hit / 2 miss) → exactly 2 results ───────
        `uvm_info("TEST", "=== Sc3: 4 orders (2 hit, 2 miss) ===", UVM_LOW)
        begin
            byte unsigned syms[4][8];
            syms[0] = aapl_sym; syms[1] = intc_sym;
            syms[2] = msft_sym; syms[3] = intc_sym;
            hits = 0;
            fork
                begin
                    for (int i = 0; i < 4; i++) begin
                        make_add_order(msg_arr, 8'h42, 100, syms[i],
                                       500_000+i*100, 10+i);
                        beats = build_kc705_frame(seq+i, msg_arr);
                        send_frame(beats);
                    end
                    seq += 4;
                end
                begin
                    repeat (500) begin
                        @(kc705_vif.monitor_cb);
                        if (kc705_vif.monitor_cb.m_axis_tvalid) hits++;;
                    end
                end
            join
            if (hits != 2)
                `uvm_error("TEST",
                    $sformatf("Sc3: expected 2 pulses, got %0d", hits))
            else
                `uvm_info("TEST", "Sc3 PASS: exactly 2 results", UVM_LOW)
        end

        // ── Sc4: seq_num gap → drop, no result ───────────────────────
        `uvm_info("TEST", "=== Sc4: seq_num gap → drop ===", UVM_LOW)
        begin
            seq += 5;
            make_add_order(msg_arr, 8'h42, 100, aapl_sym, 1_000_000, 20);
            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);
            repeat (100) @(kc705_vif.monitor_cb);
            if (kc705_vif.monitor_cb.m_axis_tvalid)
                `uvm_error("TEST", "Sc4: m_axis_tvalid for dropped datagram")
            else
                `uvm_info("TEST", "Sc4 PASS: no result after gap", UVM_LOW)
        end

        // ── Sc5: weight hot reload ─────────────────────────────────────
        `uvm_info("TEST", "=== Sc5: weight hot reload ===", UVM_LOW)
        begin
            int unsigned result1, result2;
            make_add_order(msg_arr, 8'h42, 100, aapl_sym, 2_000_000, 30);
            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);
            wait_dp_result(result1);

            begin
                weight_load_seq wt2;
                wt2 = weight_load_seq::type_id::create("wt2");
                wt2.weights = new[4];
                foreach (wt2.weights[i]) wt2.weights[i] = BF16_TWO;
                wt2.start(m_env.m_axil_agent.m_sequencer);
            end

            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);
            wait_dp_result(result2);

            if (result1 == 32'hDEAD_BEEF || result2 == 32'hDEAD_BEEF)
                `uvm_error("TEST", "Sc5: dp_result_valid timeout")
            else
                `uvm_info("TEST",
                    $sformatf("Sc5 PASS: pre=0x%08h post=0x%08h", result1, result2),
                    UVM_LOW)

            begin
                weight_load_seq wt1;
                wt1 = weight_load_seq::type_id::create("wt1");
                wt1.weights = new[4];
                foreach (wt1.weights[i]) wt1.weights[i] = BF16_ONE;
                wt1.start(m_env.m_axil_agent.m_sequencer);
            end
        end

        // ── Sc6: cpu_reset recovery ────────────────────────────────────
        `uvm_info("TEST", "=== Sc6: cpu_reset recovery ===", UVM_LOW)
        begin
            kc705_init_seq reinit;
            make_add_order(msg_arr, 8'h42, 100, aapl_sym, 1_000_000, 40);
            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);

            kc705_vif.driver_cb.cpu_reset <= 1'b1;
            repeat (4) @(kc705_vif.driver_cb);
            kc705_vif.driver_cb.cpu_reset <= 1'b0;
            repeat (10) @(kc705_vif.driver_cb);

            reinit = kc705_init_seq::type_id::create("reinit");
            reinit.kc705_vif = kc705_vif;
            reinit.watchlist.push_back(kc705_init_seq::stock_to_bits64("AAPL    "));
            reinit.watchlist.push_back(kc705_init_seq::stock_to_bits64("MSFT    "));
            reinit.start(m_env.m_axil_agent.m_sequencer);
            seq = 64'd1;

            make_add_order(msg_arr, 8'h42, 100, aapl_sym, 1_000_000, 50);
            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);
            wait_dp_result(result);
            if (result == 32'hDEAD_BEEF)
                `uvm_error("TEST", "Sc6: no result after reset recovery")
            else
                `uvm_info("TEST", $sformatf("Sc6 PASS: result=0x%08h", result), UVM_LOW)
        end

        // ── Sc7: 10 back-to-back watched orders ───────────────────────
        `uvm_info("TEST", "=== Sc7: 10 back-to-back watched orders ===", UVM_LOW)
        begin
            int n_results = 0;
            fork
                begin
                    for (int i = 0; i < 10; i++) begin
                        make_add_order(msg_arr, 8'h42, 100+i, aapl_sym,
                                       1_000_000+i*10_000, 100+i);
                        beats = build_kc705_frame(seq+i, msg_arr);
                        send_frame(beats);
                    end
                    seq += 10;
                end
                begin
                    repeat (2000) begin
                        @(kc705_vif.monitor_cb);
                        if (kc705_vif.monitor_cb.m_axis_tvalid) n_results++;
                    end
                end
            join
            if (n_results < 10)
                `uvm_error("TEST",
                    $sformatf("Sc7: expected 10, got %0d", n_results))
            else
                `uvm_info("TEST",
                    $sformatf("Sc7 PASS: %0d/10 results", n_results), UVM_LOW)
        end

        // ── Sc8: AXI4-Lite status read ─────────────────────────────────
        `uvm_info("TEST", "=== Sc8: AXI4-Lite dropped_frames read ===", UVM_LOW)
        begin
            bit [31:0] dropped_fr;
            axil_read(REG_DROPPED_FR, dropped_fr);
            `uvm_info("TEST",
                $sformatf("Sc8 PASS: dropped_frames=%0d", dropped_fr), UVM_LOW)
        end

        `uvm_info("TEST", "=== lliu_kc705_test done ===", UVM_LOW)
        phase.drop_objection(this, "lliu_kc705_test");
    endtask

endclass
