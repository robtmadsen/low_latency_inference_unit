// lliu_latency_monitor.sv — Cycle-accurate latency profiling monitor
//
// Bind module: attached to lliu_top to observe ingress handshake and
// result_valid egress. Computes per-message latency and reports
// min/max/mean/median/p99/stddev statistics at end of simulation.

module lliu_latency_monitor (
    input logic        clk,
    input logic        rst,
    // AXI4-Stream ingress handshake
    input logic        s_axis_tvalid,
    input logic        s_axis_tready,
    input logic        s_axis_tlast,
    // Dot-product result valid (egress)
    input logic        dp_result_valid
);

    // ------------------------------------------------------------------
    // Cycle counter
    // ------------------------------------------------------------------
    int unsigned cycle_count;

    always_ff @(posedge clk) begin
        if (rst)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    // ------------------------------------------------------------------
    // Ingress / egress timestamp tracking
    // ------------------------------------------------------------------
    int unsigned ingress_queue[$];  // queue of ingress timestamps
    int unsigned latencies[$];      // completed latency measurements
    int unsigned msg_count;

    initial begin
        msg_count = 0;
    end

    // Record ingress on tlast handshake (message fully received)
    always_ff @(posedge clk) begin
        if (!rst && s_axis_tvalid && s_axis_tready && s_axis_tlast) begin
            ingress_queue.push_back(cycle_count);
        end
    end

    // Record egress on dp_result_valid
    always_ff @(posedge clk) begin
        if (!rst && dp_result_valid) begin
            if (ingress_queue.size() > 0) begin
                automatic int unsigned ingress_ts = ingress_queue.pop_front();
                automatic int unsigned lat = cycle_count - ingress_ts;
                latencies.push_back(lat);
                msg_count <= msg_count + 1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Statistics computation and report (called from final block)
    // ------------------------------------------------------------------
    function automatic void compute_and_report();
        int unsigned n;
        int unsigned sorted_lat[];
        int unsigned min_lat, max_lat;
        real sum_lat, mean_lat, median_lat;
        real p50_lat, p99_lat;
        real variance, stddev_lat;
        int unsigned temp;

        n = latencies.size();
        if (n == 0) begin
            $display("");
            $display("========== Latency Profiler Report ==========");
            $display("  No latency data collected");
            $display("=============================================");
            return;
        end

        // Copy to sortable array
        sorted_lat = new[n];
        foreach (latencies[i])
            sorted_lat[i] = latencies[i];

        // Simple insertion sort (sufficient for verification)
        for (int i = 1; i < n; i++) begin
            temp = sorted_lat[i];
            for (int j = i - 1; j >= 0; j--) begin
                if (sorted_lat[j] > temp) begin
                    sorted_lat[j + 1] = sorted_lat[j];
                    if (j == 0) begin
                        sorted_lat[0] = temp;
                        temp = 0; // sentinel: already placed
                    end
                end else begin
                    sorted_lat[j + 1] = temp;
                    temp = 0; // sentinel: already placed
                    break;
                end
            end
            if (temp != 0)
                sorted_lat[0] = temp;
        end

        min_lat = sorted_lat[0];
        max_lat = sorted_lat[n - 1];

        // Mean
        sum_lat = 0.0;
        foreach (sorted_lat[i])
            sum_lat += real'(sorted_lat[i]);
        mean_lat = sum_lat / real'(n);

        // Median
        if (n % 2 == 0)
            median_lat = real'(sorted_lat[n/2 - 1] + sorted_lat[n/2]) / 2.0;
        else
            median_lat = real'(sorted_lat[n/2]);

        // Percentiles
        p50_lat = real'(sorted_lat[n / 2]);
        p99_lat = real'(sorted_lat[min_idx(int'(real'(n) * 0.99), n - 1)]);

        // Stddev (jitter)
        variance = 0.0;
        foreach (sorted_lat[i])
            variance += (real'(sorted_lat[i]) - mean_lat) ** 2;
        if (n > 1)
            stddev_lat = $sqrt(variance / real'(n - 1));
        else
            stddev_lat = 0.0;

        // Report
        $display("");
        $display("========== Latency Profiler Report ==========");
        $display("  Samples:   %0d", n);
        $display("  Min:       %0d cycles", min_lat);
        $display("  Max:       %0d cycles", max_lat);
        $display("  Mean:      %.1f cycles", mean_lat);
        $display("  Median:    %.1f cycles", median_lat);
        $display("  p50:       %0d cycles", sorted_lat[n / 2]);
        $display("  p99:       %0d cycles", sorted_lat[min_idx(int'(real'(n) * 0.99), n - 1)]);
        $display("  Stddev:    %.2f cycles (jitter)", stddev_lat);
        $display("=============================================");
    endfunction

    // Helper: return min of two ints
    function automatic int min_idx(int a, int b);
        return (a < b) ? a : b;
    endfunction

    // ------------------------------------------------------------------
    // Print report at end of simulation
    // ------------------------------------------------------------------
    final begin
        compute_and_report();
    end

endmodule
