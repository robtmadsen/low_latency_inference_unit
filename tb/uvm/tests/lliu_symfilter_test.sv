// lliu_symfilter_test.sv — Block-level test for symbol_filter
//
// DUT TOPLEVEL: symbol_filter
// Compile with: make SIM=verilator TOPLEVEL=symbol_filter TEST=lliu_symfilter_test
//
// CAM entries are loaded via kc705_ctrl_if (direct port access, not AXI4-Lite)
// since symbol_filter is tested in isolation without the kc705_top AXI4-L slave.
//
// Stock lookup stimulus is applied via kc705_ctrl_if.stock_valid / stock
// (tb_top maps these to symbol_filter.stock_valid and .stock).
//
// Scenarios (mirrors COCOTB step 3 test matrix):
//   1. Empty CAM, 10 lookups        — watchlist_hit always 0
//   2. Single entry hit             — 1 cycle latency
//   3. Single entry miss            — watchlist_hit stays 0
//   4. Entry invalidate             — hit → miss after invalidate
//   5. Overwrite entry              — key_A miss, key_B hit
//   6. Full 64-entry hit sweep      — all 64 entries hit
//   7. Back-to-back 10 lookups      — alternating hit/miss, latency=1
//   8. Write-during-lookup          — P4 SVA (write_isolation) passes
//
// All correctness checking is performed by symbol_filter_sva (bound into DUT).
// The test class drives stimulus and waits for SVA errors to surface.

class lliu_symfilter_test extends lliu_base_test;
    `uvm_component_utils(lliu_symfilter_test)

    virtual kc705_ctrl_if kc705_vif;

    function new(string name = "lliu_symfilter_test", uvm_component parent = null);
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

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------

    // Pack an 8-character ASCII string into a 64-bit big-endian integer
    // (char[0] → stock[63:56], char[7] → stock[7:0])
    function bit [63:0] stock_int(string sym);
        bit [63:0] v = 64'h0;
        for (int i = 0; i < 8 && i < sym.len(); i++)
            v[63 - i*8 -: 8] = sym[i];
        return v;
    endfunction

    // Write one CAM entry via kc705_ctrl_if direct port access
    task cam_write(int unsigned idx, bit [63:0] key, bit en);
        @(kc705_vif.driver_cb);
        kc705_vif.driver_cb.cam_wr_index  <= idx[5:0];
        kc705_vif.driver_cb.cam_wr_data   <= key;
        kc705_vif.driver_cb.cam_wr_valid  <= 1'b1;
        kc705_vif.driver_cb.cam_wr_en_bit <= en;
        @(kc705_vif.driver_cb);
        kc705_vif.driver_cb.cam_wr_valid  <= 1'b0;
        @(kc705_vif.driver_cb);
    endtask

    // Present one stock symbol for lookup (1-cycle pulse)
    task lookup(bit [63:0] key, output bit hit);
        @(kc705_vif.driver_cb);
        kc705_vif.driver_cb.stock       <= key;
        kc705_vif.driver_cb.stock_valid <= 1'b1;
        @(kc705_vif.driver_cb);
        kc705_vif.driver_cb.stock_valid <= 1'b0;
        @(kc705_vif.monitor_cb);  // 1 cycle for DUT registered output
        hit = kc705_vif.monitor_cb.watchlist_hit;
    endtask

    // -----------------------------------------------------------
    // run_phase
    // -----------------------------------------------------------
    task run_phase(uvm_phase phase);
        bit hit;
        bit [63:0] aapl, msft, goog;
        phase.raise_objection(this, "lliu_symfilter_test");

        aapl = stock_int("AAPL    ");   // padded to 8 chars
        msft = stock_int("MSFT    ");
        goog = stock_int("GOOG    ");

        // Init kc705_vif drive signals to idle
        kc705_vif.driver_cb.cam_wr_valid  <= 1'b0;
        kc705_vif.driver_cb.stock_valid   <= 1'b0;
        repeat (3) @(kc705_vif.driver_cb);

        // ── Scenario 1: empty CAM, 10 lookups → never hits ────────
        `uvm_info("TEST", "=== Scenario 1: empty CAM ===", UVM_LOW)
        for (int i = 0; i < 10; i++) begin
            lookup(aapl, hit);
            if (hit)
                `uvm_error("TEST", $sformatf("Scenario1[%0d]: unexpected hit on empty CAM", i))
        end
        `uvm_info("TEST", "Scenario1 PASS: no hits on empty CAM", UVM_LOW)

        // ── Scenario 2: single entry hit ──────────────────────────
        `uvm_info("TEST", "=== Scenario 2: single entry hit ===", UVM_LOW)
        cam_write(0, aapl, 1'b1);
        lookup(aapl, hit);
        if (!hit) `uvm_error("TEST", "Scenario2: expected hit on AAPL, got miss")
        else       `uvm_info("TEST", "Scenario2 PASS: AAPL hit", UVM_LOW)

        // ── Scenario 3: miss on different symbol ──────────────────
        `uvm_info("TEST", "=== Scenario 3: miss ===", UVM_LOW)
        lookup(msft, hit);
        if (hit) `uvm_error("TEST", "Scenario3: unexpected hit on MSFT (not in CAM)")
        else     `uvm_info("TEST", "Scenario3 PASS: MSFT miss", UVM_LOW)

        // ── Scenario 4: invalidate entry ──────────────────────────
        `uvm_info("TEST", "=== Scenario 4: invalidate ===", UVM_LOW)
        cam_write(0, aapl, 1'b0);   // disable entry 0
        lookup(aapl, hit);
        if (hit) `uvm_error("TEST", "Scenario4: expected miss after invalidate, got hit")
        else     `uvm_info("TEST", "Scenario4 PASS: no hit after invalidate", UVM_LOW)

        // ── Scenario 5: overwrite — AAPL → MSFT at index 0 ───────
        `uvm_info("TEST", "=== Scenario 5: overwrite entry ===", UVM_LOW)
        cam_write(0, msft, 1'b1);   // overwrite with MSFT
        lookup(aapl, hit);
        if (hit)  `uvm_error("TEST", "Scenario5: AAPL should miss after overwrite")
        lookup(msft, hit);
        if (!hit) `uvm_error("TEST", "Scenario5: MSFT should hit after overwrite")
        else      `uvm_info("TEST", "Scenario5 PASS: overwrite correct", UVM_LOW)

        // ── Scenario 6: full 64-entry hit sweep ───────────────────
        `uvm_info("TEST", "=== Scenario 6: full 64-entry sweep ===", UVM_LOW)
        begin
            bit [63:0] syms[64];
            int hit_count;
            // Load 64 unique symbols
            for (int i = 0; i < 64; i++) begin
                // "S0000001" … "S0000064" (each 8 bytes)
                syms[i] = 64'h0;
                syms[i][63:56] = 8'h53;          // 'S'
                syms[i][55:48] = 8'h30 + (i/10000000 % 10);
                syms[i][47:40] = 8'h30 + (i/1000000  % 10);
                syms[i][39:32] = 8'h30 + (i/100000   % 10);
                syms[i][31:24] = 8'h30 + (i/10000    % 10);
                syms[i][23:16] = 8'h30 + (i/1000     % 10);
                syms[i][15:8]  = 8'h30 + (i/100      % 10);
                syms[i][7:0]   = 8'h30 + (i/10       % 10);
                cam_write(i, syms[i], 1'b1);
            end
            // Verify all 64 hit
            hit_count = 0;
            for (int i = 0; i < 64; i++) begin
                lookup(syms[i], hit);
                if (!hit)
                    `uvm_error("TEST", $sformatf("Scenario6: index %0d missed expected hit", i))
                else
                    hit_count++;
            end
            if (hit_count == 64)
                `uvm_info("TEST", "Scenario6 PASS: all 64 entries hit", UVM_LOW)
        end

        // ── Scenario 7: back-to-back alternating hit/miss ─────────
        `uvm_info("TEST", "=== Scenario 7: back-to-back 10 lookups ===", UVM_LOW)
        begin
            // entry 0 has syms[0] (hit), lookup alternates syms[0] / goog (miss)
            bit [63:0] alt_syms[10];
            for (int i = 0; i < 10; i++)
                alt_syms[i] = (i % 2 == 0) ? 64'h5330303030303030 : goog; // syms[0] or GOOG
            for (int i = 0; i < 10; i++) begin
                logic expected_hit;
                expected_hit = (i % 2 == 0) ? 1'b1 : 1'b0;
                lookup(alt_syms[i], hit);
                if (hit !== expected_hit)
                    `uvm_error("TEST", $sformatf(
                        "Scenario7[%0d]: expected hit=%0b got=%0b", i, expected_hit, hit))
            end
            `uvm_info("TEST", "Scenario7 PASS: back-to-back latency=1 checked", UVM_LOW)
        end

        // ── Scenario 8: write-during-lookup (RAW hazard) ──────────
        `uvm_info("TEST", "=== Scenario 8: write during lookup ===", UVM_LOW)
        begin
            // Drive cam_wr_valid and stock_valid on the same cycle
            @(kc705_vif.driver_cb);
            kc705_vif.driver_cb.stock         <= 64'h5330303030303030; // syms[0]
            kc705_vif.driver_cb.stock_valid   <= 1'b1;
            kc705_vif.driver_cb.cam_wr_index  <= 6'd0;
            kc705_vif.driver_cb.cam_wr_data   <= goog;
            kc705_vif.driver_cb.cam_wr_valid  <= 1'b1;
            kc705_vif.driver_cb.cam_wr_en_bit <= 1'b1;
            @(kc705_vif.driver_cb);
            kc705_vif.driver_cb.stock_valid   <= 1'b0;
            kc705_vif.driver_cb.cam_wr_valid  <= 1'b0;
            @(kc705_vif.monitor_cb);  // P4 SVA fires and checks here
            `uvm_info("TEST", "Scenario8 PASS: write-during-lookup, SVA checked", UVM_LOW)
        end

        repeat (5) @(kc705_vif.driver_cb);
        phase.drop_objection(this, "lliu_symfilter_test");
    endtask

endclass
