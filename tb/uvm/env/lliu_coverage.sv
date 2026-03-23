// lliu_coverage.sv — Functional coverage collector for LLIU
//
// Subscribes to AXI4-Stream monitor, parses ITCH Add Order fields,
// and tracks coverage bins for message type, price range, side, and
// the price_range × side cross.
//
// Note: SV covergroups are not supported by the open-source simulator,
// so coverage is tracked with explicit counters. A report is printed in
// report_phase.  The same bin structure mirrors the cocotb functional
// coverage for cross-methodology comparison.

class lliu_coverage extends uvm_subscriber #(axi4_stream_transaction);
    `uvm_component_utils(lliu_coverage)

    // ── Bin counters ────────────────────────────────────────────────
    // Message type
    int msg_type_add_order;   // 'A' = 0x41
    int msg_type_other;

    // Price range bins
    int price_penny;    // 1–99
    int price_dollar;   // 100–9999
    int price_large;    // 10000+

    // Side bins
    int side_buy;       // 'B'
    int side_sell;      // 'S'

    // Cross: price_range × side  (3 × 2 = 6 bins)
    int cross_penny_buy,  cross_penny_sell;
    int cross_dollar_buy, cross_dollar_sell;
    int cross_large_buy,  cross_large_sell;

    // Totals
    int total_sampled;

    function new(string name = "lliu_coverage", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        msg_type_add_order = 0;
        msg_type_other     = 0;
        price_penny  = 0;
        price_dollar = 0;
        price_large  = 0;
        side_buy  = 0;
        side_sell = 0;
        cross_penny_buy  = 0;  cross_penny_sell  = 0;
        cross_dollar_buy = 0;  cross_dollar_sell  = 0;
        cross_large_buy  = 0;  cross_large_sell   = 0;
        total_sampled    = 0;
    endfunction

    // ── Analysis port write callback ────────────────────────────────
    function void write(axi4_stream_transaction t);
        byte unsigned msg_bytes[];
        int byte_count;
        byte unsigned msg_type;
        int unsigned price;
        int side;

        // Convert AXI4-Stream beats to raw byte array (big-endian)
        byte_count = t.tdata.size() * 8;
        msg_bytes = new[byte_count];
        foreach (t.tdata[i])
            for (int b = 0; b < 8; b++)
                msg_bytes[i*8 + b] = t.tdata[i][63 - b*8 -: 8];

        // Need at least 3 bytes (2-byte length + 1-byte type)
        if (byte_count < 3) return;

        total_sampled++;
        msg_type = msg_bytes[2];

        // ── Message type coverage ───────────────────────────────
        if (msg_type == 8'h41) begin
            msg_type_add_order++;
        end else begin
            msg_type_other++;
            return;  // no further field coverage for non-Add-Order
        end

        // ── Parse Add Order fields ──────────────────────────────
        // Need 38 bytes minimum for a full Add Order with length prefix
        if (byte_count < 38) return;

        // Side at offset 21 ('B' = buy, 'S' = sell)
        side = (msg_bytes[21] == 8'h42) ? 1 : 0;

        // Price at offset 34..37 (big-endian 32-bit)
        price = 0;
        for (int i = 0; i < 4; i++)
            price = (price << 8) | msg_bytes[34 + i];

        // ── Side coverage ───────────────────────────────────────
        if (side == 1) side_buy++;
        else           side_sell++;

        // ── Price range coverage ────────────────────────────────
        if (price >= 1 && price <= 99) begin
            price_penny++;
            if (side == 1) cross_penny_buy++;
            else           cross_penny_sell++;
        end else if (price >= 100 && price <= 9999) begin
            price_dollar++;
            if (side == 1) cross_dollar_buy++;
            else           cross_dollar_sell++;
        end else if (price >= 10000) begin
            price_large++;
            if (side == 1) cross_large_buy++;
            else           cross_large_sell++;
        end
    endfunction

    // ── Coverage query ──────────────────────────────────────────────
    function int get_cross_bins_hit();
        int hit = 0;
        if (cross_penny_buy   > 0) hit++;
        if (cross_penny_sell  > 0) hit++;
        if (cross_dollar_buy  > 0) hit++;
        if (cross_dollar_sell > 0) hit++;
        if (cross_large_buy   > 0) hit++;
        if (cross_large_sell  > 0) hit++;
        return hit;
    endfunction

    function real get_cross_coverage_pct();
        return (get_cross_bins_hit() * 100.0) / 6.0;
    endfunction

    // ── Report ──────────────────────────────────────────────────────
    function void report_phase(uvm_phase phase);
        string report;
        int cross_hit;

        super.report_phase(phase);

        cross_hit = get_cross_bins_hit();

        report = "\n";
        report = {report, "╔══════════════════════════════════════════════════╗\n"};
        report = {report, "║         UVM Functional Coverage Report          ║\n"};
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, $sformatf("║  Total transactions sampled:  %6d            ║\n", total_sampled)};
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, "║  Message Type                                   ║\n"};
        report = {report, $sformatf("║    Add Order (A):    %6d  %s                 ║\n",
                  msg_type_add_order, msg_type_add_order > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Other:            %6d  %s                 ║\n",
                  msg_type_other, msg_type_other > 0 ? "[hit]" : "[   ]")};
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, "║  Price Range                                    ║\n"};
        report = {report, $sformatf("║    Penny   (1-99):   %6d  %s                 ║\n",
                  price_penny, price_penny > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Dollar  (100-9k): %6d  %s                 ║\n",
                  price_dollar, price_dollar > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Large   (10k+):   %6d  %s                 ║\n",
                  price_large, price_large > 0 ? "[hit]" : "[   ]")};
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, "║  Side                                           ║\n"};
        report = {report, $sformatf("║    Buy  (B):         %6d  %s                 ║\n",
                  side_buy, side_buy > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Sell (S):         %6d  %s                 ║\n",
                  side_sell, side_sell > 0 ? "[hit]" : "[   ]")};
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, "║  Cross: Price Range × Side                      ║\n"};
        report = {report, $sformatf("║    Penny  × Buy:     %6d  %s                 ║\n",
                  cross_penny_buy, cross_penny_buy > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Penny  × Sell:    %6d  %s                 ║\n",
                  cross_penny_sell, cross_penny_sell > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Dollar × Buy:     %6d  %s                 ║\n",
                  cross_dollar_buy, cross_dollar_buy > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Dollar × Sell:    %6d  %s                 ║\n",
                  cross_dollar_sell, cross_dollar_sell > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Large  × Buy:     %6d  %s                 ║\n",
                  cross_large_buy, cross_large_buy > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Large  × Sell:    %6d  %s                 ║\n",
                  cross_large_sell, cross_large_sell > 0 ? "[hit]" : "[   ]")};
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, $sformatf("║  Cross coverage: %0d/6 bins = %0.1f%%             ║\n",
                  cross_hit, get_cross_coverage_pct())};
        report = {report, "╚══════════════════════════════════════════════════╝\n"};

        `uvm_info("COVERAGE", report, UVM_LOW)
    endfunction
endclass
