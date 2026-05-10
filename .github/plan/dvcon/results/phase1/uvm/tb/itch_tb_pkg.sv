// itch_tb_pkg.sv — UVM testbench package for itch_field_extract
package itch_tb_pkg;

    import uvm_pkg::*;
    `include "uvm_macros.svh"

    // -------------------------------------------------------------------------
    // Sequence item: holds stimulus inputs and observed outputs
    // -------------------------------------------------------------------------
    class itch_seq_item extends uvm_sequence_item;

        // Stimulus
        rand bit          rst;
        rand bit          msg_valid;
        rand bit [287:0]  msg_data;

        // Observed outputs (filled by monitor)
        bit [7:0]   out_message_type;
        bit [63:0]  out_order_ref;
        bit         out_side;
        bit [31:0]  out_price;
        bit [63:0]  out_stock;
        bit         out_fields_valid;

        `uvm_object_utils_begin(itch_seq_item)
            `uvm_field_int(rst,              UVM_DEFAULT)
            `uvm_field_int(msg_valid,        UVM_DEFAULT)
            `uvm_field_int(msg_data,         UVM_DEFAULT)
            `uvm_field_int(out_message_type, UVM_DEFAULT)
            `uvm_field_int(out_order_ref,    UVM_DEFAULT)
            `uvm_field_int(out_side,         UVM_DEFAULT)
            `uvm_field_int(out_price,        UVM_DEFAULT)
            `uvm_field_int(out_stock,        UVM_DEFAULT)
            `uvm_field_int(out_fields_valid, UVM_DEFAULT)
        `uvm_object_utils_end

        function new(string name = "itch_seq_item");
            super.new(name);
        endfunction

        // Helper: build a packed Add Order message body.
        // byte 0 is at MSB (bits 287:280) per DUT layout: byte[N] = msg_data[(35-N)*8 +: 8]
        static function bit [287:0] pack_add_order(
            bit [7:0]  msg_type,
            bit [15:0] stock_locate,
            bit [15:0] tracking_number,
            bit [47:0] timestamp,
            bit [63:0] order_ref,
            bit [7:0]  buy_sell,
            bit [31:0] shares,
            bit [63:0] stock,
            bit [31:0] price
        );
            bit [287:0] d;
            d = '0;
            d[(35- 0)*8 +: 8] = msg_type;
            d[(35- 1)*8 +: 8] = stock_locate[15:8];
            d[(35- 2)*8 +: 8] = stock_locate[7:0];
            d[(35- 3)*8 +: 8] = tracking_number[15:8];
            d[(35- 4)*8 +: 8] = tracking_number[7:0];
            d[(35- 5)*8 +: 8] = timestamp[47:40];
            d[(35- 6)*8 +: 8] = timestamp[39:32];
            d[(35- 7)*8 +: 8] = timestamp[31:24];
            d[(35- 8)*8 +: 8] = timestamp[23:16];
            d[(35- 9)*8 +: 8] = timestamp[15:8];
            d[(35-10)*8 +: 8] = timestamp[7:0];
            d[(35-11)*8 +: 8] = order_ref[63:56];
            d[(35-12)*8 +: 8] = order_ref[55:48];
            d[(35-13)*8 +: 8] = order_ref[47:40];
            d[(35-14)*8 +: 8] = order_ref[39:32];
            d[(35-15)*8 +: 8] = order_ref[31:24];
            d[(35-16)*8 +: 8] = order_ref[23:16];
            d[(35-17)*8 +: 8] = order_ref[15:8];
            d[(35-18)*8 +: 8] = order_ref[7:0];
            d[(35-19)*8 +: 8] = buy_sell;
            d[(35-20)*8 +: 8] = shares[31:24];
            d[(35-21)*8 +: 8] = shares[23:16];
            d[(35-22)*8 +: 8] = shares[15:8];
            d[(35-23)*8 +: 8] = shares[7:0];
            d[(35-24)*8 +: 8] = stock[63:56];
            d[(35-25)*8 +: 8] = stock[55:48];
            d[(35-26)*8 +: 8] = stock[47:40];
            d[(35-27)*8 +: 8] = stock[39:32];
            d[(35-28)*8 +: 8] = stock[31:24];
            d[(35-29)*8 +: 8] = stock[23:16];
            d[(35-30)*8 +: 8] = stock[15:8];
            d[(35-31)*8 +: 8] = stock[7:0];
            d[(35-32)*8 +: 8] = price[31:24];
            d[(35-33)*8 +: 8] = price[23:16];
            d[(35-34)*8 +: 8] = price[15:8];
            d[(35-35)*8 +: 8] = price[7:0];
            return d;
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Driver
    // -------------------------------------------------------------------------
    class itch_driver extends uvm_driver #(itch_seq_item);
        `uvm_component_utils(itch_driver)
        virtual itch_if vif;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual itch_if)::get(this, "", "vif", vif))
                `uvm_fatal("DRV", "Could not get virtual interface")
        endfunction

        task run_phase(uvm_phase phase);
            // Drive on negedge with blocking assignments: this is the simplest
            // race-free style. Each item I drives signals starting at negedge I,
            // so the next posedge samples item I cleanly.
            forever begin
                seq_item_port.get_next_item(req);
                @(negedge vif.clk);
                vif.rst       = req.rst;
                vif.msg_valid = req.msg_valid;
                vif.msg_data  = req.msg_data;
                seq_item_port.item_done();
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Monitor — samples inputs and outputs every cycle and ships pairs to
    // the analysis port. The DUT is registered: outputs at cycle K reflect
    // inputs that were applied at cycle K-1.
    // -------------------------------------------------------------------------
    class itch_monitor extends uvm_monitor;
        `uvm_component_utils(itch_monitor)
        virtual itch_if vif;
        uvm_analysis_port #(itch_seq_item) ap;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap = new("ap", this);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            if (!uvm_config_db#(virtual itch_if)::get(this, "", "vif", vif))
                `uvm_fatal("MON", "Could not get virtual interface")
        endfunction

        task run_phase(uvm_phase phase);
            itch_seq_item t;
            // Sample one delta after posedge so NBA region has settled.
            forever begin
                @(posedge vif.clk);
                #1;
                t = itch_seq_item::type_id::create("t");
                t.rst              = vif.rst;
                t.msg_valid        = vif.msg_valid;
                t.msg_data         = vif.msg_data;
                t.out_message_type = vif.message_type;
                t.out_order_ref    = vif.order_ref;
                t.out_side         = vif.side;
                t.out_price        = vif.price;
                t.out_stock        = vif.stock;
                t.out_fields_valid = vif.fields_valid;
                ap.write(t);
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Agent
    // -------------------------------------------------------------------------
    class itch_agent extends uvm_agent;
        `uvm_component_utils(itch_agent)

        itch_driver                       drv;
        uvm_sequencer #(itch_seq_item)    sqr;
        itch_monitor                      mon;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            drv = itch_driver::type_id::create("drv", this);
            sqr = uvm_sequencer #(itch_seq_item)::type_id::create("sqr", this);
            mon = itch_monitor::type_id::create("mon", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            drv.seq_item_port.connect(sqr.seq_item_export);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Scoreboard — receives sampled (input, output) pairs and verifies that
    // the output observed at cycle K matches the expected function of the
    // input observed at cycle K-1 (one pipeline stage of latency).
    // -------------------------------------------------------------------------
    `uvm_analysis_imp_decl(_itch)
    class itch_scoreboard extends uvm_scoreboard;
        `uvm_component_utils(itch_scoreboard)

        uvm_analysis_imp_itch #(itch_seq_item, itch_scoreboard) ap_imp;

        // Counters (reported at end-of-test)
        int unsigned checks;
        int unsigned errors;

        function new(string name, uvm_component parent);
            super.new(name, parent);
            ap_imp = new("ap_imp", this);
            checks = 0;
            errors = 0;
        endfunction

        // Predict expected outputs from the previous cycle's input
        function void predict(
            input  bit          rst,
            input  bit          msg_valid,
            input  bit [287:0]  msg_data,
            output bit [7:0]    exp_message_type,
            output bit [63:0]   exp_order_ref,
            output bit          exp_side,
            output bit [31:0]   exp_price,
            output bit [63:0]   exp_stock,
            output bit          exp_fields_valid
        );
            bit [7:0] mt;
            if (rst) begin
                exp_message_type = 8'h00;
                exp_order_ref    = 64'd0;
                exp_side         = 1'b0;
                exp_price        = 32'd0;
                exp_stock        = 64'd0;
                exp_fields_valid = 1'b0;
            end else begin
                mt = msg_data[(35-0)*8 +: 8];
                exp_message_type = mt;
                exp_order_ref = {
                    msg_data[(35-11)*8 +: 8],
                    msg_data[(35-12)*8 +: 8],
                    msg_data[(35-13)*8 +: 8],
                    msg_data[(35-14)*8 +: 8],
                    msg_data[(35-15)*8 +: 8],
                    msg_data[(35-16)*8 +: 8],
                    msg_data[(35-17)*8 +: 8],
                    msg_data[(35-18)*8 +: 8]
                };
                exp_side  = (msg_data[(35-19)*8 +: 8] == 8'h42);
                exp_price = {
                    msg_data[(35-32)*8 +: 8],
                    msg_data[(35-33)*8 +: 8],
                    msg_data[(35-34)*8 +: 8],
                    msg_data[(35-35)*8 +: 8]
                };
                exp_stock = {
                    msg_data[(35-24)*8 +: 8],
                    msg_data[(35-25)*8 +: 8],
                    msg_data[(35-26)*8 +: 8],
                    msg_data[(35-27)*8 +: 8],
                    msg_data[(35-28)*8 +: 8],
                    msg_data[(35-29)*8 +: 8],
                    msg_data[(35-30)*8 +: 8],
                    msg_data[(35-31)*8 +: 8]
                };
                exp_fields_valid = msg_valid && (mt == 8'h41);
            end
        endfunction

        function void write_itch(itch_seq_item t);
            bit [7:0]   exp_mt;
            bit [63:0]  exp_or;
            bit         exp_sd;
            bit [31:0]  exp_pr;
            bit [63:0]  exp_st;
            bit         exp_fv;

            // With blocking-at-negedge driver semantics, the input observed
            // at sample K and the output observed at sample K are aligned —
            // both reflect the value driven at the negedge before posedge K.
            predict(t.rst, t.msg_valid, t.msg_data,
                    exp_mt, exp_or, exp_sd, exp_pr, exp_st, exp_fv);

            checks++;

            if (t.out_message_type !== exp_mt) begin
                `uvm_error("SCB", $sformatf(
                    "message_type mismatch: got 0x%0h exp 0x%0h (msg_data=0x%0h rst=%0b valid=%0b)",
                    t.out_message_type, exp_mt, t.msg_data, t.rst, t.msg_valid))
                errors++;
            end
            if (t.out_order_ref !== exp_or) begin
                `uvm_error("SCB", $sformatf(
                    "order_ref mismatch: got 0x%0h exp 0x%0h",
                    t.out_order_ref, exp_or))
                errors++;
            end
            if (t.out_side !== exp_sd) begin
                `uvm_error("SCB", $sformatf(
                    "side mismatch: got %0b exp %0b (data=0x%0h)",
                    t.out_side, exp_sd, t.msg_data))
                errors++;
            end
            if (t.out_price !== exp_pr) begin
                `uvm_error("SCB", $sformatf(
                    "price mismatch: got 0x%0h exp 0x%0h",
                    t.out_price, exp_pr))
                errors++;
            end
            if (t.out_stock !== exp_st) begin
                `uvm_error("SCB", $sformatf(
                    "stock mismatch: got 0x%0h exp 0x%0h",
                    t.out_stock, exp_st))
                errors++;
            end
            if (t.out_fields_valid !== exp_fv) begin
                `uvm_error("SCB", $sformatf(
                    "fields_valid mismatch: got %0b exp %0b (rst=%0b valid=%0b mt=0x%0h)",
                    t.out_fields_valid, exp_fv, t.rst, t.msg_valid,
                    t.msg_data[(35-0)*8 +: 8]))
                errors++;
            end
        endfunction

        function void report_phase(uvm_phase phase);
            `uvm_info("SCB", $sformatf("Scoreboard summary: %0d checks, %0d errors",
                checks, errors), UVM_LOW)
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Environment
    // -------------------------------------------------------------------------
    class itch_env extends uvm_env;
        `uvm_component_utils(itch_env)

        itch_agent        agent;
        itch_scoreboard   scb;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            agent = itch_agent::type_id::create("agent", this);
            scb   = itch_scoreboard::type_id::create("scb", this);
        endfunction

        function void connect_phase(uvm_phase phase);
            agent.mon.ap.connect(scb.ap_imp);
        endfunction
    endclass

    // -------------------------------------------------------------------------
    // Sequences
    // -------------------------------------------------------------------------

    // Helper sequence: drive a single transaction with given fields.
    class itch_drive_one_seq extends uvm_sequence #(itch_seq_item);
        `uvm_object_utils(itch_drive_one_seq)
        bit          rst       = 0;
        bit          msg_valid = 0;
        bit [287:0]  msg_data  = '0;

        function new(string name = "itch_drive_one_seq");
            super.new(name);
        endfunction

        task body();
            req = itch_seq_item::type_id::create("req");
            start_item(req);
            req.rst       = rst;
            req.msg_valid = msg_valid;
            req.msg_data  = msg_data;
            finish_item(req);
        endtask
    endclass

    // Drive an idle (rst=0, msg_valid=0) cycle.
    class itch_idle_seq extends uvm_sequence #(itch_seq_item);
        `uvm_object_utils(itch_idle_seq)
        int unsigned cycles = 1;
        function new(string name = "itch_idle_seq");
            super.new(name);
        endfunction
        task body();
            for (int i = 0; i < cycles; i++) begin
                req = itch_seq_item::type_id::create("req");
                start_item(req);
                req.rst = 0; req.msg_valid = 0; req.msg_data = '0;
                finish_item(req);
            end
        endtask
    endclass

    // Hold reset for N cycles
    class itch_reset_seq extends uvm_sequence #(itch_seq_item);
        `uvm_object_utils(itch_reset_seq)
        int unsigned cycles = 4;
        function new(string name = "itch_reset_seq");
            super.new(name);
        endfunction
        task body();
            for (int i = 0; i < cycles; i++) begin
                req = itch_seq_item::type_id::create("req");
                start_item(req);
                req.rst = 1; req.msg_valid = 0; req.msg_data = '0;
                finish_item(req);
            end
        endtask
    endclass

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    // Base test: builds env, opens reset, runs the body, then drains.
    virtual class itch_base_test extends uvm_test;
        itch_env env;

        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction

        function void build_phase(uvm_phase phase);
            super.build_phase(phase);
            env = itch_env::type_id::create("env", this);
        endfunction

        // Hook for derived tests
        pure virtual task body_seq();

        task run_phase(uvm_phase phase);
            itch_reset_seq    rseq;
            itch_idle_seq     iseq;
            phase.raise_objection(this);
            rseq = itch_reset_seq::type_id::create("rseq");
            rseq.cycles = 4;
            rseq.start(env.agent.sqr);

            iseq = itch_idle_seq::type_id::create("iseq_pre");
            iseq.cycles = 2;
            iseq.start(env.agent.sqr);

            body_seq();

            iseq = itch_idle_seq::type_id::create("iseq_post");
            iseq.cycles = 4;
            iseq.start(env.agent.sqr);
            phase.drop_objection(this);
        endtask

        function void report_phase(uvm_phase phase);
            uvm_report_server srv = uvm_report_server::get_server();
            int err = srv.get_severity_count(UVM_ERROR)
                    + srv.get_severity_count(UVM_FATAL);
            if (err > 0) begin
                `uvm_info("TEST", $sformatf("TEST FAILED with %0d errors", err), UVM_NONE)
            end else begin
                `uvm_info("TEST", "TEST PASSED", UVM_NONE)
            end
        endfunction
    endclass

    // Drive a single Add Order, buy side
    class test_buy extends itch_base_test;
        `uvm_component_utils(test_buy)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task body_seq();
            itch_drive_one_seq s;
            s = itch_drive_one_seq::type_id::create("s");
            s.rst = 0;
            s.msg_valid = 1;
            s.msg_data = itch_seq_item::pack_add_order(
                .msg_type(8'h41),
                .stock_locate(16'h1234),
                .tracking_number(16'h5678),
                .timestamp(48'h0011_2233_4455),
                .order_ref(64'hDEAD_BEEF_CAFE_BABE),
                .buy_sell(8'h42),       // 'B'
                .shares(32'h0000_0064),
                .stock(64'h4141_5050_4C45_2020),  // "AAPL  "
                .price(32'h0001_869F)
            );
            s.start(env.agent.sqr);
        endtask
    endclass

    // Drive a single Add Order, sell side
    class test_sell extends itch_base_test;
        `uvm_component_utils(test_sell)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task body_seq();
            itch_drive_one_seq s;
            s = itch_drive_one_seq::type_id::create("s");
            s.rst = 0;
            s.msg_valid = 1;
            s.msg_data = itch_seq_item::pack_add_order(
                .msg_type(8'h41),
                .stock_locate(16'h00AA),
                .tracking_number(16'h00BB),
                .timestamp(48'h1234_5678_9ABC),
                .order_ref(64'h0123_4567_89AB_CDEF),
                .buy_sell(8'h53),       // 'S'
                .shares(32'h0000_03E8),
                .stock(64'h474F_4F47_2020_2020),  // "GOOG    "
                .price(32'h0030_D40)
            );
            s.start(env.agent.sqr);
        endtask
    endclass

    // Drive a non-Add-Order message (msg_valid=1, but msg_type != 0x41)
    class test_non_add_order extends itch_base_test;
        `uvm_component_utils(test_non_add_order)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task body_seq();
            itch_drive_one_seq s;
            // Use 'D' (Order Delete) and 'E' (Order Exec) — not 0x41
            s = itch_drive_one_seq::type_id::create("s_delete");
            s.rst = 0;
            s.msg_valid = 1;
            s.msg_data = itch_seq_item::pack_add_order(
                .msg_type(8'h44),  // 'D' delete
                .stock_locate(16'h1111),
                .tracking_number(16'h2222),
                .timestamp(48'hAA_BB_CC_DD_EE_FF),
                .order_ref(64'hAAAA_BBBB_CCCC_DDDD),
                .buy_sell(8'h42),
                .shares(32'h0000_0001),
                .stock(64'h0),
                .price(32'h0)
            );
            s.start(env.agent.sqr);

            s = itch_drive_one_seq::type_id::create("s_exec");
            s.rst = 0;
            s.msg_valid = 1;
            s.msg_data = itch_seq_item::pack_add_order(
                .msg_type(8'h45),  // 'E' execute
                .stock_locate(16'h3333),
                .tracking_number(16'h4444),
                .timestamp(48'd0),
                .order_ref(64'hFFEE_DDCC_BBAA_9988),
                .buy_sell(8'h53),
                .shares(32'h0000_00FF),
                .stock(64'h0),
                .price(32'h0)
            );
            s.start(env.agent.sqr);
        endtask
    endclass

    // Synchronous reset behaviour
    class test_reset extends itch_base_test;
        `uvm_component_utils(test_reset)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task body_seq();
            itch_drive_one_seq s;
            itch_reset_seq     rseq;
            // First drive a valid Add Order so outputs are non-zero
            s = itch_drive_one_seq::type_id::create("s_pre");
            s.rst = 0;
            s.msg_valid = 1;
            s.msg_data = itch_seq_item::pack_add_order(
                8'h41, 16'hAAAA, 16'hBBBB, 48'h1, 64'hFFFF_FFFF_FFFF_FFFF,
                8'h42, 32'h12345678,
                64'h4D53_4654_2020_2020,  // "MSFT    "
                32'h0099_9999
            );
            s.start(env.agent.sqr);

            // Now apply reset for several cycles → outputs go to 0
            rseq = itch_reset_seq::type_id::create("rseq_mid");
            rseq.cycles = 5;
            rseq.start(env.agent.sqr);

            // Then drive valid again
            s = itch_drive_one_seq::type_id::create("s_post");
            s.rst = 0;
            s.msg_valid = 1;
            s.msg_data = itch_seq_item::pack_add_order(
                8'h41, 16'h0001, 16'h0002, 48'h3, 64'h0123_4567_89AB_CDEF,
                8'h53, 32'h00000064,
                64'h4942_4D20_2020_2020, // "IBM     "
                32'h0001_0000
            );
            s.start(env.agent.sqr);
        endtask
    endclass

    // Back-to-back valid messages with no idle cycles
    class test_back_to_back extends itch_base_test;
        `uvm_component_utils(test_back_to_back)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task body_seq();
            itch_drive_one_seq s;
            // Five back-to-back valid Add Orders — alternate buy/sell, varied data
            for (int i = 0; i < 5; i++) begin
                bit [7:0] bs;
                bs = (i[0]) ? 8'h53 : 8'h42;
                s = itch_drive_one_seq::type_id::create($sformatf("s_b2b_%0d", i));
                s.rst = 0;
                s.msg_valid = 1;
                s.msg_data = itch_seq_item::pack_add_order(
                    .msg_type(8'h41),
                    .stock_locate(16'h0010 + i[15:0]),
                    .tracking_number(16'h0020 + i[15:0]),
                    .timestamp(48'h1000 + i),
                    .order_ref(64'hABCD_0000_0000_0000 | i),
                    .buy_sell(bs),
                    .shares(32'h0000_0010 + i),
                    .stock(64'h5350_5920_2020_2020 + i),
                    .price(32'h0001_0000 + i*32'h100)
                );
                s.start(env.agent.sqr);
            end
        endtask
    endclass

    // msg_valid deasserted while msg_data toggles → fields_valid stays 0
    class test_msg_valid_low extends itch_base_test;
        `uvm_component_utils(test_msg_valid_low)
        function new(string name, uvm_component parent);
            super.new(name, parent);
        endfunction
        task body_seq();
            itch_drive_one_seq s;
            // Drive msg_valid=0 with various data patterns, including one that
            // would otherwise be a valid Add Order.
            s = itch_drive_one_seq::type_id::create("s_inv0");
            s.rst = 0;
            s.msg_valid = 0;
            s.msg_data = itch_seq_item::pack_add_order(
                8'h41, 16'h1, 16'h2, 48'h3, 64'h4,
                8'h42, 32'h5, 64'h6, 32'h7
            );
            s.start(env.agent.sqr);

            s = itch_drive_one_seq::type_id::create("s_inv1");
            s.rst = 0;
            s.msg_valid = 0;
            s.msg_data = '1;
            s.start(env.agent.sqr);

            s = itch_drive_one_seq::type_id::create("s_inv2");
            s.rst = 0;
            s.msg_valid = 0;
            s.msg_data = itch_seq_item::pack_add_order(
                8'h44, 16'h0, 16'h0, 48'h0, 64'h0,
                8'h53, 32'h0, 64'h0, 32'h0
            );
            s.start(env.agent.sqr);
        endtask
    endclass

endpackage
