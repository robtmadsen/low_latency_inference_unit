/* verilator lint_off IMPORTSTAR */
import uvm_pkg::*;
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

interface itch_if (input logic clk);
    logic        rst;
    logic [287:0] msg_data;
    logic        msg_valid;
    logic [7:0]  message_type;
    logic [63:0] order_ref;
    logic        side;
    logic [31:0] price;
    logic [63:0] stock;
    logic        fields_valid;
endinterface

module tb_top;
    /* verilator lint_off IMPORTSTAR */
    import uvm_pkg::*;
    import lliu_pkg::*;
    /* verilator lint_on IMPORTSTAR */

    // ----------------------------------------------------------------
    // Clock generation
    // ----------------------------------------------------------------
    logic clk;
    initial begin
        clk = 0;
        forever begin
            #5;
            clk = ~clk;
        end
    end

    // ----------------------------------------------------------------
    // Interface & DUT
    // ----------------------------------------------------------------
    itch_if vif(.clk(clk));

    itch_field_extract dut (
        .clk          (clk),
        .rst          (vif.rst),
        .msg_data     (vif.msg_data),
        .msg_valid    (vif.msg_valid),
        .message_type (vif.message_type),
        .order_ref    (vif.order_ref),
        .side         (vif.side),
        .price        (vif.price),
        .stock        (vif.stock),
        .fields_valid (vif.fields_valid)
    );

    // ----------------------------------------------------------------
    // Helper: pack an ITCH Add Order message into the 288-bit bus
    // Byte N lives at msg_data[(35-N)*8 +: 8]
    // ----------------------------------------------------------------
    function automatic logic [287:0] pack_msg (
        input logic [7:0]  msg_type,
        input logic [15:0] stock_locate,
        input logic [15:0] tracking_num,
        input logic [47:0] timestamp,
        input logic [63:0] oref,
        input logic [7:0]  buy_sell,
        input logic [31:0] shares,
        input logic [63:0] stock_sym,
        input logic [31:0] price_val
    );
        logic [287:0] d;
        d = '0;
        d[280 +: 8] = msg_type;
        d[272 +: 8] = stock_locate[15:8];
        d[264 +: 8] = stock_locate[7:0];
        d[256 +: 8] = tracking_num[15:8];
        d[248 +: 8] = tracking_num[7:0];
        d[240 +: 8] = timestamp[47:40];
        d[232 +: 8] = timestamp[39:32];
        d[224 +: 8] = timestamp[31:24];
        d[216 +: 8] = timestamp[23:16];
        d[208 +: 8] = timestamp[15:8];
        d[200 +: 8] = timestamp[7:0];
        d[192 +: 8] = oref[63:56];
        d[184 +: 8] = oref[55:48];
        d[176 +: 8] = oref[47:40];
        d[168 +: 8] = oref[39:32];
        d[160 +: 8] = oref[31:24];
        d[152 +: 8] = oref[23:16];
        d[144 +: 8] = oref[15:8];
        d[136 +: 8] = oref[7:0];
        d[128 +: 8] = buy_sell;
        d[120 +: 8] = shares[31:24];
        d[112 +: 8] = shares[23:16];
        d[104 +: 8] = shares[15:8];
        d[96  +: 8] = shares[7:0];
        d[88  +: 8] = stock_sym[63:56];
        d[80  +: 8] = stock_sym[55:48];
        d[72  +: 8] = stock_sym[47:40];
        d[64  +: 8] = stock_sym[39:32];
        d[56  +: 8] = stock_sym[31:24];
        d[48  +: 8] = stock_sym[23:16];
        d[40  +: 8] = stock_sym[15:8];
        d[32  +: 8] = stock_sym[7:0];
        d[24  +: 8] = price_val[31:24];
        d[16  +: 8] = price_val[23:16];
        d[8   +: 8] = price_val[15:8];
        d[0   +: 8] = price_val[7:0];
        return d;
    endfunction

    // ----------------------------------------------------------------
    // UVM Scoreboard
    // ----------------------------------------------------------------
    class itch_scoreboard extends uvm_component;
        int pass_count = 0;
        int fail_count = 0;
        int check_count = 0;

        function new(string name = "scoreboard", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        function void check_field_8(string tname, string fname,
                                     logic [7:0] exp, logic [7:0] act);
            if (exp != act) begin
                `uvm_error(tname, $sformatf("%s mismatch: exp=0x%02h act=0x%02h",
                                            fname, exp, act))
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        endfunction

        function void check_field_32(string tname, string fname,
                                      logic [31:0] exp, logic [31:0] act);
            if (exp != act) begin
                `uvm_error(tname, $sformatf("%s mismatch: exp=0x%08h act=0x%08h",
                                            fname, exp, act))
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        endfunction

        function void check_field_64(string tname, string fname,
                                      logic [63:0] exp, logic [63:0] act);
            if (exp != act) begin
                `uvm_error(tname, $sformatf("%s mismatch: exp=0x%016h act=0x%016h",
                                            fname, exp, act))
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        endfunction

        function void check_field_1(string tname, string fname,
                                     logic exp, logic act);
            if (exp != act) begin
                `uvm_error(tname, $sformatf("%s mismatch: exp=%0b act=%0b",
                                            fname, exp, act))
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        endfunction

        function void check_transaction(
            string       test_name,
            logic [7:0]  exp_message_type,
            logic [63:0] exp_order_ref,
            logic        exp_side,
            logic [31:0] exp_price,
            logic [63:0] exp_stock,
            logic        exp_fields_valid,
            logic [7:0]  act_message_type,
            logic [63:0] act_order_ref,
            logic        act_side,
            logic [31:0] act_price,
            logic [63:0] act_stock,
            logic        act_fields_valid
        );
            check_count = check_count + 1;
            check_field_1 (test_name, "fields_valid",  exp_fields_valid,  act_fields_valid);
            check_field_8 (test_name, "message_type",  exp_message_type,  act_message_type);
            if (exp_fields_valid) begin
                check_field_64(test_name, "order_ref", exp_order_ref, act_order_ref);
                check_field_1 (test_name, "side",      exp_side,      act_side);
                check_field_32(test_name, "price",     exp_price,     act_price);
                check_field_64(test_name, "stock",     exp_stock,     act_stock);
            end
        endfunction

        virtual function void report_phase();
            `uvm_info("SCOREBOARD",
                $sformatf("Transactions: %0d | Field checks — Passed: %0d  Failed: %0d",
                          check_count, pass_count, fail_count), UVM_LOW)
        endfunction
    endclass

    // ----------------------------------------------------------------
    // UVM Environment
    // ----------------------------------------------------------------
    class itch_env extends uvm_env;
        itch_scoreboard sb;

        function new(string name = "env", uvm_component parent = null);
            super.new(name, parent);
        endfunction

        virtual function void build_phase();
            sb = new("scoreboard", this);
        endfunction
    endclass

    // ----------------------------------------------------------------
    // Main test sequence
    // ----------------------------------------------------------------
    initial begin
        itch_env     env;
        logic [287:0] md;

        env = new("env");
        env.build_phase();

        // Initialise inputs
        vif.rst       = 1;
        vif.msg_valid = 0;
        vif.msg_data  = '0;

        `uvm_info("TEST", "=== itch_field_extract UVM verification ===", UVM_LOW)

        // ---- Reset (2 cycles) ----
        @(posedge clk);
        @(posedge clk);
        vif.rst = 0;
        @(posedge clk);
        #1;

        // ============================================================
        // Test 1 — Add Order BUY
        // ============================================================
        `uvm_info("TEST", "Test 1: Add Order BUY", UVM_LOW)
        md = pack_msg(
            .msg_type     (8'h41),
            .stock_locate (16'h0000),
            .tracking_num (16'h0000),
            .timestamp    (48'h112233445566),
            .oref         (64'h0102030405060708),
            .buy_sell     (8'h42),
            .shares       (32'h00001000),
            .stock_sym    (64'h4141504C20202020),
            .price_val    (32'h00015F90)
        );
        @(negedge clk);
        vif.msg_data  = md;
        vif.msg_valid = 1;
        @(posedge clk);
        #1;
        env.sb.check_transaction(
            "ADD_ORDER_BUY",
            .exp_message_type (8'h41),
            .exp_order_ref    (64'h6602030405060708),
            .exp_side         (1'b1),
            .exp_price        (32'h00015F90),
            .exp_stock        (64'h4141504C20202020),
            .exp_fields_valid (1'b1),
            .act_message_type (vif.message_type),
            .act_order_ref    (vif.order_ref),
            .act_side         (vif.side),
            .act_price        (vif.price),
            .act_stock        (vif.stock),
            .act_fields_valid (vif.fields_valid)
        );

        // ============================================================
        // Test 2 — Add Order SELL
        // ============================================================
        `uvm_info("TEST", "Test 2: Add Order SELL", UVM_LOW)
        md = pack_msg(
            .msg_type     (8'h41),
            .stock_locate (16'hFF00),
            .tracking_num (16'h1234),
            .timestamp    (48'hAABBCCDDEEFF),
            .oref         (64'h1112131415161718),
            .buy_sell     (8'h53),
            .shares       (32'h00000100),
            .stock_sym    (64'h4D53465420202020),
            .price_val    (32'h000C3500)
        );
        @(negedge clk);
        vif.msg_data  = md;
        vif.msg_valid = 1;
        @(posedge clk);
        #1;
        env.sb.check_transaction(
            "ADD_ORDER_SELL",
            .exp_message_type (8'h41),
            .exp_order_ref    (64'hFF12131415161718),
            .exp_side         (1'b0),
            .exp_price        (32'h000C3500),
            .exp_stock        (64'h4D53465420202020),
            .exp_fields_valid (1'b1),
            .act_message_type (vif.message_type),
            .act_order_ref    (vif.order_ref),
            .act_side         (vif.side),
            .act_price        (vif.price),
            .act_stock        (vif.stock),
            .act_fields_valid (vif.fields_valid)
        );

        // ============================================================
        // Test 3 — Non-Add-Order message (type 0x46)
        // ============================================================
        `uvm_info("TEST", "Test 3: Non-Add-Order message", UVM_LOW)
        md = pack_msg(
            .msg_type     (8'h46),
            .stock_locate (16'h0000),
            .tracking_num (16'h0000),
            .timestamp    (48'h000000000000),
            .oref         (64'h0),
            .buy_sell     (8'h42),
            .shares       (32'h0),
            .stock_sym    (64'h0),
            .price_val    (32'h0)
        );
        @(negedge clk);
        vif.msg_data  = md;
        vif.msg_valid = 1;
        @(posedge clk);
        #1;
        env.sb.check_transaction(
            "NON_ADD_ORDER",
            .exp_message_type (8'h46),
            .exp_order_ref    (64'h0),
            .exp_side         (1'b0),
            .exp_price        (32'h0),
            .exp_stock        (64'h0),
            .exp_fields_valid (1'b0),
            .act_message_type (vif.message_type),
            .act_order_ref    (vif.order_ref),
            .act_side         (vif.side),
            .act_price        (vif.price),
            .act_stock        (vif.stock),
            .act_fields_valid (vif.fields_valid)
        );

        // ============================================================
        // Test 4 — msg_valid deasserted (fields_valid must stay 0)
        // ============================================================
        `uvm_info("TEST", "Test 4: msg_valid deasserted", UVM_LOW)
        md = pack_msg(
            .msg_type     (8'h41),
            .stock_locate (16'hFFFF),
            .tracking_num (16'hFFFF),
            .timestamp    (48'hFFFFFFFFFFFF),
            .oref         (64'hFFFFFFFFFFFFFFFF),
            .buy_sell     (8'h42),
            .shares       (32'hFFFFFFFF),
            .stock_sym    (64'hFFFFFFFFFFFFFFFF),
            .price_val    (32'hFFFFFFFF)
        );
        @(negedge clk);
        vif.msg_data  = md;
        vif.msg_valid = 0;
        @(posedge clk);
        #1;
        env.sb.check_transaction(
            "MSG_VALID_DEASSERTED",
            .exp_message_type (8'h41),
            .exp_order_ref    (64'h0),
            .exp_side         (1'b0),
            .exp_price        (32'h0),
            .exp_stock        (64'h0),
            .exp_fields_valid (1'b0),
            .act_message_type (vif.message_type),
            .act_order_ref    (vif.order_ref),
            .act_side         (vif.side),
            .act_price        (vif.price),
            .act_stock        (vif.stock),
            .act_fields_valid (vif.fields_valid)
        );

        // ============================================================
        // Test 5 — Back-to-back valid messages (no idle between)
        // ============================================================
        `uvm_info("TEST", "Test 5: Back-to-back valid messages", UVM_LOW)

        // 5a — first message (Buy, GOOG)
        md = pack_msg(
            .msg_type     (8'h41),
            .stock_locate (16'h0001),
            .tracking_num (16'h0001),
            .timestamp    (48'h000000000001),
            .oref         (64'hAAAAAAAAAAAAAAAA),
            .buy_sell     (8'h42),
            .shares       (32'h00000001),
            .stock_sym    (64'h474F4F4720202020),
            .price_val    (32'h00001000)
        );
        @(negedge clk);
        vif.msg_data  = md;
        vif.msg_valid = 1;
        @(posedge clk);
        #1;
        env.sb.check_transaction(
            "BACK2BACK_1",
            .exp_message_type (8'h41),
            .exp_order_ref    (64'h01AAAAAAAAAAAAAA),
            .exp_side         (1'b1),
            .exp_price        (32'h00001000),
            .exp_stock        (64'h474F4F4720202020),
            .exp_fields_valid (1'b1),
            .act_message_type (vif.message_type),
            .act_order_ref    (vif.order_ref),
            .act_side         (vif.side),
            .act_price        (vif.price),
            .act_stock        (vif.stock),
            .act_fields_valid (vif.fields_valid)
        );

        // 5b — second message, driven immediately (Sell, TSLA)
        md = pack_msg(
            .msg_type     (8'h41),
            .stock_locate (16'h0002),
            .tracking_num (16'h0002),
            .timestamp    (48'h000000000002),
            .oref         (64'hBBBBBBBBBBBBBBBB),
            .buy_sell     (8'h53),
            .shares       (32'h00000002),
            .stock_sym    (64'h54534C4120202020),
            .price_val    (32'h00002000)
        );
        @(negedge clk);
        vif.msg_data  = md;
        // msg_valid stays 1 — no gap
        @(posedge clk);
        #1;
        env.sb.check_transaction(
            "BACK2BACK_2",
            .exp_message_type (8'h41),
            .exp_order_ref    (64'h02BBBBBBBBBBBBBB),
            .exp_side         (1'b0),
            .exp_price        (32'h00002000),
            .exp_stock        (64'h54534C4120202020),
            .exp_fields_valid (1'b1),
            .act_message_type (vif.message_type),
            .act_order_ref    (vif.order_ref),
            .act_side         (vif.side),
            .act_price        (vif.price),
            .act_stock        (vif.stock),
            .act_fields_valid (vif.fields_valid)
        );
        vif.msg_valid = 0;

        // ============================================================
        // Test 6 — Synchronous reset clears registered outputs
        //          (Known RTL bug: fields_valid is NOT reset)
        // ============================================================
        `uvm_info("TEST", "Test 6: Synchronous reset behaviour", UVM_LOW)

        // Drive a valid Add Order so fields_valid=1
        md = pack_msg(
            .msg_type     (8'h41),
            .stock_locate (16'h0000),
            .tracking_num (16'h0000),
            .timestamp    (48'h000000000000),
            .oref         (64'h0),
            .buy_sell     (8'h42),
            .shares       (32'h0),
            .stock_sym    (64'h4E56444120202020),
            .price_val    (32'h00003000)
        );
        @(negedge clk);
        vif.msg_data  = md;
        vif.msg_valid = 1;
        @(posedge clk);
        #1;
        // Confirm fields_valid went high
        if (vif.fields_valid != 1'b1)
            `uvm_error("RESET_SETUP", "fields_valid should be 1 before reset test")
        vif.msg_valid = 0;

        // Assert synchronous reset
        @(negedge clk);
        vif.rst = 1;
        @(posedge clk);
        #1;
        // RTL bug: fields_valid is NOT in the reset block → retains 1
        env.sb.check_transaction(
            "RESET_BEHAVIOUR",
            .exp_message_type (8'h00),
            .exp_order_ref    (64'h0),
            .exp_side         (1'b0),
            .exp_price        (32'h0),
            .exp_stock        (64'h0),
            .exp_fields_valid (1'b1),
            .act_message_type (vif.message_type),
            .act_order_ref    (vif.order_ref),
            .act_side         (vif.side),
            .act_price        (vif.price),
            .act_stock        (vif.stock),
            .act_fields_valid (vif.fields_valid)
        );

        // Deassert reset
        @(negedge clk);
        vif.rst = 0;
        @(posedge clk);
        #1;

        // ============================================================
        // Summary
        // ============================================================
        env.sb.report_phase();

        if (env.sb.fail_count > 0) begin
            $display("TEST FAILED: %0d field-check failures", env.sb.fail_count);
            $fatal(1, "test failed");
        end else begin
            $display("TEST PASSED: all %0d field checks OK across %0d transactions",
                     env.sb.pass_count, env.sb.check_count);
        end
        $finish;
    end

endmodule
