// end_to_end_latency_sva.sv — Full datapath latency contract
//
// Two variants selected at compile time via Makefile define:
//
//   LLIU_TOP_DUT  (default)
//     Measures from Add-Order message accepted by the ITCH parser
//     (parser_fields_valid → add_order_accepted port) to dp_result_valid.
//     Bound: < DEFAULT_MAX_LATENCY_CYCLES (default 15) @ clk_300.
//
//   KC705_TOP_DUT
//     Measures from the first beat delivered by the CDC async FIFO read side
//     (axis_async_fifo m_tvalid && m_tready → fifo_rd_tvalid port)
//     to dp_result_valid.  Bound: < 22 cycles @ clk_300.
//     The extra budget vs. the v1 bound accounts for ~5 FIFO CDC cycles and
//     1 symbol_filter lookup cycle.
//
// The Makefile passes +define+LLIU_TOP_DUT or +define+KC705_TOP_DUT depending
// on the TOPLEVEL variable.  If neither is defined both sections are active
// which is intentional only in full-chip simulations where both DUTs coexist.

module end_to_end_latency_sva #(
    parameter int unsigned DEFAULT_MAX_LATENCY_CYCLES = 15
) (
    input logic clk,
    input logic rst,
    // LLIU_TOP_DUT path: connect to parser_fields_valid
    input logic add_order_accepted,
    // KC705_TOP_DUT path: connect to axis_async_fifo m_tvalid & m_tready (beat 0)
    input logic fifo_rd_tvalid,
    input logic dp_result_valid
);

`ifdef LLIU_TOP_DUT
    // ----------------------------------------------------------------
    // v1 / lliu_top latency check  (12-cycle bound from parser output)
    // ----------------------------------------------------------------
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
            if (add_order_accepted)
                pending_starts.push_back(cycle_count);

            if (dp_result_valid) begin
                if (pending_starts.size() == 0) begin
                    $error("SVA [LLIU]: dp_result_valid asserted without pending message ingress");
                end else begin
                    automatic int unsigned start_cycle = pending_starts.pop_front();
                    automatic int unsigned latency = cycle_count - start_cycle;
                    latencies.push_back(latency);
                    if (latency >= max_latency_cycles) begin
                        $error(
                            "SVA [LLIU]: parser_fields_valid -> dp_result_valid latency %0d cycles exceeds spec %0d",
                            latency,
                            max_latency_cycles
                        );
                    end
                end
            end

            if (pending_starts.size() > 0) begin
                if ((cycle_count - pending_starts[0]) >= max_latency_cycles) begin
                    $error(
                        "SVA [LLIU]: message pending for %0d cycles without dp_result_valid (spec %0d)",
                        cycle_count - pending_starts[0],
                        max_latency_cycles
                    );
                end
            end
        end
    end

    final begin
        if (latencies.size() == 0) begin
            $display("========== End-to-End Latency Report (lliu_top) ===========");
            $display("  Limit:     %0d cycles", max_latency_cycles);
            $display("  No parser_fields_valid -> dp_result_valid samples collected");
            $display("===========================================================");
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
            $display("========== End-to-End Latency Report (lliu_top) ===========");
            $display("  Limit:     %0d cycles", max_latency_cycles);
            $display("  Samples:   %0d", latencies.size());
            $display("  Min:       %0d cycles", min_lat);
            $display("  Max:       %0d cycles", max_lat);
            $display("===========================================================");
        end
    end
`endif // LLIU_TOP_DUT

`ifdef KC705_TOP_DUT
    // ----------------------------------------------------------------
    // KC705 / kc705_top latency check  (18-cycle bound from FIFO read)
    // ----------------------------------------------------------------
    // Connect fifo_rd_tvalid to (axis_async_fifo.m_tvalid & m_tready)
    // in the tb_top bind for kc705_top.  The timer starts on the first
    // beat exiting the CDC FIFO and must complete before dp_result_valid
    // within 18 clk_300 cycles (spec MAS §2.4).

    localparam int unsigned KC705_MAX_LATENCY_CYCLES = 22;

    int unsigned kc705_cycle_count;
    int unsigned kc705_pending_starts[$];
    int unsigned kc705_latencies[$];

    always_ff @(posedge clk) begin
        if (rst)
            kc705_cycle_count <= 0;
        else
            kc705_cycle_count <= kc705_cycle_count + 1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            kc705_pending_starts.delete();
            kc705_latencies.delete();
        end else begin
            if (fifo_rd_tvalid)
                kc705_pending_starts.push_back(kc705_cycle_count);

            if (dp_result_valid) begin
                if (kc705_pending_starts.size() == 0) begin
                    $error("SVA [KC705]: dp_result_valid asserted without pending FIFO beat");
                end else begin
                    automatic int unsigned start_cycle = kc705_pending_starts.pop_front();
                    automatic int unsigned latency = kc705_cycle_count - start_cycle;
                    kc705_latencies.push_back(latency);
                    if (latency >= KC705_MAX_LATENCY_CYCLES) begin
                        $error(
                            "SVA [KC705]: FIFO beat 0 -> dp_result_valid latency %0d cycles exceeds spec %0d",
                            latency,
                            KC705_MAX_LATENCY_CYCLES
                        );
                    end
                end
            end

            if (kc705_pending_starts.size() > 0) begin
                if ((kc705_cycle_count - kc705_pending_starts[0]) >= KC705_MAX_LATENCY_CYCLES) begin
                    $error(
                        "SVA [KC705]: FIFO beat pending for %0d cycles without dp_result_valid (spec %0d)",
                        kc705_cycle_count - kc705_pending_starts[0],
                        KC705_MAX_LATENCY_CYCLES
                    );
                end
            end
        end
    end

    final begin
        if (kc705_latencies.size() == 0) begin
            $display("========== End-to-End Latency Report (kc705_top) ==========");
            $display("  Limit:     %0d cycles", KC705_MAX_LATENCY_CYCLES);
            $display("  No FIFO beat 0 -> dp_result_valid samples collected");
            $display("===========================================================");
        end else begin
            int unsigned min_lat;
            int unsigned max_lat;
            min_lat = kc705_latencies[0];
            max_lat = kc705_latencies[0];
            foreach (kc705_latencies[i]) begin
                if (kc705_latencies[i] < min_lat)
                    min_lat = kc705_latencies[i];
                if (kc705_latencies[i] > max_lat)
                    max_lat = kc705_latencies[i];
            end
            $display("========== End-to-End Latency Report (kc705_top) ==========");
            $display("  Limit:     %0d cycles", KC705_MAX_LATENCY_CYCLES);
            $display("  Samples:   %0d", kc705_latencies.size());
            $display("  Min:       %0d cycles", min_lat);
            $display("  Max:       %0d cycles", max_lat);
            $display("===========================================================");
        end
    end
`endif // KC705_TOP_DUT

endmodule