//      // verilator_coverage annotation
        package lliu_core_tb_pkg;
        
            import uvm_pkg::*;
            `include "uvm_macros.svh"
        
            localparam int TB_VEC = 4;
        
            // -----------------------------------------------------------------
            // Static config: holds the virtual interface handle
            // -----------------------------------------------------------------
%000000     class lliu_core_cfg;
                static virtual lliu_core_if vif;
            endclass
        
            // -----------------------------------------------------------------
            // Reference-model helpers
            // -----------------------------------------------------------------
            function automatic real fp32_to_real(input logic [31:0] fp32);
                logic [63:0] fp64;
                logic [10:0] fp64_exp;
%000000         if (fp32[30:0] == 31'b0) return 0.0;
                fp64_exp = {3'b0, fp32[30:23]} + 11'd896;
                fp64     = {fp32[31], fp64_exp, fp32[22:0], 29'b0};
                return $bitstoreal(fp64);
            endfunction
        
            function automatic real bf16_to_real(input logic [15:0] bf16);
                return fp32_to_real({bf16, 16'b0});
            endfunction
        
            function automatic real compute_dot_product(
                input logic [15:0] features [TB_VEC],
                input logic [15:0] weights  [TB_VEC]
            );
                real s;
                s = 0.0;
                for (int i = 0; i < TB_VEC; i++)
                    s = s + bf16_to_real(features[i]) * bf16_to_real(weights[i]);
                return s;
            endfunction
        
            // -----------------------------------------------------------------
            // Sequence item
            // -----------------------------------------------------------------
            class lliu_core_seq_item extends uvm_sequence_item;
                logic [15:0] features [TB_VEC];
                logic [15:0] weights  [TB_VEC];
                string       tname;
                real          expected;
        
%000000         `uvm_object_utils(lliu_core_seq_item)
        
%000000         function new(string name = "lliu_core_seq_item");
%000000             super.new(name);
                endfunction
            endclass
        
            // -----------------------------------------------------------------
            // Scoreboard
            // -----------------------------------------------------------------
            class lliu_core_scoreboard extends uvm_component;
%000000         `uvm_component_utils(lliu_core_scoreboard)
        
                int unsigned num_checks;
                int unsigned num_pass;
                int unsigned num_fail;
                int unsigned num_timeout;
                string       bug_log;
        
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
%000001             num_checks  = 0;
%000001             num_pass    = 0;
%000001             num_fail    = 0;
%000001             num_timeout = 0;
%000001             bug_log     = "";
                endfunction
        
%000003         function void check_result(logic [31:0] dut_result,
                                           real          expected,
                                           string        test_name);
%000003             real actual_r, diff, ref_abs, rel;
%000003             actual_r = fp32_to_real(dut_result);
%000003             diff     = actual_r - expected;
%000003             if (diff < 0.0) diff = -diff;
%000003             ref_abs  = expected;
%000003             if (ref_abs < 0.0) ref_abs = -ref_abs;
%000003             rel = (ref_abs > 1.0e-12) ? diff / ref_abs : diff;
        
%000003             num_checks = num_checks + 1;
        
%000003             if (rel < 0.001) begin
%000000                 num_pass = num_pass + 1;
                        `uvm_info("SB", $sformatf("[%s] PASS: expected=%0g actual=%0g",
%000000                           test_name, expected, actual_r), UVM_LOW)
%000003             end else begin
%000003                 num_fail = num_fail + 1;
                        `uvm_warning("SB", $sformatf(
                            "[%s] MISMATCH: expected=%0g actual=%0g (0x%08h)",
%000003                     test_name, expected, actual_r, dut_result))
%000003                 bug_log = {bug_log,
%000003                     $sformatf("| %s | %0g | %0g (0x%08h) | mismatch |\n",
%000003                               test_name, expected, actual_r, dut_result)};
                    end
                endfunction
        
%000005         function void log_timeout(string test_name, real expected);
%000005             num_timeout = num_timeout + 1;
                    `uvm_warning("SB", $sformatf(
                        "[%s] TIMEOUT: DPE never produced result_valid (expected=%0g)",
%000005                 test_name, expected))
%000005             bug_log = {bug_log,
%000005                 $sformatf("| %s | %0g | TIMEOUT | DPE stuck |\n",
%000005                           test_name, expected)};
                endfunction
        
%000001         function void report_phase(uvm_phase phase);
                    `uvm_info("SB", $sformatf(
                        "\n--- Scoreboard Summary ---\nChecks: %0d  Pass: %0d  Fail: %0d  Timeout: %0d",
%000001                 num_checks, num_pass, num_fail, num_timeout), UVM_LOW)
                endfunction
            endclass
        
            // -----------------------------------------------------------------
            // Driver
            // -----------------------------------------------------------------
            class lliu_core_driver extends uvm_component;
%000000         `uvm_component_utils(lliu_core_driver)
        
                virtual lliu_core_if vif;
        
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
        
%000001         function void build_phase(uvm_phase phase);
%000001             super.build_phase(phase);
%000001             vif = lliu_core_cfg::vif;
                endfunction
        
%000008         task do_reset();
%000008             vif.rst            <= 1'b1;
%000008             vif.features_valid <= 1'b0;
%000008             vif.wgt_wr_en      <= 1'b0;
%000008             vif.wgt_wr_addr    <= '0;
%000008             vif.wgt_wr_data    <= '0;
~000032             for (int i = 0; i < TB_VEC; i++) vif.features[i] <= '0;
~000080             repeat (10) @(posedge vif.clk);
%000008             vif.rst <= 1'b0;
~000040             repeat (5) @(posedge vif.clk);
                endtask
        
%000008         task load_weights(input logic [15:0] w [TB_VEC]);
~000032             for (int i = 0; i < TB_VEC; i++) begin
 000032                 @(posedge vif.clk);
 000032                 vif.wgt_wr_en   <= 1'b1;
 000032                 vif.wgt_wr_addr <= i[1:0];
 000032                 vif.wgt_wr_data <= w[i];
                    end
%000008             @(posedge vif.clk);
%000008             vif.wgt_wr_en <= 1'b0;
                endtask
        
 000011         task drive_features(input logic [15:0] f [TB_VEC]);
 000011             @(posedge vif.clk);
 000044             for (int i = 0; i < TB_VEC; i++) vif.features[i] <= f[i];
 000011             vif.features_valid <= 1'b1;
 000011             @(posedge vif.clk);
 000011             vif.features_valid <= 1'b0;
                endtask
            endclass
        
            // -----------------------------------------------------------------
            // Monitor
            // -----------------------------------------------------------------
            class lliu_core_monitor extends uvm_component;
%000000         `uvm_component_utils(lliu_core_monitor)
        
                virtual lliu_core_if vif;
                logic [31:0] last_result;
                logic        got_result;
        
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
%000001             got_result = 0;
                endfunction
        
%000001         function void build_phase(uvm_phase phase);
%000001             super.build_phase(phase);
%000001             vif = lliu_core_cfg::vif;
                endfunction
        
%000000         task run_phase(uvm_phase phase);
 001889             forever begin
 001889                 @(posedge vif.clk);
~001886                 if (vif.result_valid) begin
%000003                     last_result = vif.result;
%000003                     got_result  = 1;
                        end
                    end
                endtask
            endclass
        
            // -----------------------------------------------------------------
            // Agent
            // -----------------------------------------------------------------
            class lliu_core_agent extends uvm_component;
%000000         `uvm_component_utils(lliu_core_agent)
        
                lliu_core_driver  drv;
                lliu_core_monitor mon;
        
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
        
%000001         function void build_phase(uvm_phase phase);
%000001             super.build_phase(phase);
%000001             drv = lliu_core_driver::type_id::create("drv", this);
%000001             mon = lliu_core_monitor::type_id::create("mon", this);
                endfunction
            endclass
        
            // -----------------------------------------------------------------
            // Environment
            // -----------------------------------------------------------------
            class lliu_core_env extends uvm_env;
%000000         `uvm_component_utils(lliu_core_env)
        
                lliu_core_agent      agt;
                lliu_core_scoreboard sb;
        
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
        
%000001         function void build_phase(uvm_phase phase);
%000001             super.build_phase(phase);
%000001             agt = lliu_core_agent::type_id::create("agt", this);
%000001             sb  = lliu_core_scoreboard::type_id::create("sb", this);
                endfunction
            endclass
        
            // -----------------------------------------------------------------
            // Base test
            // -----------------------------------------------------------------
            class lliu_core_base_test extends uvm_test;
%000001         `uvm_component_utils(lliu_core_base_test)
        
                lliu_core_env        env;
                virtual lliu_core_if vif;
        
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
        
%000001         function void build_phase(uvm_phase phase);
%000001             super.build_phase(phase);
%000001             env = lliu_core_env::type_id::create("env", this);
%000001             vif = lliu_core_cfg::vif;
                endfunction
        
                // ---- helper: run a single inference (may timeout) -----------
%000005         task run_single(
                    input string        test_name,
                    input logic [15:0]  weights  [TB_VEC],
                    input logic [15:0]  features [TB_VEC],
                    input real          expected,
%000001             input int           do_rst = 1
                );
%000005             if (do_rst) env.agt.drv.do_reset();
%000005             env.agt.drv.load_weights(weights);
~000010             repeat (2) @(posedge vif.clk);
%000005             env.agt.mon.got_result = 0;
%000005             env.agt.drv.drive_features(features);
%000005             begin
%000005                 int cyc;
~001500                 for (cyc = 0; cyc < 300; cyc++) begin
 001500                     @(posedge vif.clk);
~001500                     if (env.agt.mon.got_result) begin
%000000                         env.sb.check_result(env.agt.mon.last_result,
%000000                                             expected, test_name);
%000000                         return;
                            end
                        end
%000005                 env.sb.log_timeout(test_name, expected);
                    end
                endtask
        
                // ---- helper: double inference (second provides missing elem)
%000003         task run_double(
                    input string        test_name,
                    input logic [15:0]  weights  [TB_VEC],
                    input logic [15:0]  feat1    [TB_VEC],
                    input logic [15:0]  feat2    [TB_VEC],
                    input real          expected
                );
%000003             env.agt.drv.do_reset();
%000003             env.agt.drv.load_weights(weights);
%000006             repeat (2) @(posedge vif.clk);
%000003             env.agt.mon.got_result = 0;
        
                    // 1st inference (will timeout — DPE stuck at element VEC_LEN-1)
%000003             env.agt.drv.drive_features(feat1);
~000090             repeat (30) @(posedge vif.clk);
        
                    // 2nd inference provides the missing element to the DPE
%000003             env.agt.drv.drive_features(feat2);
        
%000003             begin
%000003                 int cyc;
~000078                 for (cyc = 0; cyc < 300; cyc++) begin
 000078                     @(posedge vif.clk);
~000078                     if (env.agt.mon.got_result) begin
%000000                         env.sb.check_result(env.agt.mon.last_result,
%000000                                             expected, test_name);
%000000                         return;
                            end
                        end
%000003                 env.sb.log_timeout(test_name, expected);
                    end
                endtask
        
                // ---- main test body -----------------------------------------
%000001         task run_phase(uvm_phase phase);
                    // bf16 constants
%000001             logic [15:0] w [TB_VEC];
%000001             logic [15:0] f [TB_VEC];
%000001             logic [15:0] f2[TB_VEC];
        
%000001             phase.raise_objection(this);
%000001             `uvm_info("TEST", "===== Starting lliu_core tests =====", UVM_LOW)
        
                    // ------ T1: basic (all 1.0 weights) ------
%000001             w = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
%000001             f = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
%000001             run_single("T1_basic", w, f,
%000001                         compute_dot_product(f, w));
        
                    // ------ T2: zero weights ------
%000001             w = '{16'h0000, 16'h0000, 16'h0000, 16'h0000};
%000001             f = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
%000001             run_single("T2_zero_wgt", w, f,
%000001                         compute_dot_product(f, w));
        
                    // ------ T3: mixed positive ------
%000001             w = '{16'h4000, 16'h3F00, 16'h3F80, 16'h4040};
%000001             f = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
%000001             run_single("T3_mixed", w, f,
%000001                         compute_dot_product(f, w));
        
                    // ------ T4: negative weights ------
%000001             w = '{16'h3F80, 16'hBF80, 16'h3F80, 16'hBF80};
%000001             f = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
%000001             run_single("T4_neg_wgt", w, f,
%000001                         compute_dot_product(f, w));
        
                    // ------ T5: both negative (triggers sign OR bug) ------
%000001             w = '{16'hBF80, 16'hBF80, 16'hBF80, 16'hBF80};
%000001             f = '{16'hBF80, 16'hC000, 16'hC040, 16'hC080};
%000001             run_single("T5_both_neg", w, f,
%000001                         compute_dot_product(f, w));
        
                    // ------ T6: double inference (completes DPE) ------
%000001             w  = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
%000001             f  = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
%000001             f2 = '{16'h4000, 16'h4000, 16'h4000, 16'h4000};
%000001             run_double("T6_double", w, f, f2,
%000001                         compute_dot_product(f, w));
        
                    // ------ T7: back-to-back result_out test ------
%000001             w  = '{16'h4000, 16'h4000, 16'h4000, 16'h4000};
%000001             f  = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
%000001             f2 = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
%000001             run_double("T7_result_out", w, f, f2,
%000001                         compute_dot_product(f, w));
        
                    // ------ T8: large values ------
                    // 64.0 = 0x4280, 0.25 = 0x3E80
%000001             w  = '{16'h4280, 16'h3E80, 16'h3F80, 16'h4000};
%000001             f  = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
%000001             f2 = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
%000001             run_double("T8_large", w, f, f2,
%000001                         compute_dot_product(f, w));
        
%000001             `uvm_info("TEST", "===== All tests finished =====", UVM_LOW)
~000020             repeat (20) @(posedge vif.clk);
%000001             phase.drop_objection(this);
                endtask
        
%000001         function void report_phase(uvm_phase phase);
                    `uvm_info("TEST", $sformatf(
                        "\n========== TEST REPORT ==========\nTotal checks : %0d\nPass         : %0d\nFail         : %0d\nTimeout      : %0d\n=================================",
                        env.sb.num_checks, env.sb.num_pass,
%000001                 env.sb.num_fail, env.sb.num_timeout), UVM_LOW)
                endfunction
            endclass
        
        endpackage
        
