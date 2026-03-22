// bfloat16_mul.sv — bfloat16 multiplier producing float32 result
//
// Takes two bfloat16 operands and produces a float32 product.
// Single-cycle combinational datapath.
//
// bfloat16 format: [15] sign | [14:7] exponent (8-bit, bias 127) | [6:0] mantissa (7-bit, implicit leading 1)
// float32 format:  [31] sign | [30:23] exponent (8-bit, bias 127) | [22:0] mantissa (23-bit, implicit leading 1)

import lliu_pkg::*;

module bfloat16_mul (
    input  bfloat16_t a,
    input  bfloat16_t b,
    output float32_t  result
);

    // Decompose inputs
    logic        a_sign, b_sign;
    logic [7:0]  a_exp,  b_exp;
    logic [7:0]  a_man,  b_man;  // 8-bit: implicit 1 + 7 explicit bits
    logic        a_zero, b_zero;

    assign a_sign = a[15];
    assign b_sign = b[15];
    assign a_exp  = a[14:7];
    assign b_exp  = b[14:7];
    assign a_zero = (a[14:0] == 15'b0);
    assign b_zero = (b[14:0] == 15'b0);

    // Implicit leading 1 for normalized numbers (exponent != 0)
    assign a_man = (a_exp != 8'b0) ? {1'b1, a[6:0]} : {1'b0, a[6:0]};
    assign b_man = (b_exp != 8'b0) ? {1'b1, b[6:0]} : {1'b0, b[6:0]};

    // Result sign: XOR of input signs
    logic r_sign;
    assign r_sign = a_sign ^ b_sign;

    // Mantissa multiply: 8-bit × 8-bit = 16-bit product
    // Format: if both normalized, product is [1.xxx] × [1.yyy] = [01.xx...] or [1x.xx...]
    logic [15:0] man_product;
    assign man_product = a_man * b_man;

    // Exponent sum with bias correction
    // Result exponent = a_exp + b_exp - bias
    // Use wider intermediate to detect overflow/underflow
    logic [9:0] exp_sum;
    assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd127;

    // Normalize: check if product has a leading 1 in bit [15]
    // If man_product[15] == 1: shift right by 1, increment exponent
    // Otherwise: no shift needed
    logic        norm_shift;
    logic [22:0] r_man;
    logic [9:0]  r_exp_wide;
    logic [7:0]  r_exp;

    assign norm_shift = man_product[15];

    always_comb begin
        if (a_zero || b_zero) begin
            // Zero result
            r_man      = 23'b0;
            r_exp_wide = 10'b0;
        end else if (norm_shift) begin
            // Product >= 2.0 in fixed point, shift right, bump exponent
            // man_product[15:1] is 15 bits; we need 23 mantissa bits for float32
            // Place the 14 significant bits (excluding implicit 1) into top of mantissa
            r_man      = {man_product[14:1], 9'b0};
            r_exp_wide = exp_sum + 10'd1;
        end else begin
            // Product < 2.0, no shift
            // man_product[14:0] is 15 bits; bit [14] is the implicit 1
            // Place the 13 significant bits into top of mantissa
            r_man      = {man_product[13:0], 9'b0};
            r_exp_wide = exp_sum;
        end
    end

    // Clamp exponent
    always_comb begin
        if (a_zero || b_zero) begin
            r_exp = 8'b0;
        end else if (r_exp_wide[9]) begin
            // Underflow (negative exponent) — flush to zero
            r_exp = 8'b0;
        end else if (r_exp_wide[8]) begin
            // Overflow — clamp to max (infinity)
            r_exp = 8'hFF;
        end else begin
            r_exp = r_exp_wide[7:0];
        end
    end

    // Assemble float32 result
    logic result_is_zero;
    assign result_is_zero = a_zero || b_zero || (r_exp == 8'b0 && !a_zero && !b_zero);

    assign result = result_is_zero ? {r_sign, 31'b0} : {r_sign, r_exp, r_man};

endmodule
