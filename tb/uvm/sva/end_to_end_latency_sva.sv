// end_to_end_latency_sva.sv — Full datapath latency contract for lliu_top
//
// Performance contract:
//   final AXI4-Stream beat accepted -> dp_result_valid must complete in
//   fewer than MAX_LATENCY_CYCLES cycles.

module end_to_end_latency_sva #(
    parameter int unsigned DEFAULT_MAX_LATENCY_CYCLES = 12
) (
    input logic clk,
    input logic rst,
    input logic s_axis_tvalid,
    input logic s_axis_tready,
    input logic s_axis_tlast,
    input logic dp_result_valid
);

    int unsigned cycle_count;
    int unsigned pending_starts[$];
    int unsigned latencies[$];
    int unsigned max_latency_cycles;

    initial begin
        max_latency_cycles = DEFAULT_MAX_LATENCY_CYCLES;
        void'($value$plusargs("LLIU_MAX_LATENCY=%d", max_latency_cycles));
        $display("Configured end-to-end latency limit: %0d cycles", max_latency_cycles);
    end

    always_ff @(posedge clk) begin
        if (rst)
            cycle_count <= 0;
        else
            cycle_count <= cycle_count + 1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            pending_starts.delete();
            latencies.delete();
        end else begin
            if (s_axis_tvalid && s_axis_tready && s_axis_tlast)
                pending_starts.push_back(cycle_count);

            if (dp_result_valid) begin
                if (pending_starts.size() == 0) begin
                    $error("SVA: dp_result_valid asserted without pending message ingress");
                end else begin
                    automatic int unsigned start_cycle = pending_starts.pop_front();
                    automatic int unsigned latency = cycle_count - start_cycle;
                    latencies.push_back(latency);
                    if (latency >= max_latency_cycles) begin
                        $error(
                            "SVA: AXIS tlast handshake -> dp_result_valid latency %0d cycles exceeds spec %0d",
                            latency,
                            max_latency_cycles
                        );
                    end
                end
            end

            if (pending_starts.size() > 0) begin
                if ((cycle_count - pending_starts[0]) >= max_latency_cycles) begin
                    $error(
                        "SVA: message pending for %0d cycles without dp_result_valid (spec %0d)",
                        cycle_count - pending_starts[0],
                        max_latency_cycles
                    );
                end
            end
        end
    end

    final begin
        if (latencies.size() == 0) begin
            $display("========== End-to-End Latency Report ==========");
            $display("  Limit:     %0d cycles", max_latency_cycles);
            $display("  No tlast -> dp_result_valid samples collected");
            $display("================================================");
        end else begin
            int unsigned min_lat;
            int unsigned max_lat;
            min_lat = latencies[0];
            max_lat = latencies[0];
            foreach (latencies[i]) begin
                if (latencies[i] < min_lat)
                    min_lat = latencies[i];
                if (latencies[i] > max_lat)
                    max_lat = latencies[i];
            end
            $display("========== End-to-End Latency Report ==========");
            $display("  Limit:     %0d cycles", max_latency_cycles);
            $display("  Samples:   %0d", latencies.size());
            $display("  Min:       %0d cycles", min_lat);
            $display("  Max:       %0d cycles", max_lat);
            $display("================================================");
        end
    end

endmodule