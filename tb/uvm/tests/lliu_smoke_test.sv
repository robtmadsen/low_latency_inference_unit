// lliu_smoke_test.sv — Single Add Order end-to-end UVM test
//
// 1. Load known weights via AXI4-Lite
// 2. Send one synthetic Add Order via AXI4-Stream
// 3. Wait for inference completion
// 4. Read result register
// 5. Scoreboard auto-checks via predictor

class lliu_smoke_test extends lliu_base_test;
    `uvm_component_utils(lliu_smoke_test)

    function new(string name = "lliu_smoke_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        weight_load_seq       wgt_seq;
        itch_replay_seq       itch_seq;
        axil_poll_status_seq  poll_seq;
        axil_read_seq         rd_seq;

        phase.raise_objection(this, "lliu_smoke_test");

        // Initialize golden model predictor
        m_env.m_predictor.init_golden_model();

        // ---- Step 1: Load weights ----
        // Known bfloat16 weights: [1.0, 0.5, 0.25, 0.125]
        // bfloat16(1.0)   = 0x3F80
        // bfloat16(0.5)   = 0x3F00
        // bfloat16(0.25)  = 0x3E80
        // bfloat16(0.125) = 0x3E00
        wgt_seq = weight_load_seq::type_id::create("wgt_seq");
        wgt_seq.weights = new[4];
        wgt_seq.weights[0] = 16'h3F80;  // 1.0
        wgt_seq.weights[1] = 16'h3F00;  // 0.5
        wgt_seq.weights[2] = 16'h3E80;  // 0.25
        wgt_seq.weights[3] = 16'h3E00;  // 0.125

        // Set weights in predictor for golden model comparison
        begin
            shortint unsigned pred_wgts[4];
            pred_wgts[0] = 16'h3F80;
            pred_wgts[1] = 16'h3F00;
            pred_wgts[2] = 16'h3E80;
            pred_wgts[3] = 16'h3E00;
            m_env.m_predictor.set_weights(pred_wgts);
        end

        wgt_seq.start(m_env.m_axil_agent.m_sequencer);
        `uvm_info("SMOKE", "Weights loaded", UVM_LOW)

        // ---- Step 2: Send one Add Order ----
        // Buy order for AAPL at price 15000 ($150.00 in ITCH fixed-point)
        itch_seq = itch_replay_seq::type_id::create("itch_seq");
        itch_seq.add_order(
            .order_ref(64'h0000_0000_0000_0001),
            .side(1),         // Buy
            .price(15000),
            .shares(100),
            .stock("AAPL    ")
        );
        itch_seq.start(m_env.m_axis_agent.m_sequencer);
        `uvm_info("SMOKE", "Add Order sent", UVM_LOW)

        // ---- Step 3: Wait for inference to complete ----
        `uvm_info("SMOKE", "Waiting for inference completion...", UVM_LOW)
        poll_seq = axil_poll_status_seq::type_id::create("poll_seq");
        poll_seq.max_polls = 200;
        poll_seq.start(m_env.m_axil_agent.m_sequencer);

        if (poll_seq.timed_out)
            `uvm_error("SMOKE", "Timeout waiting for inference completion")
        else
            `uvm_info("SMOKE", "Inference complete (result_ready=1, busy=0)", UVM_LOW)

        // ---- Step 4: Read result register ----
        rd_seq = axil_read_seq::type_id::create("rd_seq");
        rd_seq.addr = 32'h10;  // RESULT register
        rd_seq.start(m_env.m_axil_agent.m_sequencer);
        `uvm_info("SMOKE", $sformatf("Result register: 0x%08h", rd_seq.rdata), UVM_LOW)

        // Scoreboard comparison happens automatically via analysis ports

        #1us;  // Drain time
        phase.drop_objection(this, "lliu_smoke_test");
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        if (m_env.m_scoreboard.m_total_mismatches > 0)
            `uvm_error("SMOKE", $sformatf("Scoreboard reported %0d mismatches",
                       m_env.m_scoreboard.m_total_mismatches))
        `uvm_info("SMOKE", $sformatf("Smoke test: %0d comparisons, %0d mismatches",
                  m_env.m_scoreboard.m_total_compared,
                  m_env.m_scoreboard.m_total_mismatches), UVM_NONE)
    endfunction
endclass
