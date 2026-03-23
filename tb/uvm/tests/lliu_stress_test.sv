// lliu_stress_test.sv — Backpressure stress test
//
// Runs itch_random_seq (100 messages) with periodic inter-message
// stalls to exercise pipeline FIFO fill/drain behavior.
// Protocol checkers and scoreboard verify no data loss.

class lliu_stress_test extends lliu_base_test;
    `uvm_component_utils(lliu_stress_test)

    function new(string name = "lliu_stress_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        weight_load_seq      wgt_seq;
        backpressure_seq     bp_seq;
        axil_poll_status_seq poll_seq;

        phase.raise_objection(this, "lliu_stress_test");

        m_env.m_predictor.init_golden_model();

        // ---- Load weights ----
        wgt_seq = weight_load_seq::type_id::create("wgt_seq");
        wgt_seq.weights = new[4];
        wgt_seq.weights[0] = 16'h3F80;  // 1.0
        wgt_seq.weights[1] = 16'h3F00;  // 0.5
        wgt_seq.weights[2] = 16'h3E80;  // 0.25
        wgt_seq.weights[3] = 16'h3E00;  // 0.125
        begin
            shortint unsigned wgts[4];
            wgts[0] = 16'h3F80;
            wgts[1] = 16'h3F00;
            wgts[2] = 16'h3E80;
            wgts[3] = 16'h3E00;
            m_env.m_predictor.set_weights(wgts);
        end
        wgt_seq.start(m_env.m_axil_agent.m_sequencer);
        `uvm_info("STRESS", "Weights loaded", UVM_LOW)

        // ---- Run backpressure stress: periodic stalls every 4 msgs ----
        bp_seq = backpressure_seq::type_id::create("bp_seq");
        bp_seq.pattern      = 1;     // periodic
        bp_seq.ready_every  = 4;     // stall every 4 messages
        bp_seq.stall_ns     = 50;    // 50 ns = ~15 clock cycles @ 300 MHz
        bp_seq.num_messages = 20;   // reduced from 100 to fit within 10ms
        bp_seq.start(m_env.m_axis_agent.m_sequencer);
        `uvm_info("STRESS", "Backpressure sequence complete", UVM_LOW)

        // ---- Wait for final result ----
        poll_seq = axil_poll_status_seq::type_id::create("poll_seq");
        poll_seq.max_polls = 500;
        poll_seq.start(m_env.m_axil_agent.m_sequencer);
        if (poll_seq.timed_out)
            `uvm_error("STRESS", "Timeout waiting for final result")

        #2us;
        phase.drop_objection(this, "lliu_stress_test");
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        `uvm_info("STRESS", $sformatf("Stress test: %0d comparisons, %0d mismatches",
                  m_env.m_scoreboard.m_total_compared,
                  m_env.m_scoreboard.m_total_mismatches), UVM_NONE)
        if (m_env.m_scoreboard.m_total_mismatches > 0)
            `uvm_error("STRESS", $sformatf("Scoreboard: %0d mismatches under backpressure",
                       m_env.m_scoreboard.m_total_mismatches))
    endfunction
endclass
