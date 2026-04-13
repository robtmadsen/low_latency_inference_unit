// lliu_risk_fuzz_test.sv — Risk-check fuzz test for kc705_top
//
// DUT target: kc705_top (KINTEX7_SIM_GTX_BYPASS)
// Spec ref:   .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.6, §4.10
//
// Runs risk_fuzz_seq which exercises:
//   - Price band out-of-bound (high and low)
//   - Fat-finger out-of-bound
//   - In-band pass
//   - Kill switch arm + block
//
// Compile/run:
//   make SIM=verilator TOPLEVEL=kc705_top TEST=lliu_risk_fuzz_test

class lliu_risk_fuzz_test extends lliu_base_test;
    `uvm_component_utils(lliu_risk_fuzz_test)

    virtual kc705_ctrl_if kc705_vif;

    function new(string name = "lliu_risk_fuzz_test", uvm_component parent = null);
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

    task run_phase(uvm_phase phase);
        kc705_init_seq  init_seq;
        risk_fuzz_seq   rf_seq;

        phase.raise_objection(this, "lliu_risk_fuzz_test");

        // ── Initialise DUT ─────────────────────────────────────────
        kc705_vif.driver_cb.cpu_reset    <= 1'b0;
        kc705_vif.driver_cb.s_tkeep      <= 8'hFF;
        kc705_vif.driver_cb.m_axis_tready <= 1'b1;

        `uvm_info("RISK_FUZZ_TEST", "=== KC705 init ===", UVM_LOW)
        init_seq = kc705_init_seq::type_id::create("init_seq");
        init_seq.kc705_vif = kc705_vif;
        // Watchlist must contain "AAPL    " for risk_fuzz_seq
        init_seq.watchlist.push_back(kc705_init_seq::stock_to_bits64("AAPL    "));
        init_seq.start(m_env.m_axil_agent.m_sequencer);

        // ── Run risk fuzz sequence ─────────────────────────────────
        `uvm_info("RISK_FUZZ_TEST", "=== Starting risk_fuzz_seq ===", UVM_LOW)
        rf_seq = risk_fuzz_seq::type_id::create("rf_seq");
        rf_seq.kc705_vif        = kc705_vif;
        rf_seq.m_axis_agent_sqr = m_env.m_axis_agent.m_sequencer;
        // Use tight thresholds: 10 bps band, 1000 share fat-finger
        rf_seq.band_bps         = 10;
        rf_seq.max_qty          = 1000;
        rf_seq.start(m_env.m_axil_agent.m_sequencer);

        // Check final metrics
        if (rf_seq.oob_leaked > 0)
            `uvm_error("RISK_FUZZ_TEST",
                $sformatf("%0d OOB order(s) leaked past risk check — FAIL", rf_seq.oob_leaked))
        if (rf_seq.inband_missed > 0)
            `uvm_error("RISK_FUZZ_TEST",
                $sformatf("%0d in-band order(s) incorrectly blocked — FAIL",
                    rf_seq.inband_missed))
        if (rf_seq.oob_leaked == 0 && rf_seq.inband_missed == 0)
            `uvm_info("RISK_FUZZ_TEST", "=== RISK FUZZ TEST PASS ===", UVM_LOW)

        phase.drop_objection(this, "lliu_risk_fuzz_test");
    endtask

endclass
