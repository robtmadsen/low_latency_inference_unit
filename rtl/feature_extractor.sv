// feature_extractor.sv — Transform parsed ITCH fields into bfloat16 feature vector
//
// 3-stage pipeline between itch_field_extract and dot_product_engine.
// Converts raw integer fields (price, side, order_ref) into bfloat16 features:
//   [0] price delta  — current price minus last-seen price
//   [1] side encoding — buy = +1.0, sell = -1.0
//   [2] order flow    — running buy - sell imbalance counter
//   [3] normalized price — raw price as bfloat16
//
// Latency: 3 cycles (fields_valid → features_valid)
//   Stage 1:  integer arithmetic registered (breaks CARRY4 subtraction chain)
//   Stage 2a: magnitude + sign computation registered (breaks CARRY4 abs chain)
//   Stage 2b: leading-zero priority encoding → bfloat16 output registered

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
    // Convert pre-computed magnitude + sign to bfloat16
    // (Called in Stage 2b; magnitude was computed in Stage 2a)
    // ------------------------------------------------------------------
    function automatic bfloat16_t mag_to_bf16(
        input logic        is_zero,
        input logic        sign_bit,
        input logic [31:0] mag
    );
        logic [7:0] exp_val;
        logic [6:0] man_val;
        int         lz;

        if (is_zero) begin
            /* verilator coverage_off */
            return 16'h0000;
            /* verilator coverage_on */
        end

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
    // Stage 1 intermediate registers
    // ------------------------------------------------------------------
    logic signed [31:0] price_delta_r;
    logic signed [31:0] side_enc_int_r;
    logic signed [31:0] flow_val_r;
    logic signed [31:0] price_norm_r;
    logic               valid_d1;

    // Stage 2a intermediates (magnitude + sign, fires on valid_d1)
    logic [31:0] mag0_r2, mag1_r2, mag2_r2, mag3_r2;
    logic        sgn0_r2, sgn1_r2, sgn2_r2, sgn3_r2;
    logic        zero0_r2, zero1_r2, zero2_r2, zero3_r2;
    logic        valid_d2;

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
    // Stage 2a: magnitude + sign computation (fires on valid_d1)
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            mag0_r2  <= '0;  mag1_r2  <= '0;  mag2_r2  <= '0;  mag3_r2  <= '0;
            sgn0_r2  <= '0;  sgn1_r2  <= '0;  sgn2_r2  <= '0;  sgn3_r2  <= '0;
            zero0_r2 <= '0;  zero1_r2 <= '0;  zero2_r2 <= '0;  zero3_r2 <= '0;
            valid_d2 <= 1'b0;
        end else begin
            valid_d2 <= valid_d1;
            if (valid_d1) begin
                // Feature 0: price delta (can be zero or negative)
                zero0_r2 <= (price_delta_r == 32'sd0);
                sgn0_r2  <= price_delta_r[31];
                mag0_r2  <= price_delta_r[31] ? (~price_delta_r + 32'd1) : price_delta_r;

                // Feature 1: side encoding (always ±1, never zero)
                zero1_r2 <= 1'b0;
                sgn1_r2  <= side_enc_int_r[31];
                mag1_r2  <= side_enc_int_r[31] ? (~side_enc_int_r + 32'd1) : side_enc_int_r;

                // Feature 2: order flow (can be zero or negative)
                zero2_r2 <= (flow_val_r == 32'sd0);
                sgn2_r2  <= flow_val_r[31];
                mag2_r2  <= flow_val_r[31]  ? (~flow_val_r  + 32'd1) : flow_val_r;

                // Feature 3: normalized price (non-negative; zero when price == 0)
                zero3_r2 <= (price_norm_r == 32'h0);
                sgn3_r2  <= 1'b0;
                mag3_r2  <= price_norm_r;
            end
        end
    end

    // ------------------------------------------------------------------
    // Stage 2b: bfloat16 normalization (fires on valid_d2)
    // ------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            features_valid <= 1'b0;
            for (int i = 0; i < VEC_LEN; i++)
                features[i] <= 16'h0000;
        end else if (valid_d2) begin
            features[0] <= mag_to_bf16(zero0_r2, sgn0_r2, mag0_r2);
            features[1] <= mag_to_bf16(zero1_r2, sgn1_r2, mag1_r2);
            features[2] <= mag_to_bf16(zero2_r2, sgn2_r2, mag2_r2);
            features[3] <= mag_to_bf16(zero3_r2, sgn3_r2, mag3_r2);
            features_valid <= 1'b1;
        end else begin
            features_valid <= 1'b0;
        end
    end

endmodule
