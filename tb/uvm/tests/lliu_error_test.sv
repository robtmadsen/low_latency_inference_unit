// lliu_error_test.sv — Parser error injection and recovery test
//
// Sends truncated, bad-type, and garbage messages via itch_error_seq,
// each followed by a valid Add Order to verify parser recovery.
// Scoreboard must match on the valid recovery messages.

class lliu_error_test extends lliu_base_test;
    `uvm_component_utils(lliu_error_test)

    function new(string name = "lliu_error_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        weight_load_seq      wgt_seq;
        itch_error_seq       err_seq;
        axil_poll_status_seq poll_seq;

        phase.raise_objection(this, "lliu_error_test");

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
        `uvm_info("ERR_TEST", "Weights loaded", UVM_LOW)

        // ---- Run error injection sequence ----
        err_seq = itch_error_seq::type_id::create("err_seq");
        err_seq.start(m_env.m_axis_agent.m_sequencer);
        `uvm_info("ERR_TEST", "Error injection complete", UVM_LOW)

        // ---- Wait for last valid result ----
        poll_seq = axil_poll_status_seq::type_id::create("poll_seq");
        poll_seq.max_polls = 300;
        poll_seq.start(m_env.m_axil_agent.m_sequencer);
        if (poll_seq.timed_out)
            `uvm_error("ERR_TEST", "Timeout waiting for final recovery result — parser may have hung")

        #2us;
        phase.drop_objection(this, "lliu_error_test");
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        `uvm_info("ERR_TEST", $sformatf("Error test: %0d comparisons, %0d mismatches",
                  m_env.m_scoreboard.m_total_compared,
                  m_env.m_scoreboard.m_total_mismatches), UVM_NONE)
        if (m_env.m_scoreboard.m_total_mismatches > 0)
            `uvm_error("ERR_TEST", "Scoreboard mismatch after error recovery")
    endfunction
endclass
