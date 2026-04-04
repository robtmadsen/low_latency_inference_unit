// feature_extractor.sv — Transform parsed ITCH fields into bfloat16 feature vector
//
// 2-stage pipeline between itch_field_extract and dot_product_engine.
// Converts raw integer fields (price, side, order_ref) into bfloat16 features:
//   [0] price delta  — current price minus last-seen price
//   [1] side encoding — buy = +1.0, sell = -1.0
//   [2] order flow    — running buy - sell imbalance counter
//   [3] normalized price — raw price as bfloat16
//
// Latency: 2 cycles (fields_valid → features_valid)
//   Stage 1: integer arithmetic registered (breaks CARRY4 subtraction chain)
//   Stage 2: bfloat16 conversion registered (output)

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
    // Stage 1 intermediate registers
    // ------------------------------------------------------------------
    logic signed [31:0] price_delta_r;
    logic signed [31:0] side_enc_int_r;
    logic signed [31:0] flow_val_r;
    logic signed [31:0] price_norm_r;
    logic               valid_d1;

    // ------------------------------------------------------------------
    // Stage 1: register integer arithmetic, update state
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            price_delta_r  <= '0;
            side_enc_int_r <= '0;
            flow_val_r     <= '0;
            price_norm_r   <= '0;
            valid_d1       <= 1'b0;
            last_price     <= 32'd0;
            order_flow     <= 16'sd0;
        end else begin
            valid_d1 <= fields_valid;
            if (fields_valid) begin
                price_delta_r  <= 32'($signed({1'b0, price}) - $signed({1'b0, last_price}));
                side_enc_int_r <= side ? 32'sd1 : -32'sd1;
                if (side)
                    flow_val_r <= $signed({{16{order_flow[15]}}, order_flow}) + 32'sd1;
                else
                    flow_val_r <= $signed({{16{order_flow[15]}}, order_flow}) - 32'sd1;
                price_norm_r   <= {1'b0, price[30:0]};
                // Update state for next message
                last_price <= price;
                if (side)
                    order_flow <= order_flow + 16'sd1;
                else
                    order_flow <= order_flow - 16'sd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 2: bfloat16 conversion registered (output)
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            features_valid <= 1'b0;
            for (int i = 0; i < VEC_LEN; i++)
                features[i] <= 16'h0000;
        end else if (valid_d1) begin
            features[0]    <= int_to_bf16(price_delta_r);
            features[1]    <= int_to_bf16(side_enc_int_r);
            features[2]    <= int_to_bf16(flow_val_r);
            features[3]    <= int_to_bf16(price_norm_r);
            features_valid <= 1'b1;
        end else begin
            features_valid <= 1'b0;
        end
    end

endmodule
