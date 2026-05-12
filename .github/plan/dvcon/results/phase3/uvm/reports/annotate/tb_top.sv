//      // verilator_coverage annotation
        `timescale 1ns/1ps
        
        import lliu_pkg::*;
        
        module tb_top;
        
            import uvm_pkg::*;
            import lliu_core_tb_pkg::*;
        
            // Clock: 100 MHz (10 ns period)
%000001     logic clk = 0;
 003777     always #5 clk = ~clk;
        
            // Interface
            lliu_core_if vif(clk);
        
            // Unpack features from interface into bfloat16_t array for DUT
            bfloat16_t feat_arr [4];
%000001     always_comb begin
%000001         feat_arr[0] = vif.features[0];
%000001         feat_arr[1] = vif.features[1];
%000001         feat_arr[2] = vif.features[2];
%000001         feat_arr[3] = vif.features[3];
            end
        
            // DUT
            lliu_core #(
                .VEC_LEN (4),
                .HIDDEN  (4)
            ) dut (
                .clk            (clk),
                .rst            (vif.rst),
                .features       (feat_arr),
                .features_valid (vif.features_valid),
                .wgt_wr_addr    (vif.wgt_wr_addr),
                .wgt_wr_data    (vif.wgt_wr_data),
                .wgt_wr_en      (vif.wgt_wr_en),
                .result         (vif.result),
                .result_valid   (vif.result_valid),
                .result_out     (vif.result_out),
                .result_ready   (vif.result_ready)
            );
        
            // UVM launch
%000001     initial begin
%000001         lliu_core_cfg::vif = vif;
%000001         run_test("lliu_core_base_test");
%000001         $finish;
            end
        
            // Safety watchdog — kill simulation after 500 us
%000000     initial begin
%000000         #500_000;
%000000         `uvm_fatal("WATCHDOG", "Simulation timed out at 500 us")
            end
        
        endmodule
        
