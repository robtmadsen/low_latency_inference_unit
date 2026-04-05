// order_book_driver.sv — UVM driver for order_book DUT
//
// Protocol:
//   1. Wait for book_ready (DUT in S_IDLE).
//   2. Drive all ITCH message fields for one cycle with fields_valid=1.
//   3. Deassert fields_valid.
//   4. Poll until book_ready returns (DUT back to S_IDLE) before accepting
//      the next item — maximum 30 cycles to account for full FSM traversal:
//      S_IDLE → S_READ_REF1 → S_READ_REF2 → S_PROCESS → S_SCAN_BOOK
//      → S_UPDATE → S_DONE → S_IDLE = 7 cycles.

class order_book_driver extends uvm_driver #(order_book_seq_item);
    `uvm_component_utils(order_book_driver)

    virtual order_book_if vif;

    function new(string name = "order_book_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual order_book_if)::get(this, "", "ob_vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found for order_book_driver")
    endfunction

    task run_phase(uvm_phase phase);
        // Idle the stimulus signals immediately so the DUT reset is clean
        idle_bus();

        // Wait for reset deassertion (poll on clock edges — Verilator-safe)
        do @(posedge vif.clk); while (vif.rst);
        @(posedge vif.clk);

        forever begin
            order_book_seq_item req;
            seq_item_port.get_next_item(req);
            drive_item(req);
            seq_item_port.item_done();
        end
    endtask

    // ------------------------------------------------------------------
    // Idle all DUT input pins
    // ------------------------------------------------------------------
    task idle_bus();
        vif.msg_type     <= 8'h0;
        vif.order_ref    <= 64'h0;
        vif.new_order_ref <= 64'h0;
        vif.price        <= 32'h0;
        vif.shares       <= 32'h0;
        vif.side         <= 1'b0;
        vif.sym_id       <= 9'h0;
        vif.fields_valid <= 1'b0;
    endtask

    // ------------------------------------------------------------------
    // Drive a single ITCH message
    // ------------------------------------------------------------------
    task drive_item(order_book_seq_item req);
        // Advance to a posedge boundary
        @(posedge vif.clk);
        // Wait until DUT is idle (ready to accept a new message)
        while (!vif.book_ready) @(posedge vif.clk);

        `uvm_info("OB_DRV", req.convert2string(), UVM_HIGH)

        // Drive fields — takes effect at the NEXT posedge (NBA semantics)
        vif.msg_type      <= req.msg_type_e;
        vif.order_ref     <= req.order_ref;
        vif.new_order_ref <= req.new_order_ref;
        vif.price         <= req.price;
        vif.shares        <= {8'h0, req.shares};   // pack 24-bit into 32-bit port
        vif.side          <= req.side;
        vif.sym_id        <= req.sym_id;
        vif.fields_valid  <= 1'b1;

        // One cycle of fields_valid = 1
        @(posedge vif.clk);
        vif.fields_valid <= 1'b0;
        idle_bus();

        // Wait for the FSM to complete (return to S_IDLE) before next item.
        // Full worst-case path is 7 cycles; 30-cycle budget is generous.
        begin : wait_ready
            automatic int t;
            for (t = 0; t < 30; t++) begin
                @(posedge vif.clk);
                if (vif.book_ready || vif.bbo_valid) break;
            end
        end
    endtask
endclass
