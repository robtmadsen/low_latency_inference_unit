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

    // ── KC705 / Kintex-7 coverage groups ────────────────────────────
    // moldupp64_cg: seq_state × msg_count
    // seq_state bins
    int mold_accepted;         // datagram accepted (no gap)
    int mold_drop_gap;         // dropped — seq_num gap detected
    int mold_drop_dup;         // dropped — duplicate seq_num
    // msg_count bins: how many ITCH messages were in the MoldUDP64 datagram
    int mold_msg_single;       // exactly 1 message
    int mold_msg_small;        // 2–4 messages
    int mold_msg_medium;       // 5–15 messages
    int mold_msg_large;        // 16+ messages
    // cross: seq_state × msg_count (accepted vs dropped, all msg sizes)
    int mold_cross_accept_single, mold_cross_accept_small;
    int mold_cross_accept_medium, mold_cross_accept_large;
    int mold_cross_drop_single,   mold_cross_drop_small;
    int mold_cross_drop_medium,   mold_cross_drop_large;

    // symbol_filter_cg: watchlist_hit × cam_occupancy × back_to_back_count
    int symf_hit;              // symbol matched watchlist
    int symf_miss;             // symbol not in watchlist
    int symf_cam_empty;        // 0 entries in CAM
    int symf_cam_sparse;       // 1–15 entries
    int symf_cam_dense;        // 16–63 entries
    int symf_cam_full;         // all 64 entries occupied
    int symf_b2b_single;       // single frame (no consecutive hits)
    int symf_b2b_pair;         // 2–3 consecutive hits
    int symf_b2b_run;          // 4+ consecutive hits

    // drop_on_full_cg: drop_type × inter-drop gap
    int drop_overflow;         // FIFO-full frame drop
    int drop_backpressure;     // backpressure-induced drop
    int drop_gap_near;         // < 5 frames between consecutive drops
    int drop_gap_medium;       // 5–19 frames between drops
    int drop_gap_far;          // 20+ frames between drops

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

        // KC705 coverage groups — initial zero
        mold_accepted = 0;   mold_drop_gap = 0;   mold_drop_dup = 0;
        mold_msg_single = 0; mold_msg_small = 0;
        mold_msg_medium = 0; mold_msg_large = 0;
        mold_cross_accept_single = 0; mold_cross_accept_small  = 0;
        mold_cross_accept_medium = 0; mold_cross_accept_large  = 0;
        mold_cross_drop_single   = 0; mold_cross_drop_small    = 0;
        mold_cross_drop_medium   = 0; mold_cross_drop_large    = 0;

        symf_hit  = 0; symf_miss = 0;
        symf_cam_empty = 0; symf_cam_sparse = 0;
        symf_cam_dense = 0; symf_cam_full   = 0;
        symf_b2b_single = 0; symf_b2b_pair = 0; symf_b2b_run = 0;

        drop_overflow   = 0; drop_backpressure = 0;
        drop_gap_near   = 0; drop_gap_medium = 0; drop_gap_far = 0;
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
    endfunction   // write

    // ── KC705 sampling APIs ─────────────────────────────────────────
    // Called by the KC705 scoreboard / monitor when it observes relevant events.

    // sample_moldupp64: called once per MoldUDP64 datagram arriving at moldupp64_strip
    //   accepted: 1 = forwarded, 0 = dropped
    //   reason:   1 = gap, 2 = duplicate (ignored if accepted=1)
    //   msg_count: number of ITCH messages in the datagram
    function void sample_moldupp64(bit accepted, int reason, int msg_count);
        if (accepted) begin
            mold_accepted++;
            if  (msg_count == 1)              begin mold_msg_single++; mold_cross_accept_single++; end
            else if (msg_count inside {[2:4]})  begin mold_msg_small++;  mold_cross_accept_small++;  end
            else if (msg_count inside {[5:15]}) begin mold_msg_medium++; mold_cross_accept_medium++; end
            else                               begin mold_msg_large++;  mold_cross_accept_large++;  end
        end else begin
            if (reason == 1) mold_drop_gap++;
            else             mold_drop_dup++;
            if  (msg_count == 1)              begin mold_msg_single++; mold_cross_drop_single++; end
            else if (msg_count inside {[2:4]})  begin mold_msg_small++;  mold_cross_drop_small++;  end
            else if (msg_count inside {[5:15]}) begin mold_msg_medium++; mold_cross_drop_medium++; end
            else                               begin mold_msg_large++;  mold_cross_drop_large++;  end
        end
    endfunction

    // sample_symbol_filter: called once per incoming ITCH message arriving at symbol_filter
    //   hit:         1 = matched watchlist entry, 0 = miss
    //   cam_entries: number of currently programmed CAM entries (0–64)
    //   consec_hits: count of consecutive hit messages (including this one)
    function void sample_symbol_filter(bit hit, int cam_entries, int consec_hits);
        if (hit) symf_hit++;
        else     symf_miss++;

        if      (cam_entries == 0)                symf_cam_empty++;
        else if (cam_entries inside {[1:15]})     symf_cam_sparse++;
        else if (cam_entries inside {[16:63]})    symf_cam_dense++;
        else                                      symf_cam_full++;

        if      (consec_hits <= 1)               symf_b2b_single++;
        else if (consec_hits inside {[2:3]})     symf_b2b_pair++;
        else                                     symf_b2b_run++;
    endfunction

    // sample_drop_on_full: called each time eth_axis_rx_wrap drops a frame
    //   is_backpressure: 1 = downstream backpressure triggered drop, 0 = FIFO full
    //   frames_since_last_drop: frames that arrived since the previous drop event
    function void sample_drop_on_full(bit is_backpressure, int frames_since_last_drop);
        if (is_backpressure) drop_backpressure++;
        else                 drop_overflow++;

        if      (frames_since_last_drop < 5)  drop_gap_near++;
        else if (frames_since_last_drop < 20) drop_gap_medium++;
        else                                  drop_gap_far++;
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
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, "║  KC705 — MoldUDP64 Coverage                     ║\n"};
        report = {report, $sformatf("║    Accepted:        %6d  %s                 ║\n",
                  mold_accepted,  mold_accepted  > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Drop-gap:        %6d  %s                 ║\n",
                  mold_drop_gap,  mold_drop_gap  > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Drop-dup:        %6d  %s                 ║\n",
                  mold_drop_dup,  mold_drop_dup  > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Msg×1:           %6d  %s                 ║\n",
                  mold_msg_single, mold_msg_single > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Msg×2-4:         %6d  %s                 ║\n",
                  mold_msg_small,  mold_msg_small  > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Msg×5-15:        %6d  %s                 ║\n",
                  mold_msg_medium, mold_msg_medium > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Msg×16+:         %6d  %s                 ║\n",
                  mold_msg_large,  mold_msg_large  > 0 ? "[hit]" : "[   ]")};
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, "║  KC705 — Symbol Filter Coverage                 ║\n"};
        report = {report, $sformatf("║    Hit:             %6d  %s                 ║\n",
                  symf_hit,  symf_hit  > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Miss:            %6d  %s                 ║\n",
                  symf_miss, symf_miss > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    CAM empty:       %6d  %s                 ║\n",
                  symf_cam_empty,  symf_cam_empty  > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    CAM sparse:      %6d  %s                 ║\n",
                  symf_cam_sparse, symf_cam_sparse > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    CAM dense:       %6d  %s                 ║\n",
                  symf_cam_dense, symf_cam_dense > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    CAM full:        %6d  %s                 ║\n",
                  symf_cam_full,  symf_cam_full  > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    B2B single:      %6d  %s                 ║\n",
                  symf_b2b_single, symf_b2b_single > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    B2B pair:        %6d  %s                 ║\n",
                  symf_b2b_pair,   symf_b2b_pair   > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    B2B run:         %6d  %s                 ║\n",
                  symf_b2b_run,    symf_b2b_run    > 0 ? "[hit]" : "[   ]")};
        report = {report, "╠══════════════════════════════════════════════════╣\n"};
        report = {report, "║  KC705 — Drop-on-Full Coverage                  ║\n"};
        report = {report, $sformatf("║    FIFO overflow:   %6d  %s                 ║\n",
                  drop_overflow,    drop_overflow    > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Backpressure:    %6d  %s                 ║\n",
                  drop_backpressure, drop_backpressure > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Gap <5:          %6d  %s                 ║\n",
                  drop_gap_near,   drop_gap_near   > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Gap 5-19:        %6d  %s                 ║\n",
                  drop_gap_medium, drop_gap_medium > 0 ? "[hit]" : "[   ]")};
        report = {report, $sformatf("║    Gap 20+:         %6d  %s                 ║\n",
                  drop_gap_far,    drop_gap_far    > 0 ? "[hit]" : "[   ]")};
        report = {report, "╚══════════════════════════════════════════════════╝\n"};

        `uvm_info("COVERAGE", report, UVM_LOW)
    endfunction
endclass
