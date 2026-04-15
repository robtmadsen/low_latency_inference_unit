// lliu_ouch_compliance_test.sv — OUCH 5.0 packet compliance test for kc705_top
//
// DUT target: kc705_top (KINTEX7_SIM_GTX_BYPASS)
// Spec ref:   .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.8
//             NASDAQ OUCH 5.0 spec (Enter Order message structure)
//
// Sends N_ORDERS watched ITCH Add Orders and waits for N_ORDERS OUCH tvalid
// pulses.  The structural correctness of each packet is verified by the bound
// ouch_packet_sva module (which fires $error on violation).
//
// Compile/run:
//   make SIM=verilator TOPLEVEL=kc705_top TEST=lliu_ouch_compliance_test

class lliu_ouch_compliance_test extends lliu_base_test;
    `uvm_component_utils(lliu_ouch_compliance_test)

    virtual kc705_ctrl_if kc705_vif;

    // Number of orders to send and expect back
    localparam int N_ORDERS = 10;
    localparam int PER_ORDER_TIMEOUT = 400;   // cycles per order

    // ── Typedefs (avoid collision with definitions in lliu_kc705_test) ──
    // These are local task temporaries — typedef in package or task scope only.

    function new(string name = "lliu_ouch_compliance_test", uvm_component parent = null);
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

    // ── Frame-building helpers ─────────────────────────────────────
    function automatic void _make_add_order(
        ref    byte unsigned    msg[],
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

    function automatic bit [63:0] _build_frame_beats(
        output bit [63:0] beats_out[],
        input longint unsigned seq_num,
        input byte unsigned    msg_bytes[]
    );
        int unsigned msg_len         = msg_bytes.size();
        int unsigned udp_payload_len = 22 + msg_len;
        int unsigned ip_total_len    = 28 + udp_payload_len;
        int unsigned udp_total_len   = 8  + udp_payload_len;
        int unsigned total_bytes     = 14 + ip_total_len;
        int unsigned padded          = (total_bytes + 7) / 8 * 8;
        byte unsigned frame_bytes[];
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
        beats_out = new[padded/8];
        for (int b = 0; b < padded/8; b++) begin
            beats_out[b] = 64'h0;
            for (int k = 0; k < 8; k++)
                beats_out[b][k*8 +: 8] = frame_bytes[b*8+k];
        end
        return 64'h0;
    endfunction

    task _send_frame(bit [63:0] beats[]);
        axis_raw_seq s;
        s = axis_raw_seq::type_id::create("raw_sq");
        s.beats = new[beats.size()](beats);
        s.start(m_env.m_axis_agent.m_sequencer);
    endtask

    task run_phase(uvm_phase phase);
        kc705_init_seq  init_seq;
        byte unsigned   aapl_sym[8];
        byte unsigned   msft_sym[8];
        byte unsigned   msg[];
        bit [63:0]      beats[];
        longint unsigned seq;
        int unsigned    received;
        int unsigned    i;

        phase.raise_objection(this, "lliu_ouch_compliance_test");

        kc705_vif.driver_cb.cpu_reset    <= 1'b0;
        kc705_vif.driver_cb.s_tkeep      <= 8'hFF;
        kc705_vif.driver_cb.m_axis_tready <= 1'b1;

        aapl_sym = '{8'h41,8'h41,8'h50,8'h4C,8'h20,8'h20,8'h20,8'h20};
        msft_sym = '{8'h4D,8'h53,8'h46,8'h54,8'h20,8'h20,8'h20,8'h20};
        seq = 64'd100;

        // ── Init ──────────────────────────────────────────────────
        `uvm_info("OUCH_TEST", "=== KC705 init ===", UVM_LOW)
        init_seq = kc705_init_seq::type_id::create("init_seq");
        init_seq.kc705_vif = kc705_vif;
        init_seq.watchlist.push_back(kc705_init_seq::stock_to_bits64("AAPL    "));
        init_seq.watchlist.push_back(kc705_init_seq::stock_to_bits64("MSFT    "));
        init_seq.start(m_env.m_axil_agent.m_sequencer);

        // ── Send N_ORDERS orders alternating AAPL/MSFT ─────────────
        `uvm_info("OUCH_TEST",
            $sformatf("=== Sending %0d orders, expecting %0d OUCH packets ===",
                N_ORDERS, N_ORDERS), UVM_LOW)

        for (i = 0; i < N_ORDERS; i++) begin
            byte unsigned sym[8];
            byte unsigned side;
            int unsigned  qty;
            int unsigned  price;

            sym   = (i % 2 == 0) ? aapl_sym : msft_sym;
            side  = (i % 3 == 0) ? 8'h53 : 8'h42;   // alternate S/B
            qty   = 100 + i * 10;
            price = 1_500_000 + i * 1000;

            _make_add_order(msg, side, qty, sym, price, longint'(i + 1));
            void'(_build_frame_beats(beats, seq, msg));
            _send_frame(beats);
            seq++;

            // Inter-frame gap: allow pipeline to flush before next frame
            repeat(20) @(kc705_vif.monitor_cb);
        end

        // ── Collect N_ORDERS OUCH tvalid pulses ────────────────────
        `uvm_info("OUCH_TEST", "=== Waiting for OUCH output packets ===", UVM_LOW)
        received = 0;
        for (int t = 0; t < N_ORDERS * PER_ORDER_TIMEOUT; t++) begin
            @(kc705_vif.monitor_cb);
            if (kc705_vif.monitor_cb.m_axis_tvalid &&
                kc705_vif.monitor_cb.m_axis_tlast) begin
                received++;
                `uvm_info("OUCH_TEST",
                    $sformatf("  Received OUCH packet %0d of %0d", received, N_ORDERS), UVM_MEDIUM)
                if (received >= N_ORDERS)
                    break;
            end
        end

        if (received < N_ORDERS)
            `uvm_error("OUCH_TEST",
                $sformatf("Only received %0d of %0d expected OUCH packets — timeout", received, N_ORDERS))
        else
            `uvm_info("OUCH_TEST",
                $sformatf("=== OUCH COMPLIANCE TEST PASS: %0d packets verified ===", received),
                UVM_LOW)

        // ouch_packet_sva has been checking each packet structurally via $error;
        // if any assertion fires the simulator will have already reported it.

        phase.drop_objection(this, "lliu_ouch_compliance_test");
    endtask

endclass
