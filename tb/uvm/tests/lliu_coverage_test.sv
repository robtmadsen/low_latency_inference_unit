// lliu_coverage_test.sv — Constrained-random coverage-closure test
//
// Closes remaining line-coverage gaps via weight randomization.
// The existing tests (smoke, replay, random, stress, error) use fixed
// weights with zero mantissa {1.0, 0.5, 0.25, 0.125}, which prevents:
//   - bfloat16_mul norm_shift (needs non-trivial mantissa product)
//   - fp32_acc deep renormalization (needs sign-diverse accumulation)
//   - fp32_acc exact cancellation (needs precisely opposing products)
//
// Strategy:
//   Phase 1 — Constrained-random weight loop:
//     Re-randomize weights across N_ITERS iterations with four constraint
//     flavours, send random orders, let natural diversity exercise all
//     arithmetic paths.
//   Phase 2 — Protocol edges (directed, one-shot):
//     Register-map corners (CTRL, unmapped) and parser truncation.
//     CR can't reach these — they need specific AXI-Lite / AXI-Stream ops.

class lliu_coverage_test extends lliu_base_test;
    `uvm_component_utils(lliu_coverage_test)

    localparam int N_ITERS      = 128;
    localparam int ORDERS_PER   = 4;

    function new(string name = "lliu_coverage_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
        weight_load_seq       wgt_seq;
        itch_replay_seq       order_seq;
        axil_poll_status_seq  poll_seq;
        axil_read_seq         rd_seq;
        regmap_edge_seq       regmap_seq;
        itch_edge_seq         itch_seq;

        shortint unsigned     w[4];
        longint unsigned      order_ref;

        phase.raise_objection(this, "lliu_coverage_test");
        m_env.m_predictor.init_golden_model();

        order_ref = 64'hCC00_0000_0000_0001;

        // ================================================================
        // Phase 1: Constrained-random arithmetic coverage
        // ================================================================
        `uvm_info("COV_TEST", "Phase 1: Constrained-random weight loop", UVM_LOW)

        for (int iter = 0; iter < N_ITERS; iter++) begin
            // ---- Constrained weight generation ----
            if (iter < 4) begin
                // Exact-cancellation: w[0] = +V, w[1] = -V, w[2..3] = 0
                // Guarantees sum_man == 0 on second MAC element
                bit [7:0] e = 8'($urandom_range(126, 140));
                bit [6:0] m = 7'($urandom_range(0, 127));
                w[0] = {1'b0, e, m};
                w[1] = {1'b1, e, m};
                w[2] = 16'h0000;
                w[3] = 16'h0000;
            end else if (iter < 36) begin
                // Cancellation-biased: same exponent, opposite signs, random mantissa
                // Diverse mantissa differences → different renorm depths
                bit [7:0] e = 8'($urandom_range(124, 142));
                w[0] = {1'b0, e, 7'($urandom_range(0, 127))};
                w[1] = {1'b1, e, 7'($urandom_range(0, 127))};
                w[2] = {1'b0, 8'($urandom_range(120, 145)), 7'($urandom_range(0, 127))};
                w[3] = {1'b1, 8'($urandom_range(120, 145)), 7'($urandom_range(0, 127))};
            end else if (iter < 52) begin
                // Exponent-diverse: different exponents create alignment shifts
                // Alignment shifts fill low mantissa bits → deeper renorm
                bit [7:0] e0 = 8'($urandom_range(128, 145));
                bit [7:0] e1 = e0 - 8'($urandom_range(1, 14));
                w[0] = {1'b0, e0, 7'($urandom_range(32, 127))};
                w[1] = {1'b1, e1, 7'($urandom_range(32, 127))};
                w[2] = {1'b0, 8'($urandom_range(125, 140)), 7'($urandom_range(0, 127))};
                w[3] = {1'b1, 8'($urandom_range(125, 140)), 7'($urandom_range(0, 127))};
            end else if (iter < 60) begin
                // Large-exponent: overflow path (r_exp_wide[8] in bfloat16_mul)
                // Needs weight_exp + feature_exp - 127 >= 256
                // Features from int_to_bf16(price) top out at exp ~157
                // So weight_exp >= 226 to reach overflow
                for (int k = 0; k < 4; k++) begin
                    w[k] = {1'($urandom_range(0,1)),
                            8'($urandom_range(220, 250)),
                            7'($urandom_range(0, 127))};
                end
            end else begin
                // Pure random: broad coverage, non-zero mantissa for norm_shift
                for (int k = 0; k < 4; k++) begin
                    w[k] = {1'($urandom_range(0,1)),
                            8'($urandom_range(115, 160)),
                            7'($urandom_range(0, 127))};
                end
            end

            // ---- Load weights ----
            wgt_seq = weight_load_seq::type_id::create("wgt_seq");
            wgt_seq.weights = new[4];
            for (int k = 0; k < 4; k++) wgt_seq.weights[k] = w[k];
            begin
                shortint unsigned pred_w[4];
                for (int k = 0; k < 4; k++) pred_w[k] = w[k];
                m_env.m_predictor.set_weights(pred_w);
            end
            wgt_seq.start(m_env.m_axil_agent.m_sequencer);

            // ---- Send random orders ----
            order_seq = itch_replay_seq::type_id::create("orders");
            for (int j = 0; j < ORDERS_PER; j++) begin
                int unsigned price = $urandom_range(1, 500000);
                bit          side  = $urandom_range(0, 1);
                order_seq.add_order(order_ref, side, price, 100, "COV     ");
                order_ref++;
            end
            order_seq.start(m_env.m_axis_agent.m_sequencer);

            // ---- Poll and read results ----
            for (int j = 0; j < ORDERS_PER; j++) begin
                poll_seq = axil_poll_status_seq::type_id::create("poll");
                poll_seq.max_polls = 500;
                poll_seq.start(m_env.m_axil_agent.m_sequencer);
                if (poll_seq.timed_out)
                    `uvm_warning("COV_TEST", $sformatf("iter=%0d order=%0d timeout", iter, j))
                rd_seq = axil_read_seq::type_id::create("rd");
                rd_seq.addr = 32'h10;
                rd_seq.start(m_env.m_axil_agent.m_sequencer);
            end

            if (iter % 32 == 31)
                `uvm_info("COV_TEST", $sformatf("Progress: %0d/%0d iterations", iter+1, N_ITERS), UVM_LOW)
        end

        // ================================================================
        // Phase 2: Protocol / control-path edges (directed)
        // ================================================================
        `uvm_info("COV_TEST", "Phase 2: Protocol edges (regmap + parser)", UVM_LOW)

        // Reload known-good weights for parser edge cases
        wgt_seq = weight_load_seq::type_id::create("wgt_proto");
        wgt_seq.weights = new[4];
        wgt_seq.weights[0] = 16'h3F80;
        wgt_seq.weights[1] = 16'h3F00;
        wgt_seq.weights[2] = 16'h3E80;
        wgt_seq.weights[3] = 16'h3E00;
        begin
            shortint unsigned pred_w[4];
            pred_w[0] = 16'h3F80; pred_w[1] = 16'h3F00;
            pred_w[2] = 16'h3E80; pred_w[3] = 16'h3E00;
            m_env.m_predictor.set_weights(pred_w);
        end
        wgt_seq.start(m_env.m_axil_agent.m_sequencer);

        // Parser edge cases (truncation, non-Add-Order, back-to-back)
        itch_seq = itch_edge_seq::type_id::create("itch_seq");
        itch_seq.start(m_env.m_axis_agent.m_sequencer);
        repeat (7) begin
            poll_seq = axil_poll_status_seq::type_id::create("poll");
            poll_seq.max_polls = 500;
            poll_seq.start(m_env.m_axil_agent.m_sequencer);
            if (poll_seq.timed_out)
                `uvm_warning("COV_TEST", "Poll timeout during parser edges")
            rd_seq = axil_read_seq::type_id::create("rd");
            rd_seq.addr = 32'h10;
            rd_seq.start(m_env.m_axil_agent.m_sequencer);
        end

        // Register-map edge cases (CTRL, unmapped, read-only writes)
        // LAST: soft_reset disrupts pipeline state
        regmap_seq = regmap_edge_seq::type_id::create("regmap_seq");
        regmap_seq.start(m_env.m_axil_agent.m_sequencer);

        `uvm_info("COV_TEST", "Coverage closure complete", UVM_LOW)
        #1us;
        phase.drop_objection(this, "lliu_coverage_test");
    endtask

    function void check_phase(uvm_phase phase);
        super.check_phase(phase);
        `uvm_info("COV_TEST", $sformatf("Coverage test: %0d comparisons, %0d mismatches",
                  m_env.m_scoreboard.m_total_compared,
                  m_env.m_scoreboard.m_total_mismatches), UVM_NONE)
    endfunction
endclass
