// lliu_tx_backpressure_test.sv — TX backpressure auto-kill test for kc705_top
//
// DUT target: kc705_top (KINTEX7_SIM_GTX_BYPASS)
// Spec ref:   .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.7
//
// Exercises the TX backpressure kill-switch mechanism by running
// tx_backpressure_kill_seq:
//   1. Baseline: order passes with tready asserted.
//   2. Deassert tready > 64 cycles → kill arm.
//   3. Order while kill armed → must be blocked.
//   4. Assert tready ≥ 256 cycles → kill self-clear.
//   5. Order after self-clear → must pass.
//
// Compile/run:
//   make SIM=verilator TOPLEVEL=kc705_top TEST=lliu_tx_backpressure_test

class lliu_tx_backpressure_test extends lliu_base_test;
    `uvm_component_utils(lliu_tx_backpressure_test)

    virtual kc705_ctrl_if kc705_vif;

    function new(string name = "lliu_tx_backpressure_test", uvm_component parent = null);
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
        kc705_init_seq          init_seq;
        tx_backpressure_kill_seq bp_seq;

        phase.raise_objection(this, "lliu_tx_backpressure_test");

        kc705_vif.driver_cb.cpu_reset    <= 1'b0;
        kc705_vif.driver_cb.s_tkeep      <= 8'hFF;
        kc705_vif.driver_cb.m_axis_tready <= 1'b1;

        // ── Init ──────────────────────────────────────────────────
        `uvm_info("BP_TEST", "=== KC705 init ===", UVM_LOW)
        init_seq = kc705_init_seq::type_id::create("init_seq");
        init_seq.kc705_vif = kc705_vif;
        // Watchlist must contain "AAPL    " for tx_backpressure_kill_seq
        init_seq.watchlist.push_back(kc705_init_seq::stock_to_bits64("AAPL    "));
        init_seq.start(m_env.m_axil_agent.m_sequencer);

        // ── Run backpressure sequence ──────────────────────────────
        `uvm_info("BP_TEST", "=== Starting tx_backpressure_kill_seq ===", UVM_LOW)
        bp_seq = tx_backpressure_kill_seq::type_id::create("bp_seq");
        bp_seq.kc705_vif        = kc705_vif;
        bp_seq.m_axis_agent_sqr = m_env.m_axis_agent.m_sequencer;
        bp_seq.start(m_env.m_axil_agent.m_sequencer);

        // ── Report ─────────────────────────────────────────────────
        if (!bp_seq.baseline_ok || !bp_seq.kill_ok || !bp_seq.recovery_ok) begin
            `uvm_error("BP_TEST",
                $sformatf("TX backpressure kill test FAILED: baseline=%0b kill=%0b recovery=%0b",
                    bp_seq.baseline_ok, bp_seq.kill_ok, bp_seq.recovery_ok))
        end else begin
            `uvm_info("BP_TEST", "=== TX BACKPRESSURE KILL TEST PASS ===", UVM_LOW)
        end

        phase.drop_objection(this, "lliu_tx_backpressure_test");
    endtask

endclass
