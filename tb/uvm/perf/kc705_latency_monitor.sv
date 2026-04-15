// kc705_latency_monitor.sv — KC705 hot-path latency profiling monitor
//
// Bind target: kc705_top (inside `ifdef KC705_TOP_DUT in tb_top.sv)
//
// Four measurement channels (MAS §2.4 performance contract):
//
//   CH1 (clk_300): fifo_rd_tvalid first beat → dp_result_valid   < 18 cycles
//   CH2 (clk_300): parser_fields_valid        → feat_valid        < 5 cycles
//   CH3 (clk_300): stock_valid                → watchlist_hit     == 1 cycle
//   CH4 (clk_156): strip_header_done          → m_tvalid          ≤ 4 cycles
//       CH4 inputs are stubbed (tied to 1'b0 in bind until RTL engineer
//       annotates internal moldupp64_strip signals with (* keep = "true" *)).
//
// All bound checked at end-of-simulation (final block).  Violations are
// reported as $error (equal severity to UVM_ERROR).
//
// Spec ref: .github/arch/kintex-7/Kintex-7_MAS.md §2.4

`timescale 1ns/1ps

module kc705_latency_monitor (
    input logic clk_300,
    input logic rst,

    // CH1: FIFO → OUCH output
    input logic fifo_rd_tvalid,     // CDC FIFO read-side tvalid (first ITCH beat)
    input logic ouch_tvalid,        // OUCH m_axis_tvalid (inference → order entry)

    // CH2: parser → feature extractor  (internal — stub until RTL annotates)
    input logic parser_fields_valid, // 1'b0 stub in bind until available
    input logic feat_valid,          // 1'b0 stub

    // CH3: symbol filter  (internal — stub)
    input logic stock_valid,         // 1'b0 stub
    input logic watchlist_hit        // 1'b0 stub
);

    // ------------------------------------------------------------------
    // Cycle counter (clk_300 domain)
    // ------------------------------------------------------------------
    int unsigned cycle_count;
    always_ff @(posedge clk_300) begin
        if (rst) cycle_count <= 0;
        else     cycle_count <= cycle_count + 1;
    end

    // ------------------------------------------------------------------
    // CH1: fifo_rd_tvalid (first beat of new message) → dp_result_valid
    //      Bound: < 18 cycles @ clk_300
    // ------------------------------------------------------------------
    // Track whether we are inside a FIFO→result window
    int unsigned ch1_ingress_queue[$];
    int unsigned ch1_latencies[$];
    bit ch1_in_window;   // prevents re-triggering on the same message burst

    always_ff @(posedge clk_300) begin
        if (rst) begin
            ch1_ingress_queue.delete();
            ch1_latencies.delete();
            ch1_in_window <= 1'b0;
        end else begin
            // Record ingress on the first beat after idle
            if (fifo_rd_tvalid && !ch1_in_window) begin
                ch1_ingress_queue.push_back(cycle_count);
                ch1_in_window <= 1'b1;
            end
            // Clear window when FIFO becomes idle (no valid → new message next time)
            if (!fifo_rd_tvalid)
                ch1_in_window <= 1'b0;

            // Record egress
            if (ouch_tvalid && ch1_ingress_queue.size() > 0) begin
                automatic int unsigned lat =
                    cycle_count - ch1_ingress_queue.pop_front();
                ch1_latencies.push_back(lat);
            end
        end
    end

    // ------------------------------------------------------------------
    // CH2: parser_fields_valid → feat_valid
    //      Bound: < 5 cycles @ clk_300
    //      (stubbed — no-op when inputs tied to 0)
    // ------------------------------------------------------------------
    int unsigned ch2_ingress_queue[$];
    int unsigned ch2_latencies[$];

    always_ff @(posedge clk_300) begin
        if (rst) begin
            ch2_ingress_queue.delete();
            ch2_latencies.delete();
        end else begin
            if (parser_fields_valid)
                ch2_ingress_queue.push_back(cycle_count);
            if (feat_valid && ch2_ingress_queue.size() > 0) begin
                automatic int unsigned lat =
                    cycle_count - ch2_ingress_queue.pop_front();
                ch2_latencies.push_back(lat);
            end
        end
    end

    // ------------------------------------------------------------------
    // CH3: stock_valid → watchlist_hit (exactly 1 cycle)
    //      (stubbed — no-op when inputs tied to 0)
    // ------------------------------------------------------------------
    int unsigned ch3_latencies[$];
    int unsigned ch3_ingress_queue[$];
    int unsigned ch3_violations;

    initial ch3_violations = 0;

    always_ff @(posedge clk_300) begin
        if (rst) begin
            ch3_ingress_queue.delete();
            ch3_latencies.delete();
        end else begin
            if (stock_valid)
                ch3_ingress_queue.push_back(cycle_count);
            if (watchlist_hit && ch3_ingress_queue.size() > 0) begin
                automatic int unsigned start_cy = ch3_ingress_queue.pop_front();
                automatic int unsigned lat = cycle_count - start_cy;
                ch3_latencies.push_back(lat);
                if (lat != 1)
                    ch3_violations <= ch3_violations + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Stats helper
    // ------------------------------------------------------------------
    function automatic void compute_stats(
        input  int unsigned q[$],
        output int unsigned q_min, q_max, q_p99,
        output real         q_mean
    );
        int unsigned n;
        int unsigned sorted[];
        real sum;
        int  p99_idx;
        int  tmp;

        n = q.size();
        if (n == 0) begin
            q_min = 0; q_max = 0; q_p99 = 0; q_mean = 0.0;
            return;
        end
        sorted = new[n](q);
        // Bubble sort (small N expected)
        for (int i = 0; i < n; i++)
            for (int j = i+1; j < n; j++)
                if (sorted[j] < sorted[i]) begin
                    tmp       = sorted[i];
                    sorted[i] = sorted[j];
                    sorted[j] = tmp;
                end
        q_min = sorted[0];
        q_max = sorted[n-1];
        sum   = 0.0;
        foreach (sorted[i]) sum += sorted[i];
        q_mean  = sum / n;
        p99_idx = (int'(n * 99) / 100);
        if (p99_idx >= n) p99_idx = n - 1;
        q_p99   = sorted[p99_idx];
    endfunction

    // ------------------------------------------------------------------
    // End-of-simulation report and assertions
    // ------------------------------------------------------------------
    final begin : kc705_perf_report
        int unsigned min_l, max_l, p99_l;
        real mean_l;
        string pass_str;
        int    violations;

        $display("");
        $display("╔══════════════════════════════════════════════════════════╗");
        $display("║          kc705_latency_monitor — Performance Report     ║");
        $display("╠══════════════════════════════════════════════════════════╣");

        // ── CH1: FIFO → dp_result_valid ─────────────────────────────
        violations = 0;
        if (ch1_latencies.size() > 0) begin
            compute_stats(ch1_latencies, min_l, max_l, p99_l, mean_l);
            foreach (ch1_latencies[i])
                if (ch1_latencies[i] >= 18) violations++;
            pass_str = (violations == 0) ? "PASS" : "FAIL";
            $display("║  CH1  FIFO → OUCH tvalid       (bound < 18 cycles)     ║");
            $display("║    n=%0d  min=%0d  max=%0d  p99=%0d  mean=%.1f  [%s]",
                ch1_latencies.size(), min_l, max_l, p99_l, mean_l, pass_str);
            if (violations > 0)
                $error("kc705_latency_monitor CH1: %0d measurement(s) ≥ 18 cycles (MAS §2.4 violation)",
                    violations);
        end else begin
            $display("║  CH1  FIFO → OUCH tvalid   no samples collected    ║");
        end

        $display("╠══════════════════════════════════════════════════════════╣");

        // ── CH2: parser_fields_valid → feat_valid ───────────────────
        violations = 0;
        if (ch2_latencies.size() > 0) begin
            compute_stats(ch2_latencies, min_l, max_l, p99_l, mean_l);
            foreach (ch2_latencies[i])
                if (ch2_latencies[i] >= 5) violations++;
            pass_str = (violations == 0) ? "PASS" : "FAIL";
            $display("║  CH2  parser → feat_valid       (bound < 5 cycles)     ║");
            $display("║    n=%0d  min=%0d  max=%0d  p99=%0d  mean=%.1f  [%s]",
                ch2_latencies.size(), min_l, max_l, p99_l, mean_l, pass_str);
            if (violations > 0)
                $error("kc705_latency_monitor CH2: %0d measurement(s) ≥ 5 cycles",
                    violations);
        end else begin
            $display("║  CH2  parser → feat_valid        stubbed / no samples  ║");
        end

        $display("╠══════════════════════════════════════════════════════════╣");

        // ── CH3: stock_valid → watchlist_hit ────────────────────────
        if (ch3_latencies.size() > 0) begin
            compute_stats(ch3_latencies, min_l, max_l, p99_l, mean_l);
            pass_str = (ch3_violations == 0) ? "PASS" : "FAIL";
            $display("║  CH3  stock_valid → watchlist_hit  (bound = 1 cycle)   ║");
            $display("║    n=%0d  min=%0d  max=%0d  violations=%0d  [%s]",
                ch3_latencies.size(), min_l, max_l, ch3_violations, pass_str);
            if (ch3_violations > 0)
                $error("kc705_latency_monitor CH3: %0d watchlist_hit latency != 1 cycle",
                    ch3_violations);
        end else begin
            $display("║  CH3  stock_valid → watchlist_hit   stubbed / no data  ║");
        end

        $display("╠══════════════════════════════════════════════════════════╣");
        $display("║  CH4  strip_header_done → m_tvalid  stubbed (< 4 cycles) ║");
        $display("╚══════════════════════════════════════════════════════════╝");
        $display("");
    end

endmodule
