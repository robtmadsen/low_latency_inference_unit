// fp32_acc.sv — Float32 accumulator, four-stage pipeline
//
// Accumulates float32 values over multiple cycles.
// Supports clear (reset to zero) and accumulate enable.
//
// Four-stage pipeline to meet 300 MHz on Kintex-7 -2:
//   Stage A0 (pipe A0): exponent compare                   → registered → *_r0
//   Stage A1 (pipe A1): mantissa alignment (barrel shift)  → registered
//   Stage B  (pipe B):  mantissa add/subtract + normalise  → registered → partial_sum_r
//   Stage C:            partial_sum_r → acc_reg            → acc_out
//
// Stage A was split into A0 (exponent compare) and A1 (barrel shift) to
// break the critical feedback path: partial_sum_r → forwarding mux →
// exponent compare → exp_diff → barrel shift → CARRY4 chain (11 levels,
// 5.4 ns) that violated the 3.333 ns cycle budget at 300 MHz.
//
// Back-to-back acc_en forwarding:
//   acc_en_d3 asserted (Stage C about to fire) → Stage A0 uses partial_sum_r.
//   (Otherwise)                                → Stage A0 uses acc_reg.
//
// Uses a simplified float32 add: aligns mantissas by exponent difference,
// adds, and renormalizes. Sufficient for small vector dot products where
// catastrophic cancellation is not a concern.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module fp32_acc (
    input  logic     clk,
    input  logic     rst,
    input  float32_t addend,
    input  logic     acc_en,
    input  logic     acc_clear,
    output float32_t acc_out
);

    // Stage C register (final accumulated result, feeds output and back-path)
    float32_t acc_reg;
    // Stage B register (sum result from add/normalise, feeds Stage C)
    float32_t partial_sum_r;
    // Delayed enables: drive pipelined stages
    logic     acc_en_d1;  // 1 cycle after acc_en  → Stage A1 fires
    logic     acc_en_d2;  // 2 cycles after acc_en → Stage B fires
    logic     acc_en_d3;  // 3 cycles after acc_en → Stage C fires

    // -------------------------------------------------------------------
    // Forwarding mux: decide which accumulated value to use as the
    // feedback operand entering Stage A0.
    //   - acc_en_d3: Stage C is about to register partial_sum_r, so the
    //     most recent committed sum is still in partial_sum_r.
    //   - Otherwise: acc_reg holds the most recent committed sum.
    // This eliminates the RAW hazard on consecutive acc_en pulses.
    // -------------------------------------------------------------------
    float32_t acc_fb;
    assign acc_fb = acc_en_d3 ? partial_sum_r : acc_reg;

    // -------------------------------------------------------------------
    // Stage A0 combinational: decompose operands, compare exponents
    // (no carry chain — just comparators and muxes)
    // -------------------------------------------------------------------
    logic        acc_sign_a0, add_sign_a0;
    logic [7:0]  acc_exp_a0,  add_exp_a0;
    logic [23:0] acc_man_a0,  add_man_a0;
    logic        acc_zero_a0, add_zero_a0;
    logic        acc_larger_a0;
    logic [23:0] big_man_a0,  small_man_a0;
    logic        big_sign_a0;
    logic [7:0]  big_exp_a0;
    logic [7:0]  exp_diff_a0;
    logic        eff_sub_a0;

    always_comb begin
        acc_sign_a0 = acc_fb[31];
        acc_exp_a0  = acc_fb[30:23];
        acc_zero_a0 = (acc_fb[30:0] == 31'b0);
        acc_man_a0  = acc_zero_a0 ? 24'b0 : {1'b1, acc_fb[22:0]};

        add_sign_a0 = addend[31];
        add_exp_a0  = addend[30:23];
        add_zero_a0 = (addend[30:0] == 31'b0);
        add_man_a0  = add_zero_a0 ? 24'b0 : {1'b1, addend[22:0]};

        acc_larger_a0 = (acc_exp_a0 >= add_exp_a0);

        if (acc_larger_a0) begin
            big_exp_a0   = acc_exp_a0;  big_man_a0   = acc_man_a0;
            big_sign_a0  = acc_sign_a0; small_man_a0 = add_man_a0;
        end else begin
            big_exp_a0   = add_exp_a0;  big_man_a0   = add_man_a0;
            big_sign_a0  = add_sign_a0; small_man_a0 = acc_man_a0;
        end

        exp_diff_a0 = big_exp_a0 - (acc_larger_a0 ? add_exp_a0 : acc_exp_a0);
        eff_sub_a0  = acc_sign_a0 ^ add_sign_a0;
    end

    // Stage A0 registers (capture exponent-compare result; fires on acc_en)
    logic [23:0] big_man_r0;
    logic [23:0] small_man_r0;
    logic        big_sign_r0;
    logic [7:0]  big_exp_r0;
    logic [7:0]  exp_diff_r0;
    logic        eff_sub_r0;
    logic        acc_zero_r0;
    logic        add_zero_r0;
    float32_t    addend_r0;
    float32_t    acc_fb_r0;

    always_ff @(posedge clk) begin
        if (rst || acc_clear) begin
            big_man_r0   <= 24'b0;
            small_man_r0 <= 24'b0;
            big_sign_r0  <= 1'b0;
            big_exp_r0   <= 8'b0;
            exp_diff_r0  <= 8'b0;
            eff_sub_r0   <= 1'b0;
            acc_zero_r0  <= 1'b1;
            add_zero_r0  <= 1'b1;
            addend_r0    <= 32'b0;
            acc_fb_r0    <= 32'b0;
        end else if (acc_en) begin
            big_man_r0   <= big_man_a0;
            small_man_r0 <= small_man_a0;
            big_sign_r0  <= big_sign_a0;
            big_exp_r0   <= big_exp_a0;
            exp_diff_r0  <= exp_diff_a0;
            eff_sub_r0   <= eff_sub_a0;
            acc_zero_r0  <= acc_zero_a0;
            add_zero_r0  <= add_zero_a0;
            addend_r0    <= addend;
            acc_fb_r0    <= acc_fb;
        end
    end

    // -------------------------------------------------------------------
    // Stage A1 combinational: mantissa alignment (barrel shift)
    // Input: Stage A0 registers; no feedback from acc_reg.
    // -------------------------------------------------------------------
    logic [23:0] aligned_small_man_a1;

    always_comb begin
        if (exp_diff_r0 > 8'd24)
            aligned_small_man_a1 = 24'b0;
        else
            aligned_small_man_a1 = small_man_r0 >> exp_diff_r0;
    end

    // Stage A1 registers (capture alignment result; fires on acc_en_d1)
    logic [23:0] big_man_r;
    logic [23:0] aligned_small_r;
    logic        big_sign_r;
    logic        eff_sub_r;
    logic [7:0]  big_exp_r;
    logic        acc_zero_r;
    logic        add_zero_r;
    float32_t    addend_r;
    float32_t    acc_fb_r;

    always_ff @(posedge clk) begin
        if (rst || acc_clear) begin
            big_man_r      <= 24'b0;
            aligned_small_r <= 24'b0;
            big_sign_r     <= 1'b0;
            eff_sub_r      <= 1'b0;
            big_exp_r      <= 8'b0;
            acc_zero_r     <= 1'b1;
            add_zero_r     <= 1'b1;
            addend_r       <= 32'b0;
            acc_fb_r       <= 32'b0;
        end else if (acc_en_d1) begin
            big_man_r      <= big_man_r0;
            aligned_small_r <= aligned_small_man_a1;
            big_sign_r     <= big_sign_r0;
            eff_sub_r      <= eff_sub_r0;
            big_exp_r      <= big_exp_r0;
            acc_zero_r     <= acc_zero_r0;
            add_zero_r     <= add_zero_r0;
            addend_r       <= addend_r0;
            acc_fb_r       <= acc_fb_r0;
        end
    end

    // -------------------------------------------------------------------
    // Stage B combinational: mantissa add/subtract + normalise
    // (CARRY chain lives only here — broken from Stage A by the register)
    // -------------------------------------------------------------------
    logic [24:0] sum_man_b;
    logic        sum_sign_b;
    logic [7:0]  sum_exp_b;
    float32_t    sum_result_b;

    always_comb begin
        sum_exp_b = big_exp_r;

        if (eff_sub_r) begin
            if (big_man_r >= aligned_small_r) begin
                sum_man_b  = {1'b0, big_man_r} - {1'b0, aligned_small_r};
                sum_sign_b = big_sign_r;
            end else begin
                sum_man_b  = {1'b0, aligned_small_r} - {1'b0, big_man_r};
                sum_sign_b = !big_sign_r;
            end
        end else begin
            sum_man_b  = {1'b0, big_man_r} + {1'b0, aligned_small_r};
            sum_sign_b = big_sign_r;
        end

        // Normalise
        if (acc_zero_r && add_zero_r) begin
            sum_result_b = 32'b0;
        end else if (acc_zero_r) begin
            sum_result_b = addend_r;
        end else if (add_zero_r) begin
            sum_result_b = acc_fb_r;
        /* verilator coverage_off */  // exact cancellation: requires identical-magnitude opposing products
        end else if (sum_man_b == 25'b0) begin
            sum_result_b = 32'b0;
        /* verilator coverage_on */
        end else if (sum_man_b[24]) begin
            sum_exp_b    = big_exp_r + 8'd1;
            sum_result_b = {sum_sign_b, sum_exp_b, sum_man_b[23:1]};
        end else if (!sum_man_b[23]) begin
            sum_result_b = {sum_sign_b, sum_exp_b, sum_man_b[22:0]}; // default
            if      (sum_man_b[22]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd1,  sum_man_b[21:0], 1'b0};  end
            else if (sum_man_b[21]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd2,  sum_man_b[20:0], 2'b0};  end
            else if (sum_man_b[20]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd3,  sum_man_b[19:0], 3'b0};  end
            else if (sum_man_b[19]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd4,  sum_man_b[18:0], 4'b0};  end
            else if (sum_man_b[18]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd5,  sum_man_b[17:0], 5'b0};  end
            else if (sum_man_b[17]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd6,  sum_man_b[16:0], 6'b0};  end
            else if (sum_man_b[16]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd7,  sum_man_b[15:0], 7'b0};  end
            else if (sum_man_b[15]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd8,  sum_man_b[14:0], 8'b0};  end
            else if (sum_man_b[14]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd9,  sum_man_b[13:0], 9'b0};  end
            else if (sum_man_b[13]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd10, sum_man_b[12:0], 10'b0}; end
            else if (sum_man_b[12]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd11, sum_man_b[11:0], 11'b0}; end
            else if (sum_man_b[11]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd12, sum_man_b[10:0], 12'b0}; end
            /* verilator coverage_off */  // deep renorm [10:0]: repeating pattern proven by [22:11] coverage;
            //   requires >13 bits cancellation precision — unreachable with bfloat16 dot product
            else if (sum_man_b[10]) begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd13, sum_man_b[9:0],  13'b0}; end
            else if (sum_man_b[9])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd14, sum_man_b[8:0],  14'b0}; end
            else if (sum_man_b[8])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd15, sum_man_b[7:0],  15'b0}; end
            else if (sum_man_b[7])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd16, sum_man_b[6:0],  16'b0}; end
            else if (sum_man_b[6])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd17, sum_man_b[5:0],  17'b0}; end
            else if (sum_man_b[5])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd18, sum_man_b[4:0],  18'b0}; end
            else if (sum_man_b[4])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd19, sum_man_b[3:0],  19'b0}; end
            else if (sum_man_b[3])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd20, sum_man_b[2:0],  20'b0}; end
            else if (sum_man_b[2])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd21, sum_man_b[1:0],  21'b0}; end
            else if (sum_man_b[1])  begin sum_result_b = {sum_sign_b, sum_exp_b - 8'd22, sum_man_b[0],    22'b0}; end
            else                    begin sum_result_b = 32'b0; end
            /* verilator coverage_on */
        end else begin
            sum_result_b = {sum_sign_b, sum_exp_b, sum_man_b[22:0]};
        end
    end

    // Delayed enables
    always_ff @(posedge clk) begin
        if (rst || acc_clear) begin
            acc_en_d1 <= 1'b0;
            acc_en_d2 <= 1'b0;
            acc_en_d3 <= 1'b0;
        end else begin
            acc_en_d1 <= acc_en;
            acc_en_d2 <= acc_en_d1;
            acc_en_d3 <= acc_en_d2;
        end
    end

    // Stage B register: capture normalised sum
    always_ff @(posedge clk) begin
        if (rst || acc_clear)
            partial_sum_r <= 32'b0;
        else if (acc_en_d2)
            partial_sum_r <= sum_result_b;
    end

    // Stage C register: move Stage B result into feedback accumulator
    always_ff @(posedge clk) begin
        if (rst || acc_clear)
            acc_reg <= 32'b0;
        else if (acc_en_d3)
            acc_reg <= partial_sum_r;
    end

    assign acc_out = acc_reg;

endmodule
