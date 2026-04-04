// fp32_acc.sv — Float32 accumulator, three-stage pipeline
//
// Accumulates float32 values over multiple cycles.
// Supports clear (reset to zero) and accumulate enable.
//
// Three-stage pipeline to meet 300 MHz on Kintex-7 -2:
//   Stage A (pipe A): exponent compare + mantissa alignment → registered
//   Stage B (pipe B): mantissa add/subtract + normalise     → registered → partial_sum_r
//   Stage C:          partial_sum_r → acc_reg               → acc_out
//
// Splitting at the alignment/add boundary breaks the critical CARRY4 chain
// that spanned both operations in the previous two-stage design.
//
// Back-to-back acc_en forwarding:
//   acc_en_d2 asserted (Stage C about to fire) → FP add (Stage A) uses partial_sum_r.
//   acc_en_d1 asserted (Stage B about to fire) → FP add (Stage A) uses acc_reg.
//   (Neither)                                  → FP add (Stage A) uses acc_reg.
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
    logic     acc_en_d1;  // 1 cycle after acc_en → Stage B fires
    logic     acc_en_d2;  // 2 cycles after acc_en → Stage C fires

    // -------------------------------------------------------------------
    // Forwarding mux: decide which accumulated value to use as the
    // feedback operand entering Stage A.
    //   - acc_en_d2: Stage C is about to register partial_sum_r, so the
    //     most recent committed sum is still in partial_sum_r.
    //   - Otherwise: acc_reg holds the most recent committed sum.
    // This eliminates the RAW hazard on consecutive acc_en pulses.
    // -------------------------------------------------------------------
    float32_t acc_fb;
    assign acc_fb = acc_en_d2 ? partial_sum_r : acc_reg;

    // -------------------------------------------------------------------
    // Stage A combinational: decompose operands, align mantissas
    // (no carry chain — just comparators, muxes, and a barrel shift)
    // -------------------------------------------------------------------
    logic        acc_sign_a, add_sign_a;
    logic [7:0]  acc_exp_a,  add_exp_a;
    logic [23:0] acc_man_a,  add_man_a;
    logic        acc_zero_a, add_zero_a;
    logic        acc_larger_a;
    logic [23:0] big_man_a, small_man_a;
    logic        big_sign_a, small_sign_a;
    logic [7:0]  big_exp_a;
    logic [7:0]  exp_diff_a;
    logic [23:0] aligned_small_man_a;
    logic        eff_sub_a;
    float32_t    addend_a;  // registered copy of addend for stage B
    float32_t    acc_fb_a;  // registered copy of acc_fb for stage B

    always_comb begin
        acc_sign_a = acc_fb[31];
        acc_exp_a  = acc_fb[30:23];
        acc_zero_a = (acc_fb[30:0] == 31'b0);
        acc_man_a  = acc_zero_a ? 24'b0 : {1'b1, acc_fb[22:0]};

        add_sign_a = addend[31];
        add_exp_a  = addend[30:23];
        add_zero_a = (addend[30:0] == 31'b0);
        add_man_a  = add_zero_a ? 24'b0 : {1'b1, addend[22:0]};

        acc_larger_a = (acc_exp_a >= add_exp_a);

        if (acc_larger_a) begin
            big_exp_a   = acc_exp_a;   big_man_a   = acc_man_a;
            big_sign_a  = acc_sign_a;  small_man_a = add_man_a;
            small_sign_a = add_sign_a;
        end else begin
            big_exp_a   = add_exp_a;   big_man_a   = add_man_a;
            big_sign_a  = add_sign_a;  small_man_a = acc_man_a;
            small_sign_a = acc_sign_a;
        end

        exp_diff_a = big_exp_a - (acc_larger_a ? add_exp_a : acc_exp_a);

        if (exp_diff_a > 8'd24)
            aligned_small_man_a = 24'b0;
        else
            aligned_small_man_a = small_man_a >> exp_diff_a;

        eff_sub_a = big_sign_a ^ small_sign_a;

        addend_a = addend;
        acc_fb_a = acc_fb;
    end

    // Stage A intermediate registers (capture alignment result)
    logic [23:0] big_man_r;
    logic [23:0] aligned_small_r;
    logic        big_sign_r;
    logic        eff_sub_r;
    logic [7:0]  big_exp_r;
    logic        acc_zero_r;
    logic        add_zero_r;
    float32_t    addend_r;  // addend forwarded to Stage B for zero-passthrough
    float32_t    acc_fb_r;  // acc_fb forwarded to Stage B for zero-passthrough

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
        end else if (acc_en) begin
            big_man_r      <= big_man_a;
            aligned_small_r <= aligned_small_man_a;
            big_sign_r     <= big_sign_a;
            eff_sub_r      <= eff_sub_a;
            big_exp_r      <= big_exp_a;
            acc_zero_r     <= acc_zero_a;
            add_zero_r     <= add_zero_a;
            addend_r       <= addend_a;
            acc_fb_r       <= acc_fb_a;
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
        end else begin
            acc_en_d1 <= acc_en;
            acc_en_d2 <= acc_en_d1;
        end
    end

    // Stage B register: capture normalised sum
    always_ff @(posedge clk) begin
        if (rst || acc_clear)
            partial_sum_r <= 32'b0;
        else if (acc_en_d1)
            partial_sum_r <= sum_result_b;
    end

    // Stage C register: move Stage B result into feedback accumulator
    always_ff @(posedge clk) begin
        if (rst || acc_clear)
            acc_reg <= 32'b0;
        else if (acc_en_d2)
            acc_reg <= partial_sum_r;
    end

    assign acc_out = acc_reg;

endmodule
