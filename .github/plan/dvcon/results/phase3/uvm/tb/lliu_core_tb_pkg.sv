package lliu_core_tb_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    localparam int TB_VEC = 4;

    // -----------------------------------------------------------------
    // Static config: holds the virtual interface handle
    // -----------------------------------------------------------------
    class lliu_core_cfg;
        static virtual lliu_core_if vif;
    endclass

    // -----------------------------------------------------------------
    // Reference-model helpers
    // -----------------------------------------------------------------
    function automatic real fp32_to_real(input logic [31:0] fp32);
        logic [63:0] fp64;
        logic [10:0] fp64_exp;
        if (fp32[30:0] == 31'b0) return 0.0;
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

        `uvm_object_utils(lliu_core_seq_item)

        function new(string name = "lliu_core_seq_item");
            super.new(name);
        endfunction
    endclass

    // -----------------------------------------------------------------
    // Scoreboard
    // -----------------------------------------------------------------
    class lliu_core_scoreboard extends uvm_component;
        `uvm_component_utils(lliu_core_scoreboard)

        int unsigned num_checks;
        int unsigned num_pass;
        int unsigned num_fail;
        int unsigned num_timeout;
        string       bug_log;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            num_checks  = 0;
            num_pass    = 0;
            num_fail    = 0;
            num_timeout = 0;
            bug_log     = "";
        endfunction

        function void check_result(logic [31:0] dut_result,
                                   real          expected,
                                   string        test_name);
            real actual_r, diff, ref_abs, rel;
            actual_r = fp32_to_real(dut_result);
            diff     = actual_r - expected;
            if (diff < 0.0) diff = -diff;
            ref_abs  = expected;
            if (ref_abs < 0.0) ref_abs = -ref_abs;
            rel = (ref_abs > 1.0e-12) ? diff / ref_abs : diff;

            num_checks = num_checks + 1;

            if (rel < 0.001) begin
                num_pass = num_pass + 1;
                `uvm_info("SB", $sformatf("[%s] PASS: expected=%0g actual=%0g",
                          test_name, expected, actual_r), UVM_LOW)
            end else begin
                num_fail = num_fail + 1;
                `uvm_warning("SB", $sformatf(
                    "[%s] MISMATCH: expected=%0g actual=%0g (0x%08h)",
                    test_name, expected, actual_r, dut_result))
                bug_log = {bug_log,
                    $sformatf("| %s | %0g | %0g (0x%08h) | mismatch |\n",
                              test_name, expected, actual_r, dut_result)};
            end
        endfunction

        function void log_timeout(string test_name, real expected);
            num_timeout = num_timeout + 1;
            `uvm_warning("SB", $sformatf(
                "[%s] TIMEOUT: DPE never produced result_valid (expected=%0g)",
                test_name, expected))
            bug_log = {bug_log,
                $sformatf("| %s | %0g | TIMEOUT | DPE stuck |\n",
                          test_name, expected)};
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SB", $sformatf(
                "\n--- Scoreboard Summary ---\nChecks: %0d  Pass: %0d  Fail: %0d  Timeout: %0d",
                num_checks, num_pass, num_fail, num_timeout), UVM_LOW)
        endfunction
    endclass

    // -----------------------------------------------------------------
    // Driver
    // -----------------------------------------------------------------
    class lliu_core_driver extends uvm_component;
        `uvm_component_utils(lliu_core_driver)

        virtual lliu_core_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            vif = lliu_core_cfg::vif;
        endfunction

        task do_reset();
            vif.rst            <= 1'b1;
            vif.features_valid <= 1'b0;
            vif.wgt_wr_en      <= 1'b0;
            vif.wgt_wr_addr    <= '0;
            vif.wgt_wr_data    <= '0;
            for (int i = 0; i < TB_VEC; i++) vif.features[i] <= '0;
            repeat (10) @(posedge vif.clk);
            vif.rst <= 1'b0;
            repeat (5) @(posedge vif.clk);
        endtask

        task load_weights(input logic [15:0] w [TB_VEC]);
            for (int i = 0; i < TB_VEC; i++) begin
                @(posedge vif.clk);
                vif.wgt_wr_en   <= 1'b1;
                vif.wgt_wr_addr <= i[1:0];
                vif.wgt_wr_data <= w[i];
            end
            @(posedge vif.clk);
            vif.wgt_wr_en <= 1'b0;
        endtask

        task drive_features(input logic [15:0] f [TB_VEC]);
            @(posedge vif.clk);
            for (int i = 0; i < TB_VEC; i++) vif.features[i] <= f[i];
            vif.features_valid <= 1'b1;
            @(posedge vif.clk);
            vif.features_valid <= 1'b0;
        endtask
    endclass

    // -----------------------------------------------------------------
    // Monitor
    // -----------------------------------------------------------------
    class lliu_core_monitor extends uvm_component;
        `uvm_component_utils(lliu_core_monitor)

        virtual lliu_core_if vif;
        logic [31:0] last_result;
        logic        got_result;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            got_result = 0;
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            vif = lliu_core_cfg::vif;
        endfunction

        task run_phase(uvm_phase phase);
            forever begin
                @(posedge vif.clk);
                if (vif.result_valid) begin
                    last_result = vif.result;
                    got_result  = 1;
                end
            end
        endtask
    endclass

    // -----------------------------------------------------------------
    // Agent
    // -----------------------------------------------------------------
    class lliu_core_agent extends uvm_component;
        `uvm_component_utils(lliu_core_agent)

        lliu_core_driver  drv;
        lliu_core_monitor mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv = lliu_core_driver::type_id::create("drv", this);
            mon = lliu_core_monitor::type_id::create("mon", this);
        endfunction
    endclass

    // -----------------------------------------------------------------
    // Environment
    // -----------------------------------------------------------------
    class lliu_core_env extends uvm_env;
        `uvm_component_utils(lliu_core_env)

        lliu_core_agent      agt;
        lliu_core_scoreboard sb;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agt = lliu_core_agent::type_id::create("agt", this);
            sb  = lliu_core_scoreboard::type_id::create("sb", this);
        endfunction
    endclass

    // -----------------------------------------------------------------
    // Base test
    // -----------------------------------------------------------------
    class lliu_core_base_test extends uvm_test;
        `uvm_component_utils(lliu_core_base_test)

        lliu_core_env        env;
        virtual lliu_core_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = lliu_core_env::type_id::create("env", this);
            vif = lliu_core_cfg::vif;
        endfunction

        // ---- helper: run a single inference (may timeout) -----------
        task run_single(
            input string        test_name,
            input logic [15:0]  weights  [TB_VEC],
            input logic [15:0]  features [TB_VEC],
            input real          expected,
            input int           do_rst = 1
        );
            if (do_rst) env.agt.drv.do_reset();
            env.agt.drv.load_weights(weights);
            repeat (2) @(posedge vif.clk);
            env.agt.mon.got_result = 0;
            env.agt.drv.drive_features(features);
            begin
                int cyc;
                for (cyc = 0; cyc < 300; cyc++) begin
                    @(posedge vif.clk);
                    if (env.agt.mon.got_result) begin
                        env.sb.check_result(env.agt.mon.last_result,
                                            expected, test_name);
                        return;
                    end
                end
                env.sb.log_timeout(test_name, expected);
            end
        endtask

        // ---- helper: double inference (second provides missing elem)
        task run_double(
            input string        test_name,
            input logic [15:0]  weights  [TB_VEC],
            input logic [15:0]  feat1    [TB_VEC],
            input logic [15:0]  feat2    [TB_VEC],
            input real          expected
        );
            env.agt.drv.do_reset();
            env.agt.drv.load_weights(weights);
            repeat (2) @(posedge vif.clk);
            env.agt.mon.got_result = 0;

            // 1st inference (will timeout — DPE stuck at element VEC_LEN-1)
            env.agt.drv.drive_features(feat1);
            repeat (30) @(posedge vif.clk);

            // 2nd inference provides the missing element to the DPE
            env.agt.drv.drive_features(feat2);

            begin
                int cyc;
                for (cyc = 0; cyc < 300; cyc++) begin
                    @(posedge vif.clk);
                    if (env.agt.mon.got_result) begin
                        env.sb.check_result(env.agt.mon.last_result,
                                            expected, test_name);
                        return;
                    end
                end
                env.sb.log_timeout(test_name, expected);
            end
        endtask

        // ---- main test body -----------------------------------------
        task run_phase(uvm_phase phase);
            // bf16 constants
            logic [15:0] w [TB_VEC];
            logic [15:0] f [TB_VEC];
            logic [15:0] f2[TB_VEC];

            phase.raise_objection(this);
            `uvm_info("TEST", "===== Starting lliu_core tests =====", UVM_LOW)

            // ------ T1: basic (all 1.0 weights) ------
            w = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
            f = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
            run_single("T1_basic", w, f,
                        compute_dot_product(f, w));

            // ------ T2: zero weights ------
            w = '{16'h0000, 16'h0000, 16'h0000, 16'h0000};
            f = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
            run_single("T2_zero_wgt", w, f,
                        compute_dot_product(f, w));

            // ------ T3: mixed positive ------
            w = '{16'h4000, 16'h3F00, 16'h3F80, 16'h4040};
            f = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
            run_single("T3_mixed", w, f,
                        compute_dot_product(f, w));

            // ------ T4: negative weights ------
            w = '{16'h3F80, 16'hBF80, 16'h3F80, 16'hBF80};
            f = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
            run_single("T4_neg_wgt", w, f,
                        compute_dot_product(f, w));

            // ------ T5: both negative (triggers sign OR bug) ------
            w = '{16'hBF80, 16'hBF80, 16'hBF80, 16'hBF80};
            f = '{16'hBF80, 16'hC000, 16'hC040, 16'hC080};
            run_single("T5_both_neg", w, f,
                        compute_dot_product(f, w));

            // ------ T6: double inference (completes DPE) ------
            w  = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
            f  = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
            f2 = '{16'h4000, 16'h4000, 16'h4000, 16'h4000};
            run_double("T6_double", w, f, f2,
                        compute_dot_product(f, w));

            // ------ T7: back-to-back result_out test ------
            w  = '{16'h4000, 16'h4000, 16'h4000, 16'h4000};
            f  = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
            f2 = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
            run_double("T7_result_out", w, f, f2,
                        compute_dot_product(f, w));

            // ------ T8: large values ------
            // 64.0 = 0x4280, 0.25 = 0x3E80
            w  = '{16'h4280, 16'h3E80, 16'h3F80, 16'h4000};
            f  = '{16'h3F80, 16'h4000, 16'h4040, 16'h4080};
            f2 = '{16'h3F80, 16'h3F80, 16'h3F80, 16'h3F80};
            run_double("T8_large", w, f, f2,
                        compute_dot_product(f, w));

            `uvm_info("TEST", "===== All tests finished =====", UVM_LOW)
            repeat (20) @(posedge vif.clk);
            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            `uvm_info("TEST", $sformatf(
                "\n========== TEST REPORT ==========\nTotal checks : %0d\nPass         : %0d\nFail         : %0d\nTimeout      : %0d\n=================================",
                env.sb.num_checks, env.sb.num_pass,
                env.sb.num_fail, env.sb.num_timeout), UVM_LOW)
        endfunction
    endclass

endpackage
