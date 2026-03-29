// feature_extractor.sv — Transform parsed ITCH fields into bfloat16 feature vector
//
// Pipeline stage between itch_field_extract and dot_product_engine.
// Converts raw integer fields (price, side, order_ref) into bfloat16 features:
//   [0] price delta  — current price minus last-seen price
//   [1] side encoding — buy = +1.0, sell = -1.0
//   [2] order flow    — running buy - sell imbalance counter
//   [3] normalized price — raw price as bfloat16
//
// Registered outputs for timing closure.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module feature_extractor #(
    parameter int VEC_LEN = FEATURE_VEC_LEN
)(
    input  logic        clk,
    input  logic        rst,

    // From itch_field_extract
    input  logic [31:0] price,
    /* verilator lint_off UNUSED */
    input  logic [63:0] order_ref,    // not used in current feature set (reserved)
    /* verilator lint_on UNUSED */
    input  logic        side,        // 1 = buy, 0 = sell
    input  logic        fields_valid,

    // Feature vector output (one-shot, all elements at once)
    output bfloat16_t   features [VEC_LEN],
    output logic        features_valid
);

    // ------------------------------------------------------------------
    // Internal state
    // ------------------------------------------------------------------
    logic [31:0] last_price;
    logic signed [15:0] order_flow;  // running buy - sell imbalance

    // ------------------------------------------------------------------
    // Integer-to-bfloat16 conversion (signed 32-bit int → bfloat16)
    //
    // 1. If zero, emit 0x0000.
    // 2. Sign is bit 31 of two's-complement (or from negative flag).
    // 3. Find leading one in magnitude, derive exponent + mantissa.
    // ------------------------------------------------------------------
    function automatic bfloat16_t int_to_bf16(input logic signed [31:0] val);
        logic [31:0] mag;
        logic        sign_bit;
        logic [7:0]  exp_val;
        logic [6:0]  man_val;
        int          lz;

        if (val == 32'sd0) begin
            /* verilator coverage_off */
            return 16'h0000;
            /* verilator coverage_on */
        end

        sign_bit = val[31];
        mag = sign_bit ? (~val + 32'd1) : val;

        // Count leading zeros of magnitude
        lz = 0;
        for (int i = 31; i >= 0; i--) begin
            if (mag[i]) break;
            lz = lz + 1;
        end

        // IEEE 754: exponent = 127 + (31 - lz)
        exp_val = 8'(127 + 31 - lz);

        // Mantissa: shift magnitude so MSB is at bit 31, take bits [30:24]
        man_val = 7'((mag << (lz + 1)) >> 25);

        return {sign_bit, exp_val, man_val};
    endfunction

    // ------------------------------------------------------------------
    // Conversion pipeline — compute features combinationally, register output
    // ------------------------------------------------------------------
    logic signed [31:0] price_delta;
    logic signed [31:0] side_enc_int;
    logic signed [31:0] flow_val;
    logic signed [31:0] price_norm;

    bfloat16_t feat_price_delta;
    bfloat16_t feat_side;
    bfloat16_t feat_flow;
    bfloat16_t feat_price;

    always_comb begin
        // Price delta: current - last (signed)
        price_delta = 32'($signed({1'b0, price}) - $signed({1'b0, last_price}));

        // Side encoding: +1 for buy, -1 for sell
        side_enc_int = side ? 32'sd1 : -32'sd1;

        // Order flow: current counter value + this order's contribution
        // (value is captured BEFORE update, so we see the inc from this cycle)
        if (side)
            flow_val = $signed({{16{order_flow[15]}}, order_flow}) + 32'sd1;
        else
            flow_val = $signed({{16{order_flow[15]}}, order_flow}) - 32'sd1;

        // Normalized price (raw value as signed int)
        price_norm = 32'({1'b0, price[30:0]});

        // Convert to bfloat16
        feat_price_delta = int_to_bf16(price_delta);
        feat_side        = int_to_bf16(side_enc_int);
        feat_flow        = int_to_bf16(flow_val);
        feat_price       = int_to_bf16(price_norm);
    end

    // ------------------------------------------------------------------
    // Output registers
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            features_valid <= 1'b0;
            last_price     <= 32'd0;
            order_flow     <= 16'sd0;
            for (int i = 0; i < VEC_LEN; i++)
                features[i] <= 16'h0000;
        end else if (fields_valid) begin
            features[0]    <= feat_price_delta;
            features[1]    <= feat_side;
            features[2]    <= feat_flow;
            features[3]    <= feat_price;
            features_valid <= 1'b1;

            // Update state for next message
            last_price <= price;
            if (side)
                order_flow <= order_flow + 16'sd1;
            else
                order_flow <= order_flow - 16'sd1;
        end else begin
            features_valid <= 1'b0;
        end
    end

endmodule
