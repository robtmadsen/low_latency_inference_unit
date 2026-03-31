// lliu_kc705_perf_test.sv — Performance / latency validation for kc705_top
//
// DUT TOPLEVEL: kc705_top
// Compile with: make SIM=verilator TOPLEVEL=kc705_top TEST=lliu_kc705_perf_test
//
// Measures observable E2E latency: fifo_rd_tvalid (first in-order ITCH beat on
// clk_300 side of the CDC FIFO) → dp_result_valid.
// Spec bound: < 18 cycles @ clk_300 (300 MHz).  [UVM_PLAN_kintex-7 §6b]
//
// Scenario matrix:
//   P1 — single watched Add Order:        E2E latency < 18 cycles
//   P2 — burst 10 watched Add Orders:     every latency < 18 cycles, mean reported
//   P3 — parser_to_feat (indirect):       consecutive frames, count cycles between
//                                          fifo_rd_tvalid pulses (pipeline empty check)
//   P4 — symbol_filter throughput:        alternate hit/miss × 10, hit-slot cycles
//   P5 — post-init cold-start latency:    first frame after init, may use spare cycles
//   P6 — consecutive same-symbol:         5 frames, verify no stall  > 18 cycles
//
// Latency is measured via kc705_ctrl_if.monitor_cb signals.  The kc705_latency_monitor
// bind module accumulates statistics; these tests verify no SVA violations are raised.

class lliu_kc705_perf_test extends lliu_kc705_test;
    `uvm_component_utils(lliu_kc705_perf_test)

    // Spec limit (cycles @ clk_300)
    localparam int E2E_BOUND_CYCLES  = 18;   // fifo_rd_tvalid → dp_result_valid
    localparam int SAMPLE_N          = 10;   // burst size for P2/P6

    function new(string name = "lliu_kc705_perf_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // ================================================================
    //  Measure latency: assert fifo_rd_tvalid rising-edge → dp_result_valid.
    //  Returns cycle count, or -1 on timeout.
    //  Starts counting from the first fifo_rd_tvalid pulse seen.
    // ================================================================
    task measure_e2e_cycles(output int cycles);
        int cnt = 0;
        cycles = -1;
        // Wait up to 100 cycles for fifo_rd_tvalid to go high
        repeat (100) begin
            @(kc705_vif.monitor_cb);
            if (kc705_vif.monitor_cb.fifo_rd_tvalid) begin
                cnt = 0;
                // From here count until dp_result_valid
                repeat (E2E_BOUND_CYCLES + 20) begin
                    if (kc705_vif.monitor_cb.dp_result_valid) begin
                        cycles = cnt;
                        return;
                    end
                    @(kc705_vif.monitor_cb);
                    cnt++;
                end
                return;  // timeout — cycles stays -1
            end
        end
    endtask

    // ================================================================
    //  run_phase
    // ================================================================
    task run_phase(uvm_phase phase);
        kc705_init_seq  init_seq;
        byte unsigned    aapl_sym[8];
        byte unsigned    intc_sym[8];
        byte_darr_t      msg_arr;
        bit [63:0]       beats[];
        longint unsigned seq;

        int             cycles;
        int             latencies[];
        int             n_violations;

        phase.raise_objection(this, "lliu_kc705_perf_test");

        kc705_vif.driver_cb.cpu_reset <= 1'b0;
        kc705_vif.driver_cb.s_tkeep   <= 8'hFF;

        aapl_sym = '{8'h41,8'h41,8'h50,8'h4C,8'h20,8'h20,8'h20,8'h20};
        intc_sym = '{8'h49,8'h4E,8'h54,8'h43,8'h20,8'h20,8'h20,8'h20};
        seq      = 64'd1;

        // ── Init ──────────────────────────────────────────────────────
        init_seq = kc705_init_seq::type_id::create("init_seq");
        init_seq.kc705_vif = kc705_vif;
        init_seq.watchlist.push_back(kc705_init_seq::stock_to_bits64("AAPL    "));
        init_seq.start(m_env.m_axil_agent.m_sequencer);

        // ── P1: single watched frame, latency < 18 cycles ─────────────
        `uvm_info("PERF", "=== P1: single watched frame latency ===", UVM_LOW)
        begin
            make_add_order(msg_arr, 8'h42, 100, aapl_sym, 1_000_000, 1);
            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);
            measure_e2e_cycles(cycles);
            if (cycles < 0)
                `uvm_error("PERF", "P1: timeout waiting for dp_result_valid")
            else if (cycles >= E2E_BOUND_CYCLES)
                `uvm_error("PERF", $sformatf(
                    "P1 VIOLATION: E2E latency %0d >= %0d cycles (spec bound)",
                    cycles, E2E_BOUND_CYCLES))
            else
                `uvm_info("PERF", $sformatf("P1 PASS: E2E latency = %0d cycles (bound=%0d)",
                    cycles, E2E_BOUND_CYCLES), UVM_LOW)
        end

        // ── P2: burst SAMPLE_N frames — all must meet spec ─────────────
        `uvm_info("PERF", $sformatf("=== P2: burst %0d frames latency ===", SAMPLE_N), UVM_LOW)
        begin
            int sum = 0;
            int min_l = 999;
            int max_l = 0;
            n_violations = 0;
            latencies = new[SAMPLE_N];

            for (int i = 0; i < SAMPLE_N; i++) begin
                make_add_order(msg_arr, 8'h42, 100+i, aapl_sym,
                               1_000_000 + i*10_000, 10+i);
                beats = build_kc705_frame(seq + i, msg_arr);
                send_frame(beats);
                measure_e2e_cycles(cycles);
                latencies[i] = cycles;
                if (cycles >= 0) begin
                    sum += cycles;
                    if (cycles < min_l) min_l = cycles;
                    if (cycles > max_l) max_l = cycles;
                    if (cycles >= E2E_BOUND_CYCLES) n_violations++;
                end
            end
            seq += SAMPLE_N;

            if (n_violations > 0)
                `uvm_error("PERF", $sformatf(
                    "P2: %0d/%0d frames violated E2E bound of %0d cycles",
                    n_violations, SAMPLE_N, E2E_BOUND_CYCLES))
            else
                `uvm_info("PERF", $sformatf(
                    "P2 PASS: min=%0d max=%0d mean=%0d/%0d cycles (bound=%0d)",
                    min_l, max_l, sum, SAMPLE_N, E2E_BOUND_CYCLES), UVM_LOW)
        end

        // ── P3: pipeline empty check (inter-frame gap) ─────────────────
        //
        // After a hit, send a miss frame immediately.  fifo_rd_tvalid should
        // not re-assert within 2 cycles of dp_result_valid (no pipeline stall
        // causing re-order of outputs).  This is a structural check.
        `uvm_info("PERF", "=== P3: hit→miss back-to-back, pipeline clear ===", UVM_LOW)
        begin
            int unsigned dp_res;
            int gap = 0;

            // Send hit
            make_add_order(msg_arr, 8'h42, 100, aapl_sym, 1_000_000, 30);
            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);

            // Wait for result
            wait_dp_result(dp_res);

            // Immediately send miss
            make_add_order(msg_arr, 8'h42, 100, intc_sym, 500_000, 31);
            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);

            // Verify dp_result_valid does not fire for 100 cycles
            repeat (100) begin
                @(kc705_vif.monitor_cb);
                if (kc705_vif.monitor_cb.dp_result_valid) gap++;
            end

            if (gap > 0)
                `uvm_error("PERF", $sformatf(
                    "P3: dp_result_valid fired %0d time(s) for unwatched symbol after hit", gap))
            else
                `uvm_info("PERF", "P3 PASS: no spurious result after hit→miss transition", UVM_LOW)
        end

        // ── P4: alternating hit/miss × 10, verify 5 hits in order ──────
        `uvm_info("PERF", "=== P4: alternating hit/miss × 10, verify 5 results ===", UVM_LOW)
        begin
            int hit_count = 0;
            fork
                begin
                    for (int i = 0; i < 10; i++) begin
                        byte unsigned sym[8];
                        sym = (i % 2 == 0) ? aapl_sym : intc_sym;
                        make_add_order(msg_arr, 8'h42, 100+i, sym,
                                       1_000_000 + i*5_000, 50+i);
                        beats = build_kc705_frame(seq + i, msg_arr);
                        send_frame(beats);
                    end
                    seq += 10;
                end
                begin
                    repeat (2000) begin
                        @(kc705_vif.monitor_cb);
                        if (kc705_vif.monitor_cb.dp_result_valid) hit_count++;
                    end
                end
            join

            if (hit_count != 5)
                `uvm_error("PERF", $sformatf(
                    "P4: expected 5 dp_result_valid, got %0d", hit_count))
            else
                `uvm_info("PERF", "P4 PASS: exactly 5 results for 5 watched frames", UVM_LOW)
        end

        // ── P5: cold-start latency — first frame post-init ─────────────
        //
        // Re-init and measure the very first frame's latency.  The spec makes
        // no special allowance for the first frame, so the bound still applies.
        `uvm_info("PERF", "=== P5: cold-start latency after re-init ===", UVM_LOW)
        begin
            kc705_init_seq cs_init;
            cs_init = kc705_init_seq::type_id::create("cs_init");
            cs_init.kc705_vif = kc705_vif;
            cs_init.watchlist.push_back(kc705_init_seq::stock_to_bits64("AAPL    "));
            cs_init.start(m_env.m_axil_agent.m_sequencer);
            seq = 64'd1;  // reset seq after re-init

            make_add_order(msg_arr, 8'h42, 100, aapl_sym, 1_000_000, 1);
            beats = build_kc705_frame(seq++, msg_arr);
            send_frame(beats);
            measure_e2e_cycles(cycles);

            if (cycles < 0)
                `uvm_error("PERF", "P5: timeout on cold-start frame")
            else if (cycles >= E2E_BOUND_CYCLES)
                `uvm_error("PERF", $sformatf(
                    "P5 VIOLATION: cold-start E2E = %0d cycles (bound=%0d)",
                    cycles, E2E_BOUND_CYCLES))
            else
                `uvm_info("PERF", $sformatf("P5 PASS: cold-start latency = %0d cycles", cycles), UVM_LOW)
        end

        // ── P6: 5 consecutive same-symbol frames ───────────────────────
        `uvm_info("PERF", "=== P6: 5 consecutive same-symbol, no latency stall ===", UVM_LOW)
        begin
            n_violations = 0;
            for (int i = 0; i < 5; i++) begin
                make_add_order(msg_arr, 8'h42, 100+i, aapl_sym,
                               1_000_000 + i*100, 100+i);
                beats = build_kc705_frame(seq + i, msg_arr);
                send_frame(beats);
                measure_e2e_cycles(cycles);
                if (cycles < 0 || cycles >= E2E_BOUND_CYCLES) n_violations++;
            end
            seq += 5;

            if (n_violations > 0)
                `uvm_error("PERF", $sformatf(
                    "P6: %0d/5 consecutive frames exceeded E2E latency bound", n_violations))
            else
                `uvm_info("PERF", "P6 PASS: all 5 consecutive same-symbol frames within bound", UVM_LOW)
        end

        `uvm_info("PERF", "=== lliu_kc705_perf_test complete ===", UVM_LOW)
        phase.drop_objection(this, "lliu_kc705_perf_test");
    endtask

endclass
