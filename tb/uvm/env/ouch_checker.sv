// ouch_checker.sv — OUCH 5.0 packet structural checker (UVM scoreboard)
//
// DUT target: kc705_top (KC705_TOP_DUT)
// Spec ref:   .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.7, §7
//             NASDAQ OUCH 5.0 Enter Order (48 bytes, 6 × 64-bit AXI4-S beats)
//
// Monitors the m_axis_* TX output stream via kc705_ctrl_if.monitor_cb.
// For each complete packet (tlast accepted with tvalid && tready):
//   1. Type byte     (byte  0 ) = 'O' (0x4F)
//   2. Buy/Sell byte (byte 15 ) = 'B' (0x42) or 'S' (0x53)
//   3. Shares field  (bytes 16–19) > 0
//   4. Price field   (bytes 28–31) > 0
//
// AXI4-S beat encoding (little-endian byte lane):
//   byte index k within beat b → tdata[k*8 +: 8] of beat b
//   i.e. byte_addr = b*8 + k
//
// The checker is active only when kc705_sim_mode is set in the UVM config DB.
// It is instantiated inside lliu_env and acquires kc705_vif during build_phase.
// Statistics are printed in report_phase; a UVM_ERROR is raised if any packet
// fails, which will fail the test via the UVM report server.

class ouch_checker extends uvm_scoreboard;
    `uvm_component_utils(ouch_checker)

    // ── Virtual interface ─────────────────────────────────────────
    virtual kc705_ctrl_if kc705_vif;

    // ── Active flag — set when kc705_sim_mode=1 ──────────────────
    bit m_active = 1'b0;

    // ── Statistics ────────────────────────────────────────────────
    int unsigned m_pkt_count   = 0;
    int unsigned m_error_count = 0;

    // ── OUCH 5.0 Enter Order layout constants ─────────────────────
    // 48 bytes = 6 × 8-byte beats
    localparam int PKT_BYTES = 48;
    localparam int MAX_BEATS = 6;   // ceil(48 / 8)

    function new(string name = "ouch_checker", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ── build_phase: resolve virtual interface + active flag ──────
    function void build_phase(uvm_phase phase);
        bit kc705_mode;
        super.build_phase(phase);
        if (uvm_config_db #(bit)::get(this, "", "kc705_sim_mode", kc705_mode))
            m_active = kc705_mode;
        if (!uvm_config_db #(virtual kc705_ctrl_if)::get(
                this, "", "kc705_vif", kc705_vif)) begin
            if (m_active)
                `uvm_fatal("NOVIF",
                    "ouch_checker: kc705_ctrl_if virtual interface not found in config DB")
        end
    endfunction

    // ── run_phase: accumulate beats and check complete packets ────
    task run_phase(uvm_phase phase);
        byte unsigned pkt_buf [PKT_BYTES];
        int unsigned  beat_idx;

        if (!m_active) return;

        // Wait for DUT reset deassertion
        do @(kc705_vif.monitor_cb); while (kc705_vif.rst);

        beat_idx = 0;

        forever begin
            @(kc705_vif.monitor_cb);

            // Beat accepted: tvalid && tready
            // Note: m_axis_tready is in driver_cb (test drives it), so read the
            // plain signal path rather than through the monitor clocking block.
            if (kc705_vif.monitor_cb.m_axis_tvalid && kc705_vif.m_axis_tready) begin
                // Unpack 8 bytes from this beat (little-endian byte lane)
                for (int k = 0; k < 8; k++) begin
                    int unsigned byte_addr;
                    byte_addr = beat_idx * 8 + k;
                    if (byte_addr < PKT_BYTES)
                        pkt_buf[byte_addr] = kc705_vif.monitor_cb.m_axis_tdata[k*8 +: 8];
                end

                if (kc705_vif.monitor_cb.m_axis_tlast) begin
                    // Full packet received — run structural checks
                    _check_packet(pkt_buf);
                    beat_idx = 0;
                end else begin
                    beat_idx++;
                    if (beat_idx >= MAX_BEATS) begin
                        `uvm_error("OUCH_CHK",
                            $sformatf(
                                "TX stream exceeded %0d beats without tlast — spurious data or oversized packet; resetting accumulator",
                                MAX_BEATS))
                        beat_idx = 0;
                    end
                end
            end
        end
    endtask

    // ── _check_packet: validate OUCH 5.0 Enter Order fields ──────
    function void _check_packet(byte unsigned pkt [PKT_BYTES]);
        bit [31:0] shares;
        bit [31:0] price;
        bit        ok;

        m_pkt_count++;
        ok = 1'b1;

        // Check 1: message type = 'O' (0x4F)
        if (pkt[0] !== 8'h4F) begin
            `uvm_error("OUCH_CHK",
                $sformatf("Pkt #%0d: type byte 0x%02h != 0x4F ('O')",
                          m_pkt_count, pkt[0]))
            ok = 1'b0;
        end

        // Check 2: buy/sell indicator must be 'B' (0x42) or 'S' (0x53)
        if (pkt[15] !== 8'h42 && pkt[15] !== 8'h53) begin
            `uvm_error("OUCH_CHK",
                $sformatf("Pkt #%0d: side byte 0x%02h invalid (expected 0x42='B' or 0x53='S')",
                          m_pkt_count, pkt[15]))
            ok = 1'b0;
        end

        // Check 3: shares field (bytes 16–19, big-endian) must be > 0
        shares = {pkt[16], pkt[17], pkt[18], pkt[19]};
        if (shares == 32'h0) begin
            `uvm_error("OUCH_CHK",
                $sformatf("Pkt #%0d: shares field is zero — invalid OUCH packet",
                          m_pkt_count))
            ok = 1'b0;
        end

        // Check 4: price field (bytes 28–31, big-endian) must be > 0
        price = {pkt[28], pkt[29], pkt[30], pkt[31]};
        if (price == 32'h0) begin
            `uvm_error("OUCH_CHK",
                $sformatf("Pkt #%0d: price field is zero — invalid OUCH packet",
                          m_pkt_count))
            ok = 1'b0;
        end

        if (!ok) begin
            m_error_count++;
        end else begin
            `uvm_info("OUCH_CHK",
                $sformatf("Pkt #%0d PASS: type=0x%02h side=%s shares=%0d price=%0d",
                          m_pkt_count, pkt[0],
                          (pkt[15] == 8'h42) ? "B" : "S",
                          shares, price),
                UVM_MEDIUM)
        end
    endfunction

    // ── report_phase: summary ─────────────────────────────────────
    function void report_phase(uvm_phase phase);
        if (!m_active) return;
        `uvm_info("OUCH_CHK",
            $sformatf("=== OUCH Checker summary: %0d packets checked, %0d structural errors ===",
                      m_pkt_count, m_error_count),
            UVM_LOW)
        if (m_error_count > 0)
            `uvm_error("OUCH_CHK",
                "One or more OUCH packets failed structural checks — see errors above")
    endfunction

endclass
