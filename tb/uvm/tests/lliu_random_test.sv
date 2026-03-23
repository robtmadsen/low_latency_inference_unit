// lliu_random_test.sv — Constrained-random ITCH test
//
// Loads weights, sends 100 random Add Orders, scoreboard checks all.
// Exercises price ranges from penny to large cap.

class lliu_random_test extends lliu_base_test;
    `uvm_component_utils(lliu_random_test)

    function new(string name = "lliu_random_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        weight_load_seq       wgt_seq;
        itch_random_seq       rand_seq;
        axil_poll_status_seq  poll_seq;
        axil_read_seq         rd_seq;
        int num_orders;

        phase.raise_objection(this, "lliu_random_test");

        // Initialize golden model predictor
        m_env.m_predictor.init_golden_model();

        // ---- Load weights ----
        wgt_seq = weight_load_seq::type_id::create("wgt_seq");
        wgt_seq.weights = new[4];
        wgt_seq.weights[0] = 16'h3F80;  // 1.0
        wgt_seq.weights[1] = 16'h3F00;  // 0.5
        wgt_seq.weights[2] = 16'h3E80;  // 0.25
        wgt_seq.weights[3] = 16'h3E00;  // 0.125

        begin
            shortint unsigned pred_wgts[4];
            pred_wgts[0] = 16'h3F80;
            pred_wgts[1] = 16'h3F00;
            pred_wgts[2] = 16'h3E80;
            pred_wgts[3] = 16'h3E00;
            m_env.m_predictor.set_weights(pred_wgts);
        end

        wgt_seq.start(m_env.m_axil_agent.m_sequencer);
        `uvm_info("RANDOM", "Weights loaded", UVM_LOW)

        // ---- Send random Add Orders ----
        rand_seq = itch_random_seq::type_id::create("rand_seq");
        rand_seq.num_messages = 100;
        rand_seq.min_price = 1;
        rand_seq.max_price = 999999;
        rand_seq.start(m_env.m_axis_agent.m_sequencer);

        num_orders = rand_seq.num_messages;

        // ---- Poll/read results for each order ----
        for (int i = 0; i < num_orders; i++) begin
            poll_seq = axil_poll_status_seq::type_id::create("poll_seq");
            poll_seq.max_polls = 500;
            poll_seq.start(m_env.m_axil_agent.m_sequencer);

            if (poll_seq.timed_out) begin
                `uvm_error("RANDOM", $sformatf("Timeout waiting for result %0d", i))
                break;
            end

            rd_seq = axil_read_seq::type_id::create("rd_seq");
            rd_seq.addr = 32'h10;
            rd_seq.start(m_env.m_axil_agent.m_sequencer);
        end

        #10us;
        phase.drop_objection(this, "lliu_random_test");
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        `uvm_info("RANDOM", $sformatf("Random test: %0d comparisons, %0d mismatches",
                  m_env.m_scoreboard.m_total_compared,
                  m_env.m_scoreboard.m_total_mismatches), UVM_NONE)
        if (m_env.m_scoreboard.m_total_mismatches > 0)
            `uvm_error("RANDOM", $sformatf("Scoreboard reported %0d mismatches",
                       m_env.m_scoreboard.m_total_mismatches))
    endfunction
endclass
