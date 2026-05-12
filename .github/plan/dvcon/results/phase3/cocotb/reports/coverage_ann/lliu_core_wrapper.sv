//      // verilator_coverage annotation
        /* verilator lint_off IMPORTSTAR */
        import lliu_pkg::*;
        /* verilator lint_on IMPORTSTAR */
        
        module lliu_core_wrapper (
 002066     input  logic         clk,
 000016     input  logic         rst,
            input  logic [511:0] features_flat,
 000014     input  logic         features_valid,
 000240     input  logic [4:0]   wgt_wr_addr,
~000024     input  logic [15:0]  wgt_wr_data,
 000015     input  logic         wgt_wr_en,
%000002     output logic [31:0]  result,
%000001     output logic         result_valid,
%000001     output logic [31:0]  result_out,
%000001     output logic         result_ready
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
        
