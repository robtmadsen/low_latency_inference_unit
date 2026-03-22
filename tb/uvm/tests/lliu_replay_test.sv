// lliu_replay_test.sv — Real NASDAQ ITCH data replay UVM test
//
// Replays actual market data from data/tvagg_sample.bin through the DUT.
// Since the sample file has no Add Orders (only S, R, H, Y, P, U types),
// we inject synthetic Add Orders after the real data replay to verify
// end-to-end inference with scoreboard checking.
//
// Test flow:
// 1. Load known weights
// 2. Replay first N messages from real ITCH file (parser discards non-Add-Order)
// 3. Inject synthetic Add Orders and verify inference results
// 4. Scoreboard auto-checks all Add Order inferences

class lliu_replay_test extends lliu_base_test;
    `uvm_component_utils(lliu_replay_test)

    function new(string name = "lliu_replay_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        weight_load_seq       wgt_seq;
        itch_replay_seq       replay_seq;
        itch_replay_seq       synth_seq;
        axil_poll_status_seq  poll_seq;
        axil_read_seq         rd_seq;
        string                data_dir;

        phase.raise_objection(this, "lliu_replay_test");

        // Initialize golden model
        m_env.m_predictor.init_golden_model();

        // ---- Step 1: Load weights ----
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
        `uvm_info("REPLAY_TEST", "Weights loaded", UVM_LOW)

        // ---- Step 2: Replay real ITCH data ----
        // Get data directory from plusarg
        if (!$value$plusargs("DATA_DIR=%s", data_dir))
            data_dir = "../../data";

        replay_seq = itch_replay_seq::type_id::create("replay_seq");
        replay_seq.m_data_file = {data_dir, "/tvagg_sample.bin"};
        replay_seq.m_max_messages = 50;  // Replay first 50 messages

        `uvm_info("REPLAY_TEST", "Replaying real ITCH data (non-Add-Order messages)...", UVM_LOW)
        replay_seq.start(m_env.m_axis_agent.m_sequencer);
        `uvm_info("REPLAY_TEST", "Real data replay complete", UVM_LOW)

        // Small gap between replay and synthetic orders
        #100ns;

        // ---- Step 3: Inject synthetic Add Orders ----
        `uvm_info("REPLAY_TEST", "Injecting synthetic Add Orders...", UVM_LOW)
        synth_seq = itch_replay_seq::type_id::create("synth_seq");

        // Add Order 1: Buy AAPL at $150.00
        synth_seq.add_order(
            .order_ref(64'h0000_0000_0000_0001),
            .side(1),
            .price(15000),
            .shares(100),
            .stock("AAPL    ")
        );

        // Add Order 2: Sell MSFT at $400.00
        synth_seq.add_order(
            .order_ref(64'h0000_0000_0000_0002),
            .side(0),
            .price(40000),
            .shares(200),
            .stock("MSFT    ")
        );

        // Add Order 3: Buy GOOGL at $175.50
        synth_seq.add_order(
            .order_ref(64'h0000_0000_0000_0003),
            .side(1),
            .price(17550),
            .shares(50),
            .stock("GOOGL   ")
        );

        synth_seq.start(m_env.m_axis_agent.m_sequencer);
        `uvm_info("REPLAY_TEST", "Synthetic Add Orders sent", UVM_LOW)

        // ---- Step 4: Read results for each Add Order ----
        for (int i = 0; i < 3; i++) begin
            // Wait for inference completion
            poll_seq = axil_poll_status_seq::type_id::create("poll_seq");
            poll_seq.max_polls = 500;
            poll_seq.start(m_env.m_axil_agent.m_sequencer);

            if (poll_seq.timed_out) begin
                `uvm_error("REPLAY_TEST",
                    $sformatf("Timeout waiting for inference #%0d", i+1))
                break;
            end

            // Read result register
            rd_seq = axil_read_seq::type_id::create("rd_seq");
            rd_seq.addr = 32'h10;
            rd_seq.start(m_env.m_axil_agent.m_sequencer);

            `uvm_info("REPLAY_TEST",
                $sformatf("Inference #%0d result: 0x%08h", i+1, rd_seq.rdata), UVM_LOW)
        end

        #1us;  // Drain time
        phase.drop_objection(this, "lliu_replay_test");
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        `uvm_info("REPLAY_TEST",
            $sformatf("Replay test: %0d comparisons, %0d mismatches",
                      m_env.m_scoreboard.m_total_compared,
                      m_env.m_scoreboard.m_total_mismatches), UVM_NONE)
    endfunction
endclass
