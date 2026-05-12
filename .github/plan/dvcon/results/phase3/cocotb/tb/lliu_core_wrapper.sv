/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module lliu_core_wrapper (
    input  logic         clk,
    input  logic         rst,
    input  logic [511:0] features_flat,
    input  logic         features_valid,
    input  logic [4:0]   wgt_wr_addr,
    input  logic [15:0]  wgt_wr_data,
    input  logic         wgt_wr_en,
    output logic [31:0]  result,
    output logic         result_valid,
    output logic [31:0]  result_out,
    output logic         result_ready
);

    bfloat16_t feat_arr [32];

    genvar gi;
    generate
        for (gi = 0; gi < 32; gi++) begin : unpack
            assign feat_arr[gi] = features_flat[gi*16 +: 16];
        end
    endgenerate

    lliu_core #(
        .VEC_LEN (32),
        .HIDDEN  (32)
    ) u_dut (
        .clk            (clk),
        .rst            (rst),
        .features       (feat_arr),
        .features_valid (features_valid),
        .wgt_wr_addr    (wgt_wr_addr),
        .wgt_wr_data    (wgt_wr_data),
        .wgt_wr_en      (wgt_wr_en),
        .result         (result),
        .result_valid   (result_valid),
        .result_out     (result_out),
        .result_ready   (result_ready)
    );

endmodule
