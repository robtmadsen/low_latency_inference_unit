//      // verilator_coverage annotation
        // itch_tb_pkg.sv — UVM testbench package for itch_field_extract
        package itch_tb_pkg;
        
            import uvm_pkg::*;
            `include "uvm_macros.svh"
        
            // -------------------------------------------------------------------------
            // Sequence item: holds stimulus inputs and observed outputs
            // -------------------------------------------------------------------------
%000000     class itch_seq_item extends uvm_sequence_item;
        
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
        
~000079         `uvm_object_utils_begin(itch_seq_item)
%000000             `uvm_field_int(rst,              UVM_DEFAULT)
%000000             `uvm_field_int(msg_valid,        UVM_DEFAULT)
%000000             `uvm_field_int(msg_data,         UVM_DEFAULT)
%000000             `uvm_field_int(out_message_type, UVM_DEFAULT)
%000000             `uvm_field_int(out_order_ref,    UVM_DEFAULT)
%000000             `uvm_field_int(out_side,         UVM_DEFAULT)
%000000             `uvm_field_int(out_price,        UVM_DEFAULT)
%000000             `uvm_field_int(out_stock,        UVM_DEFAULT)
%000000             `uvm_field_int(out_fields_valid, UVM_DEFAULT)
                `uvm_object_utils_end
        
~000158         function new(string name = "itch_seq_item");
 000158             super.new(name);
                endfunction
        
                // Helper: build a packed Add Order message body.
                // byte 0 is at MSB (bits 287:280) per DUT layout: byte[N] = msg_data[(35-N)*8 +: 8]
 000013         static function bit [287:0] pack_add_order(
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
 000013             bit [287:0] d;
 000013             d = '0;
 000013             d[(35- 0)*8 +: 8] = msg_type;
 000013             d[(35- 1)*8 +: 8] = stock_locate[15:8];
 000013             d[(35- 2)*8 +: 8] = stock_locate[7:0];
 000013             d[(35- 3)*8 +: 8] = tracking_number[15:8];
 000013             d[(35- 4)*8 +: 8] = tracking_number[7:0];
 000013             d[(35- 5)*8 +: 8] = timestamp[47:40];
 000013             d[(35- 6)*8 +: 8] = timestamp[39:32];
 000013             d[(35- 7)*8 +: 8] = timestamp[31:24];
 000013             d[(35- 8)*8 +: 8] = timestamp[23:16];
 000013             d[(35- 9)*8 +: 8] = timestamp[15:8];
 000013             d[(35-10)*8 +: 8] = timestamp[7:0];
 000013             d[(35-11)*8 +: 8] = order_ref[63:56];
 000013             d[(35-12)*8 +: 8] = order_ref[55:48];
 000013             d[(35-13)*8 +: 8] = order_ref[47:40];
 000013             d[(35-14)*8 +: 8] = order_ref[39:32];
 000013             d[(35-15)*8 +: 8] = order_ref[31:24];
 000013             d[(35-16)*8 +: 8] = order_ref[23:16];
 000013             d[(35-17)*8 +: 8] = order_ref[15:8];
 000013             d[(35-18)*8 +: 8] = order_ref[7:0];
 000013             d[(35-19)*8 +: 8] = buy_sell;
 000013             d[(35-20)*8 +: 8] = shares[31:24];
 000013             d[(35-21)*8 +: 8] = shares[23:16];
 000013             d[(35-22)*8 +: 8] = shares[15:8];
 000013             d[(35-23)*8 +: 8] = shares[7:0];
 000013             d[(35-24)*8 +: 8] = stock[63:56];
 000013             d[(35-25)*8 +: 8] = stock[55:48];
 000013             d[(35-26)*8 +: 8] = stock[47:40];
 000013             d[(35-27)*8 +: 8] = stock[39:32];
 000013             d[(35-28)*8 +: 8] = stock[31:24];
 000013             d[(35-29)*8 +: 8] = stock[23:16];
 000013             d[(35-30)*8 +: 8] = stock[15:8];
 000013             d[(35-31)*8 +: 8] = stock[7:0];
 000013             d[(35-32)*8 +: 8] = price[31:24];
 000013             d[(35-33)*8 +: 8] = price[23:16];
 000013             d[(35-34)*8 +: 8] = price[15:8];
 000013             d[(35-35)*8 +: 8] = price[7:0];
 000013             return d;
                endfunction
            endclass
        
            // -------------------------------------------------------------------------
            // Driver
            // -------------------------------------------------------------------------
            class itch_driver extends uvm_driver #(itch_seq_item);
%000000         `uvm_component_utils(itch_driver)
                virtual itch_if vif;
        
%000006         function new(string name, uvm_component parent);
%000006             super.new(name, parent);
                endfunction
        
%000006         function void build_phase(uvm_phase phase);
%000006             super.build_phase(phase);
%000006             if (!uvm_config_db#(virtual itch_if)::get(this, "", "vif", vif))
%000000                 `uvm_fatal("DRV", "Could not get virtual interface")
                endfunction
        
%000000         task run_phase(uvm_phase phase);
                    // Drive on negedge with blocking assignments: this is the simplest
                    // race-free style. Each item I drives signals starting at negedge I,
                    // so the next posedge samples item I cleanly.
 000079             forever begin
 000079                 seq_item_port.get_next_item(req);
 000079                 @(negedge vif.clk);
 000079                 vif.rst       = req.rst;
 000079                 vif.msg_valid = req.msg_valid;
 000079                 vif.msg_data  = req.msg_data;
 000079                 seq_item_port.item_done();
                    end
                endtask
            endclass
        
            // -------------------------------------------------------------------------
            // Monitor — samples inputs and outputs every cycle and ships pairs to
            // the analysis port. The DUT is registered: outputs at cycle K reflect
            // inputs that were applied at cycle K-1.
            // -------------------------------------------------------------------------
            class itch_monitor extends uvm_monitor;
%000000         `uvm_component_utils(itch_monitor)
                virtual itch_if vif;
                uvm_analysis_port #(itch_seq_item) ap;
        
%000006         function new(string name, uvm_component parent);
%000006             super.new(name, parent);
%000006             ap = new("ap", this);
                endfunction
        
%000006         function void build_phase(uvm_phase phase);
%000006             super.build_phase(phase);
%000006             if (!uvm_config_db#(virtual itch_if)::get(this, "", "vif", vif))
%000000                 `uvm_fatal("MON", "Could not get virtual interface")
                endfunction
        
%000000         task run_phase(uvm_phase phase);
%000000             itch_seq_item t;
                    // Sample one delta after posedge so NBA region has settled.
 000079             forever begin
 000079                 @(posedge vif.clk);
 000079                 #1;
 000079                 t = itch_seq_item::type_id::create("t");
 000079                 t.rst              = vif.rst;
 000079                 t.msg_valid        = vif.msg_valid;
 000079                 t.msg_data         = vif.msg_data;
 000079                 t.out_message_type = vif.message_type;
 000079                 t.out_order_ref    = vif.order_ref;
 000079                 t.out_side         = vif.side;
 000079                 t.out_price        = vif.price;
 000079                 t.out_stock        = vif.stock;
 000079                 t.out_fields_valid = vif.fields_valid;
 000079                 ap.write(t);
                    end
                endtask
            endclass
        
            // -------------------------------------------------------------------------
            // Agent
            // -------------------------------------------------------------------------
            class itch_agent extends uvm_agent;
%000000         `uvm_component_utils(itch_agent)
        
                itch_driver                       drv;
                uvm_sequencer #(itch_seq_item)    sqr;
                itch_monitor                      mon;
        
%000006         function new(string name, uvm_component parent);
%000006             super.new(name, parent);
                endfunction
        
%000006         function void build_phase(uvm_phase phase);
%000006             super.build_phase(phase);
%000006             drv = itch_driver::type_id::create("drv", this);
%000006             sqr = uvm_sequencer #(itch_seq_item)::type_id::create("sqr", this);
%000006             mon = itch_monitor::type_id::create("mon", this);
                endfunction
        
%000006         function void connect_phase(uvm_phase phase);
%000006             drv.seq_item_port.connect(sqr.seq_item_export);
                endfunction
            endclass
        
            // -------------------------------------------------------------------------
            // Scoreboard — receives sampled (input, output) pairs and verifies that
            // the output observed at cycle K matches the expected function of the
            // input observed at cycle K-1 (one pipeline stage of latency).
            // -------------------------------------------------------------------------
~000079     `uvm_analysis_imp_decl(_itch)
            class itch_scoreboard extends uvm_scoreboard;
%000000         `uvm_component_utils(itch_scoreboard)
        
                uvm_analysis_imp_itch #(itch_seq_item, itch_scoreboard) ap_imp;
        
                // Counters (reported at end-of-test)
                int unsigned checks;
                int unsigned errors;
        
%000006         function new(string name, uvm_component parent);
%000006             super.new(name, parent);
%000006             ap_imp = new("ap_imp", this);
%000006             checks = 0;
%000006             errors = 0;
                endfunction
        
                // Predict expected outputs from the previous cycle's input
 000079         function void predict(
                    input  bit          rst,
                    input  bit          msg_valid,
                    input  bit [287:0]  msg_data,
 000079             output bit [7:0]    exp_message_type,
 000079             output bit [63:0]   exp_order_ref,
 000079             output bit          exp_side,
 000079             output bit [31:0]   exp_price,
 000079             output bit [63:0]   exp_stock,
 000079             output bit          exp_fields_valid
                );
 000079             bit [7:0] mt;
 000050             if (rst) begin
 000029                 exp_message_type = 8'h00;
 000029                 exp_order_ref    = 64'd0;
 000029                 exp_side         = 1'b0;
 000029                 exp_price        = 32'd0;
 000029                 exp_stock        = 64'd0;
 000029                 exp_fields_valid = 1'b0;
 000050             end else begin
 000050                 mt = msg_data[(35-0)*8 +: 8];
 000050                 exp_message_type = mt;
 000050                 exp_order_ref = {
 000050                     msg_data[(35-11)*8 +: 8],
 000050                     msg_data[(35-12)*8 +: 8],
 000050                     msg_data[(35-13)*8 +: 8],
 000050                     msg_data[(35-14)*8 +: 8],
 000050                     msg_data[(35-15)*8 +: 8],
 000050                     msg_data[(35-16)*8 +: 8],
 000050                     msg_data[(35-17)*8 +: 8],
 000050                     msg_data[(35-18)*8 +: 8]
                        };
 000050                 exp_side  = (msg_data[(35-19)*8 +: 8] == 8'h42);
 000050                 exp_price = {
 000050                     msg_data[(35-32)*8 +: 8],
 000050                     msg_data[(35-33)*8 +: 8],
 000050                     msg_data[(35-34)*8 +: 8],
 000050                     msg_data[(35-35)*8 +: 8]
                        };
 000050                 exp_stock = {
 000050                     msg_data[(35-24)*8 +: 8],
 000050                     msg_data[(35-25)*8 +: 8],
 000050                     msg_data[(35-26)*8 +: 8],
 000050                     msg_data[(35-27)*8 +: 8],
 000050                     msg_data[(35-28)*8 +: 8],
 000050                     msg_data[(35-29)*8 +: 8],
 000050                     msg_data[(35-30)*8 +: 8],
 000050                     msg_data[(35-31)*8 +: 8]
                        };
 000050                 exp_fields_valid = msg_valid && (mt == 8'h41);
                    end
                endfunction
        
 000079         function void write_itch(itch_seq_item t);
 000079             bit [7:0]   exp_mt;
 000079             bit [63:0]  exp_or;
 000079             bit         exp_sd;
 000079             bit [31:0]  exp_pr;
 000079             bit [63:0]  exp_st;
 000079             bit         exp_fv;
        
                    // With blocking-at-negedge driver semantics, the input observed
                    // at sample K and the output observed at sample K are aligned —
                    // both reflect the value driven at the negedge before posedge K.
 000079             predict(t.rst, t.msg_valid, t.msg_data,
 000079                     exp_mt, exp_or, exp_sd, exp_pr, exp_st, exp_fv);
        
 000079             checks++;
        
~000079             if (t.out_message_type !== exp_mt) begin
                        `uvm_error("SCB", $sformatf(
                            "message_type mismatch: got 0x%0h exp 0x%0h (msg_data=0x%0h rst=%0b valid=%0b)",
%000000                     t.out_message_type, exp_mt, t.msg_data, t.rst, t.msg_valid))
%000000                 errors++;
                    end
~000079             if (t.out_order_ref !== exp_or) begin
                        `uvm_error("SCB", $sformatf(
                            "order_ref mismatch: got 0x%0h exp 0x%0h",
%000000                     t.out_order_ref, exp_or))
%000000                 errors++;
                    end
~000079             if (t.out_side !== exp_sd) begin
                        `uvm_error("SCB", $sformatf(
                            "side mismatch: got %0b exp %0b (data=0x%0h)",
%000000                     t.out_side, exp_sd, t.msg_data))
%000000                 errors++;
                    end
~000079             if (t.out_price !== exp_pr) begin
                        `uvm_error("SCB", $sformatf(
                            "price mismatch: got 0x%0h exp 0x%0h",
%000000                     t.out_price, exp_pr))
%000000                 errors++;
                    end
~000079             if (t.out_stock !== exp_st) begin
                        `uvm_error("SCB", $sformatf(
                            "stock mismatch: got 0x%0h exp 0x%0h",
%000000                     t.out_stock, exp_st))
%000000                 errors++;
                    end
~000079             if (t.out_fields_valid !== exp_fv) begin
                        `uvm_error("SCB", $sformatf(
                            "fields_valid mismatch: got %0b exp %0b (rst=%0b valid=%0b mt=0x%0h)",
                            t.out_fields_valid, exp_fv, t.rst, t.msg_valid,
%000000                     t.msg_data[(35-0)*8 +: 8]))
%000000                 errors++;
                    end
                endfunction
        
%000006         function void report_phase(uvm_phase phase);
                    `uvm_info("SCB", $sformatf("Scoreboard summary: %0d checks, %0d errors",
%000006                 checks, errors), UVM_LOW)
                endfunction
            endclass
        
            // -------------------------------------------------------------------------
            // Environment
            // -------------------------------------------------------------------------
            class itch_env extends uvm_env;
%000000         `uvm_component_utils(itch_env)
        
                itch_agent        agent;
                itch_scoreboard   scb;
        
%000006         function new(string name, uvm_component parent);
%000006             super.new(name, parent);
                endfunction
        
%000006         function void build_phase(uvm_phase phase);
%000006             super.build_phase(phase);
%000006             agent = itch_agent::type_id::create("agent", this);
%000006             scb   = itch_scoreboard::type_id::create("scb", this);
                endfunction
        
%000006         function void connect_phase(uvm_phase phase);
%000006             agent.mon.ap.connect(scb.ap_imp);
                endfunction
            endclass
        
            // -------------------------------------------------------------------------
            // Sequences
            // -------------------------------------------------------------------------
        
            // Helper sequence: drive a single transaction with given fields.
            class itch_drive_one_seq extends uvm_sequence #(itch_seq_item);
~000014         `uvm_object_utils(itch_drive_one_seq)
 000014         bit          rst       = 0;
 000014         bit          msg_valid = 0;
 000014         bit [287:0]  msg_data  = '0;
        
~000014         function new(string name = "itch_drive_one_seq");
 000014             super.new(name);
                endfunction
        
 000014         task body();
 000014             req = itch_seq_item::type_id::create("req");
 000014             start_item(req);
 000014             req.rst       = rst;
 000014             req.msg_valid = msg_valid;
 000014             req.msg_data  = msg_data;
 000014             finish_item(req);
                endtask
            endclass
        
            // Drive an idle (rst=0, msg_valid=0) cycle.
            class itch_idle_seq extends uvm_sequence #(itch_seq_item);
~000012         `uvm_object_utils(itch_idle_seq)
 000012         int unsigned cycles = 1;
~000012         function new(string name = "itch_idle_seq");
 000012             super.new(name);
                endfunction
 000012         task body();
 000036             for (int i = 0; i < cycles; i++) begin
 000036                 req = itch_seq_item::type_id::create("req");
 000036                 start_item(req);
 000036                 req.rst = 0; req.msg_valid = 0; req.msg_data = '0;
 000036                 finish_item(req);
                    end
                endtask
            endclass
        
            // Hold reset for N cycles
            class itch_reset_seq extends uvm_sequence #(itch_seq_item);
%000007         `uvm_object_utils(itch_reset_seq)
%000007         int unsigned cycles = 4;
%000007         function new(string name = "itch_reset_seq");
%000007             super.new(name);
                endfunction
%000007         task body();
~000029             for (int i = 0; i < cycles; i++) begin
 000029                 req = itch_seq_item::type_id::create("req");
 000029                 start_item(req);
 000029                 req.rst = 1; req.msg_valid = 0; req.msg_data = '0;
 000029                 finish_item(req);
                    end
                endtask
            endclass
        
            // -------------------------------------------------------------------------
            // Tests
            // -------------------------------------------------------------------------
        
            // Base test: builds env, opens reset, runs the body, then drains.
            virtual class itch_base_test extends uvm_test;
                itch_env env;
        
%000006         function new(string name, uvm_component parent);
%000006             super.new(name, parent);
                endfunction
        
%000006         function void build_phase(uvm_phase phase);
%000006             super.build_phase(phase);
%000006             env = itch_env::type_id::create("env", this);
                endfunction
        
                // Hook for derived tests
%000000         pure virtual task body_seq();
        
%000006         task run_phase(uvm_phase phase);
%000006             itch_reset_seq    rseq;
%000006             itch_idle_seq     iseq;
%000006             phase.raise_objection(this);
%000006             rseq = itch_reset_seq::type_id::create("rseq");
%000006             rseq.cycles = 4;
%000006             rseq.start(env.agent.sqr);
        
%000006             iseq = itch_idle_seq::type_id::create("iseq_pre");
%000006             iseq.cycles = 2;
%000006             iseq.start(env.agent.sqr);
        
%000006             body_seq();
        
%000006             iseq = itch_idle_seq::type_id::create("iseq_post");
%000006             iseq.cycles = 4;
%000006             iseq.start(env.agent.sqr);
%000006             phase.drop_objection(this);
                endtask
        
%000006         function void report_phase(uvm_phase phase);
%000006             uvm_report_server srv = uvm_report_server::get_server();
%000006             int err = srv.get_severity_count(UVM_ERROR)
%000006                     + srv.get_severity_count(UVM_FATAL);
%000006             if (err > 0) begin
%000000                 `uvm_info("TEST", $sformatf("TEST FAILED with %0d errors", err), UVM_NONE)
%000006             end else begin
%000006                 `uvm_info("TEST", "TEST PASSED", UVM_NONE)
                    end
                endfunction
            endclass
        
            // Drive a single Add Order, buy side
            class test_buy extends itch_base_test;
%000001         `uvm_component_utils(test_buy)
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
%000001         task body_seq();
%000001             itch_drive_one_seq s;
%000001             s = itch_drive_one_seq::type_id::create("s");
%000001             s.rst = 0;
%000001             s.msg_valid = 1;
%000001             s.msg_data = itch_seq_item::pack_add_order(
%000001                 .msg_type(8'h41),
%000001                 .stock_locate(16'h1234),
%000001                 .tracking_number(16'h5678),
%000001                 .timestamp(48'h0011_2233_4455),
%000001                 .order_ref(64'hDEAD_BEEF_CAFE_BABE),
%000001                 .buy_sell(8'h42),       // 'B'
%000001                 .shares(32'h0000_0064),
%000001                 .stock(64'h4141_5050_4C45_2020),  // "AAPL  "
%000001                 .price(32'h0001_869F)
                    );
%000001             s.start(env.agent.sqr);
                endtask
            endclass
        
            // Drive a single Add Order, sell side
            class test_sell extends itch_base_test;
%000001         `uvm_component_utils(test_sell)
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
%000001         task body_seq();
%000001             itch_drive_one_seq s;
%000001             s = itch_drive_one_seq::type_id::create("s");
%000001             s.rst = 0;
%000001             s.msg_valid = 1;
%000001             s.msg_data = itch_seq_item::pack_add_order(
%000001                 .msg_type(8'h41),
%000001                 .stock_locate(16'h00AA),
%000001                 .tracking_number(16'h00BB),
%000001                 .timestamp(48'h1234_5678_9ABC),
%000001                 .order_ref(64'h0123_4567_89AB_CDEF),
%000001                 .buy_sell(8'h53),       // 'S'
%000001                 .shares(32'h0000_03E8),
%000001                 .stock(64'h474F_4F47_2020_2020),  // "GOOG    "
%000001                 .price(32'h0030_D40)
                    );
%000001             s.start(env.agent.sqr);
                endtask
            endclass
        
            // Drive a non-Add-Order message (msg_valid=1, but msg_type != 0x41)
            class test_non_add_order extends itch_base_test;
%000001         `uvm_component_utils(test_non_add_order)
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
%000001         task body_seq();
%000001             itch_drive_one_seq s;
                    // Use 'D' (Order Delete) and 'E' (Order Exec) — not 0x41
%000001             s = itch_drive_one_seq::type_id::create("s_delete");
%000001             s.rst = 0;
%000001             s.msg_valid = 1;
%000001             s.msg_data = itch_seq_item::pack_add_order(
%000001                 .msg_type(8'h44),  // 'D' delete
%000001                 .stock_locate(16'h1111),
%000001                 .tracking_number(16'h2222),
%000001                 .timestamp(48'hAA_BB_CC_DD_EE_FF),
%000001                 .order_ref(64'hAAAA_BBBB_CCCC_DDDD),
%000001                 .buy_sell(8'h42),
%000001                 .shares(32'h0000_0001),
%000001                 .stock(64'h0),
%000001                 .price(32'h0)
                    );
%000001             s.start(env.agent.sqr);
        
%000001             s = itch_drive_one_seq::type_id::create("s_exec");
%000001             s.rst = 0;
%000001             s.msg_valid = 1;
%000001             s.msg_data = itch_seq_item::pack_add_order(
%000001                 .msg_type(8'h45),  // 'E' execute
%000001                 .stock_locate(16'h3333),
%000001                 .tracking_number(16'h4444),
%000001                 .timestamp(48'd0),
%000001                 .order_ref(64'hFFEE_DDCC_BBAA_9988),
%000001                 .buy_sell(8'h53),
%000001                 .shares(32'h0000_00FF),
%000001                 .stock(64'h0),
%000001                 .price(32'h0)
                    );
%000001             s.start(env.agent.sqr);
                endtask
            endclass
        
            // Synchronous reset behaviour
            class test_reset extends itch_base_test;
%000001         `uvm_component_utils(test_reset)
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
%000001         task body_seq();
%000001             itch_drive_one_seq s;
%000001             itch_reset_seq     rseq;
                    // First drive a valid Add Order so outputs are non-zero
%000001             s = itch_drive_one_seq::type_id::create("s_pre");
%000001             s.rst = 0;
%000001             s.msg_valid = 1;
%000001             s.msg_data = itch_seq_item::pack_add_order(
%000001                 8'h41, 16'hAAAA, 16'hBBBB, 48'h1, 64'hFFFF_FFFF_FFFF_FFFF,
%000001                 8'h42, 32'h12345678,
%000001                 64'h4D53_4654_2020_2020,  // "MSFT    "
%000001                 32'h0099_9999
                    );
%000001             s.start(env.agent.sqr);
        
                    // Now apply reset for several cycles → outputs go to 0
%000001             rseq = itch_reset_seq::type_id::create("rseq_mid");
%000001             rseq.cycles = 5;
%000001             rseq.start(env.agent.sqr);
        
                    // Then drive valid again
%000001             s = itch_drive_one_seq::type_id::create("s_post");
%000001             s.rst = 0;
%000001             s.msg_valid = 1;
%000001             s.msg_data = itch_seq_item::pack_add_order(
%000001                 8'h41, 16'h0001, 16'h0002, 48'h3, 64'h0123_4567_89AB_CDEF,
%000001                 8'h53, 32'h00000064,
%000001                 64'h4942_4D20_2020_2020, // "IBM     "
%000001                 32'h0001_0000
                    );
%000001             s.start(env.agent.sqr);
                endtask
            endclass
        
            // Back-to-back valid messages with no idle cycles
            class test_back_to_back extends itch_base_test;
%000001         `uvm_component_utils(test_back_to_back)
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
%000001         task body_seq();
%000001             itch_drive_one_seq s;
                    // Five back-to-back valid Add Orders — alternate buy/sell, varied data
%000005             for (int i = 0; i < 5; i++) begin
%000005                 bit [7:0] bs;
%000005                 bs = (i[0]) ? 8'h53 : 8'h42;
%000005                 s = itch_drive_one_seq::type_id::create($sformatf("s_b2b_%0d", i));
%000005                 s.rst = 0;
%000005                 s.msg_valid = 1;
%000005                 s.msg_data = itch_seq_item::pack_add_order(
%000005                     .msg_type(8'h41),
%000005                     .stock_locate(16'h0010 + i[15:0]),
%000005                     .tracking_number(16'h0020 + i[15:0]),
%000005                     .timestamp(48'h1000 + i),
%000005                     .order_ref(64'hABCD_0000_0000_0000 | i),
%000005                     .buy_sell(bs),
%000005                     .shares(32'h0000_0010 + i),
%000005                     .stock(64'h5350_5920_2020_2020 + i),
%000005                     .price(32'h0001_0000 + i*32'h100)
                        );
%000005                 s.start(env.agent.sqr);
                    end
                endtask
            endclass
        
            // msg_valid deasserted while msg_data toggles → fields_valid stays 0
            class test_msg_valid_low extends itch_base_test;
%000001         `uvm_component_utils(test_msg_valid_low)
%000001         function new(string name, uvm_component parent);
%000001             super.new(name, parent);
                endfunction
%000001         task body_seq();
%000001             itch_drive_one_seq s;
                    // Drive msg_valid=0 with various data patterns, including one that
                    // would otherwise be a valid Add Order.
%000001             s = itch_drive_one_seq::type_id::create("s_inv0");
%000001             s.rst = 0;
%000001             s.msg_valid = 0;
%000001             s.msg_data = itch_seq_item::pack_add_order(
%000001                 8'h41, 16'h1, 16'h2, 48'h3, 64'h4,
%000001                 8'h42, 32'h5, 64'h6, 32'h7
                    );
%000001             s.start(env.agent.sqr);
        
%000001             s = itch_drive_one_seq::type_id::create("s_inv1");
%000001             s.rst = 0;
%000001             s.msg_valid = 0;
%000001             s.msg_data = '1;
%000001             s.start(env.agent.sqr);
        
%000001             s = itch_drive_one_seq::type_id::create("s_inv2");
%000001             s.rst = 0;
%000001             s.msg_valid = 0;
%000001             s.msg_data = itch_seq_item::pack_add_order(
%000001                 8'h44, 16'h0, 16'h0, 48'h0, 64'h0,
%000001                 8'h53, 32'h0, 64'h0, 32'h0
                    );
%000001             s.start(env.agent.sqr);
                endtask
            endclass
        
        endpackage
        
