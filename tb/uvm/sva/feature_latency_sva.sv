// feature_latency_sva.sv — Parser-to-feature latency contract for lliu_top
//
// Performance contract:
//   parser_fields_valid -> feat_valid must complete in < 5 cycles.

module feature_latency_sva (
    input logic clk,
    input logic rst,
    input logic parser_fields_valid,
    input logic feat_valid
);

    int unsigned cycle_count;
    int unsigned pending_starts[$];
    int unsigned latencies[$];

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
            if (parser_fields_valid)
                pending_starts.push_back(cycle_count);

            if (feat_valid) begin
                if (pending_starts.size() == 0) begin
                    $error("SVA: feat_valid asserted without pending parser_fields_valid");
                end else begin
                    automatic int unsigned start_cycle = pending_starts.pop_front();
                    automatic int unsigned latency = cycle_count - start_cycle;
                    latencies.push_back(latency);
                    if (latency >= 5)
                        $error("SVA: parser_fields_valid -> feat_valid latency %0d cycles exceeds spec", latency);
                end
            end

            if (pending_starts.size() > 0) begin
                if ((cycle_count - pending_starts[0]) >= 5)
                    $error("SVA: parser_fields_valid pending for %0d cycles without feat_valid", cycle_count - pending_starts[0]);
            end
        end
    end

    final begin
        if (latencies.size() == 0) begin
            $display("========== Feature Latency Report ==========");
            $display("  No parser_fields_valid -> feat_valid samples collected");
            $display("============================================");
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
            $display("========== Feature Latency Report ==========");
            $display("  Samples:   %0d", latencies.size());
            $display("  Min:       %0d cycles", min_lat);
            $display("  Max:       %0d cycles", max_lat);
            $display("============================================");
        end
    end

endmodule