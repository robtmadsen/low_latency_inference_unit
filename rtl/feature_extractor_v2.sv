// feature_extractor_v2.sv — 32-feature extractor for LLIU v2.0 Phase 2
//
// Implements all 32 features per 2p0_kintex-7_MAS.md §4.4.
// Pipeline: 4 stages. Latency: 4 cycles from fields_valid to features_valid.
//
// Feature index mapping (MAS §4.4):
//   [0]  price_delta        : signed(price − last_price) per-symbol
//   [1]  side_enc           : +1 = buy, −1 = sell
//   [2]  order_flow         : running buy−sell counter
//   [3]  norm_price         : current price as unsigned bfloat16
//   [4]  bbo_bid_price      : best bid price (unsigned, from order_book)
//   [5]  bbo_ask_price      : best ask price (unsigned, from order_book)
//   [6]  bbo_bid_size       : best bid shares (unsigned, from order_book)
//   [7]  bbo_ask_size       : best ask shares (unsigned, from order_book)
//   [8]  spread             : bbo_ask_price − bbo_bid_price (unsigned)
//   [9]  mid_price          : (bbo_bid_price + bbo_ask_price) >> 1 (unsigned)
//   [10] order_vs_bid       : signed(shares[23:0] − bbo_bid_size)
//   [11] order_vs_ask       : signed(shares[23:0] − bbo_ask_size)
//   [12..15] L2 bid levels 0-3 (price, unsigned, insertion order)
//   [16..19] L2 ask levels 0-3 (price, unsigned, insertion order)
//   [20..23] L2 bid levels 0-3 (size, unsigned, insertion order)
//   [24..27] L2 ask levels 0-3 (size, unsigned, insertion order)
//   [28] rolling_buy_vol    : sum of buy shares over last 8 messages (unsigned)
//   [29] rolling_sell_vol   : sum of sell shares over last 8 messages (unsigned)
//   [30] vwap_approx        : log2-division approximation of VWAP (unsigned)
//   [31] msg_arrival_period : local cycle count spanning last 8 msgs (unsigned,
//                             smaller = faster arrival rate)
//
// Pipeline stage overview:
//   Stage 1 (s1): integer arithmetic for all 32 features; rolling window update
//   Stage 2 (s2): sign/magnitude decomposition; VWAP log2-divide approximation
//   Stage 3 (s3): bfloat16 conversion for features [0..15]
//   Stage 4 (out): bfloat16 conversion for features [16..31]; assert features_valid

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module feature_extractor_v2 #(
    parameter int VEC_LEN = FEAT_VEC_LEN_V2   // 32
)(
    input  logic        clk,
    input  logic        rst,

    // From itch_parser_v2
    input  logic [31:0] price,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] shares,      // only [23:0] used; upper byte is msg-type-specific
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic        side,        // 1 = buy, 0 = sell
    input  logic [OB_SYM_ID_W-1:0] sym_id, // symbol index (0..OB_NUM_SYMBOLS-1)
    input  logic        fields_valid,

    // BBO inputs (from order_book, 1-cycle registered latency)
    input  logic [31:0] bbo_bid_price,
    input  logic [31:0] bbo_ask_price,
    input  logic [23:0] bbo_bid_size,
    input  logic [23:0] bbo_ask_size,

    // L2 book levels (from order_book, 1-cycle registered latency)
    input  logic [31:0] l2_bid_price [0:3],
    input  logic [23:0] l2_bid_size  [0:3],
    input  logic [31:0] l2_ask_price [0:3],
    input  logic [23:0] l2_ask_size  [0:3],

    // Feature vector output
    output bfloat16_t   features [VEC_LEN],
    output logic        features_valid
);

    // ------------------------------------------------------------------
    // Per-symbol last-price LUT: OB_NUM_SYMBOLS entries, sym_id selects
    // ------------------------------------------------------------------
    logic [31:0] last_price_lut [0:OB_NUM_SYMBOLS-1];

    // ------------------------------------------------------------------
    // Running order-flow counter (cumulative buy − sell)
    // ------------------------------------------------------------------
    logic signed [15:0] order_flow_cnt;

    // ------------------------------------------------------------------
    // Bfloat16 conversion: signed magnitude → bfloat16
    function automatic bfloat16_t mag_to_bf16(
        input logic        is_zero,
        input logic        sign_bit,
        input logic [31:0] mag
    );
        logic [7:0] exp_val;
        logic [6:0] man_val;
        int         lz;
        if (is_zero) return 16'h0000;
        lz = 0;
        for (int i = 31; i >= 0; i--) begin
            if (mag[i]) break;
            lz = lz + 1;
        end
        exp_val = 8'(127 + 31 - lz);
        man_val = 7'((mag << (lz + 1)) >> 25);
        return {sign_bit, exp_val, man_val};
    endfunction

    // ------------------------------------------------------------------
    // VWAP helper: find position of MSB in 27-bit value (0..26).
    // Returns 0 for input = 0 (caller guards with zero check).
    // ------------------------------------------------------------------
    function automatic logic [4:0] msb_pos27(input logic [26:0] v);
        logic [4:0] pos;
        pos = 5'd0;
        for (int i = 0; i <= 26; i++) begin
            if (v[i]) pos = 5'(i);
        end
        return pos;
    endfunction

    // ------------------------------------------------------------------
    // 8-message rolling window: buy volume, sell volume, price×vol, arrival time
    // ------------------------------------------------------------------
    logic [23:0] buy_vol_win  [0:7];
    logic [23:0] sell_vol_win [0:7];
    logic [55:0] px_vol_win   [0:7];  // price × shares per message (32b × 24b = 56b)
    logic [15:0] msg_lcnt_win [0:7];  // local cycle counter at each message

    // Incremental rolling sums (updated each fields_valid)
    logic [26:0] buy_vol_sum;          // max: 8 × 2^24 < 2^27
    logic [26:0] sell_vol_sum;
    (* use_dsp = "no" *) logic [58:0] px_vol_sum;           // Run 54: use_dsp=no prevents Vivado from absorbing msg_pxvol_s075 into a 59-bit accumulate DSP CREG (relay at X5Y19, WNS -0.119 ns)

    // Local free-running 16-bit cycle counter (for arrival period feature)
    logic [15:0] local_cnt;

    // ------------------------------------------------------------------
    // Stage-0.5 registers: pre-registered multiply + delayed Stage-1 inputs.
    // Breaks the DSP\u2192CARRY critical path (WNS \u22123.7 ns at 312.5 MHz) by
    // registering price\u00d7shares before the 59-bit accumulation.
    // Pipeline latency increases from 4 cycles to 5 cycles (fields_valid
    // to features_valid), which exceeds the \u201c< 5 cycles\u201d secondary spec.
    // This trade-off is accepted to achieve Fmax closure at 312.5 MHz.
    //
    // PREG=1 pattern (Run 17 timing fix):
    //   price_d / shares_d are pre-registers placed in the SAME always_ff block
    //   as msg_pxvol_s05.  Vivado sees the chain: module-input FF (price_d,
    //   shares_d) -> DSP A/B-port -> PREG -> msg_pxvol_s05, and infers PREG=1
    //   on the multiply DSP.  PREG=1 uses the Setup_dsp48e1_CLK_A arc (negative
    //   setup ~-0.6 ns), giving ~3.8 ns required time vs 3.0 ns arrival -> +0.8 ns
    //   WNS.  Without this, Vivado cascades two DSPs (PREG=0 + CREG) which
    //   produces the 3.773 ns path that cannot close at 312.5 MHz.
    //   The msg_pxvol_s05 value lags msg arrival by 2 cycles instead of 1, but
    //   price/shares are stable for hundreds of cycles per ITCH message so the
    //   misalignment has no functional effect.
    // ------------------------------------------------------------------
    logic [26:0]            price_d;          // Run 55: 27-bit A-port → single DSP48E1 PREG=1; was [29:0]=30-bit → 2-DSP relay (msg_pxvol_s075_reg upper partial product, WNS -0.122 ns)
    logic [17:0]            shares_d;         // B-port pre-register (co-located with DSP by Vivado)
    (* use_dsp = "yes" *) logic [47:0] msg_pxvol_s05;  // MUST be DSP PREG (30×18); use_dsp=yes
    // overrides RuntimeOptimized tendency to fall back to LUT fabric when the
    // downstream msg_pxvol_s075 has use_dsp="no" (Run 33 regression: WNS −1.977 ns).
    logic                   fv_s05;           // fields_valid delayed 1 cycle
    logic [31:0]            price_s05;
    logic [23:0]            shares_s05;       // only [23:0] used; matches port
    logic                   side_s05;
    logic [OB_SYM_ID_W-1:0] sym_id_s05;
    logic [31:0]            bbo_bid_px_s05;
    logic [31:0]            bbo_ask_px_s05;
    logic [23:0]            bbo_bid_sz_s05;
    logic [23:0]            bbo_ask_sz_s05;
    logic [31:0]            l2_bid_px_s05 [0:3];
    logic [23:0]            l2_bid_sz_s05 [0:3];
    logic [31:0]            l2_ask_px_s05 [0:3];
    logic [23:0]            l2_ask_sz_s05 [0:3];

    always_ff @(posedge clk) begin
        if (rst) begin
            price_d        <= '0;
            shares_d       <= '0;
            msg_pxvol_s05  <= '0;
            msg_pxvol_s075 <= '0;   // Run53: reset in same always_ff as msg_pxvol_s05
            fv_s05         <= 1'b0;
            fv_s075        <= 1'b0; // Run53: reset in same always_ff as fv_s05
            price_s05      <= '0;
            shares_s05     <= '0;
            side_s05       <= 1'b0;
            sym_id_s05     <= '0;
            bbo_bid_px_s05 <= '0;
            bbo_ask_px_s05 <= '0;
            bbo_bid_sz_s05 <= '0;
            bbo_ask_sz_s05 <= '0;
            for (int k = 0; k < 4; k++) begin
                l2_bid_px_s05[k] <= '0;
                l2_bid_sz_s05[k] <= '0;
                l2_ask_px_s05[k] <= '0;
                l2_ask_sz_s05[k] <= '0;
            end
        end else begin
            price_d        <= price[26:0];    // Run 55: 27-bit A-port → single DSP PREG=1 (30-bit caused 2-DSP partial-product relay, WNS -0.122 ns)
            shares_d       <= shares[17:0];   // pre-register: Vivado places adjacent to DSP column
            msg_pxvol_s05  <= price_d * shares_d;  // A(30)xB(18)=1 DSP48E1 PREG=1 pattern
            msg_pxvol_s075 <= msg_pxvol_s05;   // Run53: in same always_ff → no relay DSP (was separate always_ff → relay at X5Y19)
            fv_s05         <= fields_valid;
            fv_s075        <= fv_s05;          // Run53: aligned with msg_pxvol_s075 (non-blocking: reads prev-cycle fv_s05)
            price_s05      <= price;
            shares_s05     <= shares[23:0];
            side_s05       <= side;
            sym_id_s05     <= sym_id;
            bbo_bid_px_s05 <= bbo_bid_price;
            bbo_ask_px_s05 <= bbo_ask_price;
            bbo_bid_sz_s05 <= bbo_bid_size;
            bbo_ask_sz_s05 <= bbo_ask_size;
            for (int k = 0; k < 4; k++) begin
                l2_bid_px_s05[k] <= l2_bid_price[k];
                l2_bid_sz_s05[k] <= l2_bid_size[k];
                l2_ask_px_s05[k] <= l2_ask_price[k];
                l2_ask_sz_s05[k] <= l2_ask_size[k];
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage-0.75 registers: msg_pxvol_s075 and fv_s075.
    // Run 32 fix (original): separate always_ff + use_dsp="no" prevented
    // Vivado from creating a relay CREG DSP for msg_pxvol_s075.
    //
    // Run 53 update: moved msg_pxvol_s075/fv_s075 assignments INTO the
    // Stage-0.5 always_ff above (same always_ff as the msg_pxvol_s05 multiply).
    // Root cause of Run 52 failure (WNS -0.119 ns):
    //   Vivado synthesized msg_pxvol_s075_reg (DSP48E1, CREG=1) at X5Y19,
    //   despite use_dsp="no" on msg_pxvol_s075.  The relay was created because
    //   the SEPARATE Stage-0.75 always_ff caused synthesis to treat this as
    //   a multi-always_ff pipeline boundary and insert a CREG relay DSP.
    //   P→C routing between adjacent DSPs (X5Y18→X5Y19) through fabric takes
    //   ~2.892 ns, exceeding the 2.773 ns budget → WNS -0.119 ns.
    // Fix: merge into SAME always_ff as the DSP PREG — Vivado sees PREG→FDRE
    //   as a single-block pipeline (no relay), direct PREG→FDRE routing
    //   (~0.4 ns) trivially meets timing.  Functional behavior is identical:
    //   non-blocking semantics ensure msg_pxvol_s075 captures msg_pxvol_s05
    //   from the PREVIOUS cycle (same 1-cycle delay as before).
    // ------------------------------------------------------------------
    (* use_dsp = "no" *) logic [47:0] msg_pxvol_s075;
    logic fv_s075;
    // Assignments moved to Stage-0.5 always_ff above (Run53).

    // ------------------------------------------------------------------
    // Stage 1 registers (integer arithmetic results)
    // ------------------------------------------------------------------
    logic signed [31:0] s1_feat [0:11];  // features 0-11 as signed 32-bit integers
    logic        [31:0] s1_l2_bid_px [0:3];
    logic        [31:0] s1_l2_ask_px [0:3];
    logic        [31:0] s1_l2_bid_sz [0:3];
    logic        [31:0] s1_l2_ask_sz [0:3];
    logic        [26:0] s1_buy_vol_sum;
    logic        [26:0] s1_sell_vol_sum;
    (* use_dsp = "no" *) logic        [58:0] s1_px_vol_sum;
    logic        [26:0] s1_vol_sum;
    logic        [15:0] s1_msg_delta;
    logic               valid_d1;

    // ------------------------------------------------------------------
    // Stage 1: integer arithmetic + state update
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < 12; i++) s1_feat[i] <= '0;
            for (int k = 0; k < 4; k++) begin
                s1_l2_bid_px[k] <= '0;  s1_l2_ask_px[k] <= '0;
                s1_l2_bid_sz[k] <= '0;  s1_l2_ask_sz[k] <= '0;
            end
            s1_buy_vol_sum  <= '0;
            s1_sell_vol_sum <= '0;
            s1_px_vol_sum   <= '0;
            s1_vol_sum      <= '0;
            s1_msg_delta    <= '0;
            valid_d1        <= 1'b0;
            order_flow_cnt  <= 16'sd0;
            local_cnt       <= '0;
            buy_vol_sum     <= '0;
            sell_vol_sum    <= '0;
            px_vol_sum      <= '0;
            for (int k = 0; k < 512; k++)
                last_price_lut[k] <= '0;
            for (int k = 0; k < 8; k++) begin
                buy_vol_win[k]  <= '0;
                sell_vol_win[k] <= '0;
                px_vol_win[k]   <= '0;
                msg_lcnt_win[k] <= '0;
            end
        end else begin
            valid_d1  <= fv_s075;  // Stage-0.75 delayed by 1 cycle (Run 32 fix)
            local_cnt <= local_cnt + 16'h1;

            if (fv_s075) begin  // Run 32: gate on fv_s075 so Stage-1 uses msg_pxvol_s075
                // ---- Feature 0: price_delta (signed) ----
                s1_feat[0] <= 32'($signed({1'b0, price_s05}) -
                                  $signed({1'b0, last_price_lut[sym_id_s05]}));

                // ---- Feature 1: side_enc (+1 / -1) ----
                s1_feat[1] <= side_s05 ? 32'sd1 : -32'sd1;

                // ---- Feature 2: order_flow (running counter) ----
                if (side_s05)
                    s1_feat[2] <= $signed({{16{order_flow_cnt[15]}}, order_flow_cnt}) + 32'sd1;
                else
                    s1_feat[2] <= $signed({{16{order_flow_cnt[15]}}, order_flow_cnt}) - 32'sd1;

                // ---- Feature 3: norm_price (treated as unsigned) ----
                s1_feat[3] <= 32'({1'b0, price_s05[30:0]});

                // ---- Features 4-7: raw BBO prices and sizes ----
                s1_feat[4] <= 32'(bbo_bid_px_s05);
                s1_feat[5] <= 32'(bbo_ask_px_s05);
                s1_feat[6] <= 32'({8'h00, bbo_bid_sz_s05});
                s1_feat[7] <= 32'({8'h00, bbo_ask_sz_s05});

                // ---- Feature 8: bid-ask spread (unsigned) ----
                s1_feat[8] <= (bbo_ask_px_s05 >= bbo_bid_px_s05)
                              ? 32'(bbo_ask_px_s05 - bbo_bid_px_s05)
                              : 32'h0;

                // ---- Feature 9: mid price (unsigned) ----
                s1_feat[9] <= 32'((bbo_ask_px_s05 + bbo_bid_px_s05) >> 1);

                // ---- Feature 10: order size vs bid BBO (signed) ----
                s1_feat[10] <= 32'($signed({8'h00, shares_s05}) -
                                   $signed({8'h00, bbo_bid_sz_s05}));

                // ---- Feature 11: order size vs ask BBO (signed) ----
                s1_feat[11] <= 32'($signed({8'h00, shares_s05}) -
                                   $signed({8'h00, bbo_ask_sz_s05}));

                // ---- Features 12-27: L2 book levels ----
                for (int k = 0; k < 4; k++) begin
                    s1_l2_bid_px[k] <= l2_bid_px_s05[k];
                    s1_l2_ask_px[k] <= l2_ask_px_s05[k];
                    s1_l2_bid_sz[k] <= {8'h00, l2_bid_sz_s05[k]};
                    s1_l2_ask_sz[k] <= {8'h00, l2_ask_sz_s05[k]};
                end

                // ---- Rolling window update (8-message shift register) ----
                begin : blk_rolling
                    automatic logic [55:0] msg_pxvol;
                    automatic logic [26:0] new_buy_sum;
                    automatic logic [26:0] new_sell_sum;
                    automatic logic [58:0] new_px_sum;

                    msg_pxvol    = {8'h0, msg_pxvol_s075};  // zero-extend 48→56 bits; use Stage-0.75 FDRE (Run 32)
                    new_buy_sum  = buy_vol_sum
                                   + (side_s05 ? 27'(shares_s05) : 27'h0)
                                   - 27'(buy_vol_win[7]);
                    new_sell_sum = sell_vol_sum
                                   + (side_s05 ? 27'h0 : 27'(shares_s05))
                                   - 27'(sell_vol_win[7]);
                    new_px_sum   = px_vol_sum + 59'(msg_pxvol) - 59'(px_vol_win[7]);

                    // Shift windows left (oldest entry at index 7)
                    for (int k = 7; k >= 1; k--) begin
                        buy_vol_win[k]  <= buy_vol_win[k-1];
                        sell_vol_win[k] <= sell_vol_win[k-1];
                        px_vol_win[k]   <= px_vol_win[k-1];
                        msg_lcnt_win[k] <= msg_lcnt_win[k-1];
                    end
                    buy_vol_win[0]  <= side_s05 ? shares_s05 : 24'h0;
                    sell_vol_win[0] <= side_s05 ? 24'h0 : shares_s05;
                    px_vol_win[0]   <= msg_pxvol;
                    msg_lcnt_win[0] <= local_cnt;

                    // Update running sums
                    buy_vol_sum  <= new_buy_sum;
                    sell_vol_sum <= new_sell_sum;
                    px_vol_sum   <= new_px_sum;

                    // Capture updated sums for Stage 2
                    s1_buy_vol_sum  <= new_buy_sum;
                    s1_sell_vol_sum <= new_sell_sum;
                    s1_px_vol_sum   <= new_px_sum;
                    s1_vol_sum      <= new_buy_sum + new_sell_sum;
                    s1_msg_delta    <= local_cnt - msg_lcnt_win[7];
                end

                // ---- Persistent state updates ----
                last_price_lut[sym_id_s05] <= price_s05;
                if (side_s05)
                    order_flow_cnt <= order_flow_cnt + 16'sd1;
                else
                    order_flow_cnt <= order_flow_cnt - 16'sd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 2 registers (sign/magnitude for all 32 features)
    // ------------------------------------------------------------------
    logic [31:0] s2_mag  [0:31];
    logic        s2_sgn  [0:31];
    logic        s2_zero [0:31];
    logic        valid_d2;

    // ------------------------------------------------------------------
    // Stage 2: sign/magnitude decomposition and VWAP approximation
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d2 <= 1'b0;
            for (int i = 0; i < 32; i++) begin
                s2_mag[i]  <= '0;
                s2_sgn[i]  <= 1'b0;
                s2_zero[i] <= 1'b1;
            end
        end else begin
            valid_d2 <= valid_d1;
            if (valid_d1) begin

                // ---- Feature 0: price_delta (signed) ----
                s2_zero[0] <= (s1_feat[0] == 32'sd0);
                s2_sgn[0]  <= s1_feat[0][31];
                s2_mag[0]  <= s1_feat[0][31] ? (~s1_feat[0] + 32'd1) : 32'(s1_feat[0]);

                // ---- Feature 1: side_enc (always ±1, never zero) ----
                s2_zero[1] <= 1'b0;
                s2_sgn[1]  <= s1_feat[1][31];
                s2_mag[1]  <= 32'd1;

                // ---- Feature 2: order_flow (signed) ----
                s2_zero[2] <= (s1_feat[2] == 32'sd0);
                s2_sgn[2]  <= s1_feat[2][31];
                s2_mag[2]  <= s1_feat[2][31] ? (~s1_feat[2] + 32'd1) : 32'(s1_feat[2]);

                // ---- Features 3-9: unsigned (sign always 0) ----
                for (int i = 3; i <= 9; i++) begin
                    s2_zero[i] <= (s1_feat[i] == 32'h0);
                    s2_sgn[i]  <= 1'b0;
                    s2_mag[i]  <= 32'(s1_feat[i]);
                end

                // ---- Feature 10: order_vs_bid (signed) ----
                s2_zero[10] <= (s1_feat[10] == 32'sd0);
                s2_sgn[10]  <= s1_feat[10][31];
                s2_mag[10]  <= s1_feat[10][31] ? (~s1_feat[10] + 32'd1) : 32'(s1_feat[10]);

                // ---- Feature 11: order_vs_ask (signed) ----
                s2_zero[11] <= (s1_feat[11] == 32'sd0);
                s2_sgn[11]  <= s1_feat[11][31];
                s2_mag[11]  <= s1_feat[11][31] ? (~s1_feat[11] + 32'd1) : 32'(s1_feat[11]);

                // ---- Features 12-15: L2 bid price (unsigned) ----
                for (int k = 0; k < 4; k++) begin
                    s2_zero[12+k] <= (s1_l2_bid_px[k] == 32'h0);
                    s2_sgn[12+k]  <= 1'b0;
                    s2_mag[12+k]  <= s1_l2_bid_px[k];
                end

                // ---- Features 16-19: L2 ask price (unsigned) ----
                for (int k = 0; k < 4; k++) begin
                    s2_zero[16+k] <= (s1_l2_ask_px[k] == 32'h0);
                    s2_sgn[16+k]  <= 1'b0;
                    s2_mag[16+k]  <= s1_l2_ask_px[k];
                end

                // ---- Features 20-23: L2 bid size (unsigned) ----
                for (int k = 0; k < 4; k++) begin
                    s2_zero[20+k] <= (s1_l2_bid_sz[k] == 32'h0);
                    s2_sgn[20+k]  <= 1'b0;
                    s2_mag[20+k]  <= s1_l2_bid_sz[k];
                end

                // ---- Features 24-27: L2 ask size (unsigned) ----
                for (int k = 0; k < 4; k++) begin
                    s2_zero[24+k] <= (s1_l2_ask_sz[k] == 32'h0);
                    s2_sgn[24+k]  <= 1'b0;
                    s2_mag[24+k]  <= s1_l2_ask_sz[k];
                end

                // ---- Feature 28: rolling buy volume ----
                s2_zero[28] <= (s1_buy_vol_sum == 27'h0);
                s2_sgn[28]  <= 1'b0;
                s2_mag[28]  <= 32'(s1_buy_vol_sum);

                // ---- Feature 29: rolling sell volume ----
                s2_zero[29] <= (s1_sell_vol_sum == 27'h0);
                s2_sgn[29]  <= 1'b0;
                s2_mag[29]  <= 32'(s1_sell_vol_sum);

                // ---- Feature 30: VWAP (log2-division approximation) ----
                begin : blk_vwap
                    automatic logic [4:0]  vmsb;
                    automatic logic [31:0] vwap;
                    if (s1_vol_sum == 27'h0) begin
                        vwap = 32'h0;
                    end else begin
                        vmsb = msb_pos27(s1_vol_sum);
                        vwap = 32'(s1_px_vol_sum >> vmsb);
                    end
                    s2_zero[30] <= (s1_vol_sum == 27'h0);
                    s2_sgn[30]  <= 1'b0;
                    s2_mag[30]  <= vwap;
                end

                // ---- Feature 31: message arrival period ----
                s2_zero[31] <= (s1_msg_delta == 16'h0);
                s2_sgn[31]  <= 1'b0;
                s2_mag[31]  <= 32'(s1_msg_delta);
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 2.5 registers: LZ-split — pre-register leading-zero count for
    // [0..15] and pipeline mag/sgn/zero for both halves.
    //
    // Run 26 timing fix: calling the full mag_to_bf16() function in a single
    // always_ff creates a 7-LUT combinational chain (4 LUTs for 32-to-5 LZ
    // priority encode + 3 LUTs for 32-to-1 mantissa barrel shift) that cannot
    // close at 3.2 ns.  Solution: split the function into two halves across
    // pipeline stages.
    //   Stage 2.5: compute lz (leading-zero count, ~4 LUT levels) from s2_mag.
    //   Stage 3  : compute exp/mantissa from pre-registered lz + pipelined mag
    //              (~3 LUT levels — one 32-to-1 MUX per mantissa bit).
    // The same split is applied symmetrically to features [16..31] across
    // Stage 3 (lz compute) → Stage 4 (exp/mantissa compute).
    // ------------------------------------------------------------------
    logic [4:0]  s25_lz_lo  [0:15];   // leading-zero count for features [0..15]
    logic [31:0] s25_mag_lo [0:15];   // pipelined mag for features [0..15]
    logic        s25_sgn_lo [0:15];
    logic        s25_zero_lo[0:15];
    logic [31:0] s25_mag_hi [16:31];  // pipelined mag for features [16..31]
    logic        s25_sgn_hi [16:31];
    logic        s25_zero_hi[16:31];
    logic        valid_d25;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d25 <= 1'b0;
            for (int i = 0; i < 16; i++) begin
                s25_lz_lo[i]   <= '0;
                s25_mag_lo[i]  <= '0;
                s25_sgn_lo[i]  <= 1'b0;
                s25_zero_lo[i] <= 1'b1;
            end
            for (int i = 16; i < 32; i++) begin
                s25_mag_hi[i]  <= '0;
                s25_sgn_hi[i]  <= 1'b0;
                s25_zero_hi[i] <= 1'b1;
            end
        end else begin
            valid_d25 <= valid_d2;
            if (valid_d2) begin
                // [0..15]: compute LZ count (~4 LUT levels); pipeline mag/sgn/zero
                for (int i = 0; i < 16; i++) begin
                    s25_sgn_lo[i]  <= s2_sgn[i];
                    s25_zero_lo[i] <= s2_zero[i];
                    s25_mag_lo[i]  <= s2_mag[i];
                    begin
                        automatic int lz_cnt;
                        lz_cnt = 0;
                        for (int j = 31; j >= 0; j--) begin
                            if (s2_mag[i][j]) break;
                            lz_cnt = lz_cnt + 1;
                        end
                        s25_lz_lo[i] <= 5'(lz_cnt);
                    end
                end
                // [16..31]: pipeline mag/sgn/zero only (lz computed in Stage 3)
                for (int i = 16; i < 32; i++) begin
                    s25_mag_hi[i]  <= s2_mag[i];
                    s25_sgn_hi[i]  <= s2_sgn[i];
                    s25_zero_hi[i] <= s2_zero[i];
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 3 registers:
    //   [0..15]: assemble bf16 from pre-registered lz + pipelined mag
    //            (~3 LUT levels: 32-to-1 MUX per mantissa bit + add for exp)
    //   [16..31]: compute LZ count from pipelined mag; pipeline mag/sgn/zero
    // ------------------------------------------------------------------
    bfloat16_t   s3_feat_lo  [0:15];
    logic [4:0]  s3_lz_hi    [16:31];  // leading-zero count for [16..31]
    logic [31:0] s3_mag_hi   [16:31];
    logic        s3_sgn_hi   [16:31];
    logic        s3_zero_hi  [16:31];
    logic        valid_d3;

    always_ff @(posedge clk) begin
        if (rst) begin
            valid_d3 <= 1'b0;
            for (int i = 0; i < 16; i++) s3_feat_lo[i] <= 16'h0;
            for (int i = 16; i < 32; i++) begin
                s3_lz_hi[i]   <= '0;
                s3_mag_hi[i]  <= '0;
                s3_sgn_hi[i]  <= 1'b0;
                s3_zero_hi[i] <= 1'b1;
            end
        end else begin
            valid_d3 <= valid_d25;
            if (valid_d25) begin
                // [0..15]: exp/mantissa from pre-registered lz (~3 LUT levels)
                for (int i = 0; i < 16; i++) begin
                    if (s25_zero_lo[i]) begin
                        s3_feat_lo[i] <= 16'h0000;
                    end else begin
                        automatic logic [7:0] exp_v;
                        automatic logic [6:0] man_v;
                        // exp = 127 + 31 - lz = 158 - lz (8-bit minus 5-bit)
                        exp_v = 8'd158 - {3'b0, s25_lz_lo[i]};
                        // man: shift mag left by (lz+1), take bits [31:25].
                        // Use 6-bit shift amount to correctly represent lz+1=32
                        // when lz=31 (shift by 32 → 0, correct for mantissa).
                        man_v = 7'((s25_mag_lo[i] << ({1'b0, s25_lz_lo[i]} + 6'd1)) >> 25);
                        s3_feat_lo[i] <= {s25_sgn_lo[i], exp_v, man_v};
                    end
                end
                // [16..31]: LZ count from pipelined mag + pipeline mag/sgn/zero
                for (int i = 16; i < 32; i++) begin
                    s3_mag_hi[i]  <= s25_mag_hi[i];
                    s3_sgn_hi[i]  <= s25_sgn_hi[i];
                    s3_zero_hi[i] <= s25_zero_hi[i];
                    begin
                        automatic int lz_cnt;
                        lz_cnt = 0;
                        for (int j = 31; j >= 0; j--) begin
                            if (s25_mag_hi[i][j]) break;
                            lz_cnt = lz_cnt + 1;
                        end
                        s3_lz_hi[i] <= 5'(lz_cnt);
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 4 (output): latch bf16 for [0..15]; assemble bf16 for [16..31]
    //   [16..31]: exp/mantissa from pre-registered s3_lz_hi (~3 LUT levels)
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            features_valid <= 1'b0;
            for (int i = 0; i < VEC_LEN; i++) features[i] <= 16'h0;
        end else begin
            features_valid <= valid_d3;
            if (valid_d3) begin
                // [0..15]: pure latch — no combinational logic
                for (int i = 0; i < 16; i++)
                    features[i] <= s3_feat_lo[i];
                // [16..31]: assemble bf16 from pre-registered lz
                for (int i = 16; i < 32; i++) begin
                    if (s3_zero_hi[i]) begin
                        features[i] <= 16'h0000;
                    end else begin
                        automatic logic [7:0] exp_v;
                        automatic logic [6:0] man_v;
                        exp_v = 8'd158 - {3'b0, s3_lz_hi[i]};
                        man_v = 7'((s3_mag_hi[i] << ({1'b0, s3_lz_hi[i]} + 6'd1)) >> 25);
                        features[i] <= {s3_sgn_hi[i], exp_v, man_v};
                    end
                end
            end
        end
    end

endmodule

