// order_book_stress_seq.sv — Fuzz driver for order_book
//
// Phase 1 fuzz strategy: randomize price/qty across rule boundaries.
// "Rule boundaries" for order_book:
//   - Price: near 0, mid-range, near-max
//   - Qty: 1, large (>9000), near-max (2^24-1)
//   - sym_id: edge values (0, 1, 498, 499) and random interior
//   - BBO interaction: multiple orders at same price level
//   - Mix of Add/Delete/Cancel/Replace/Execute in ratio 50/20/15/10/5
//
// The sequence tracks active order references in a queue so that
// Delete/Cancel/Replace/Execute ops target orders that actually exist.

class order_book_stress_seq extends uvm_sequence #(order_book_seq_item);
    `uvm_object_utils(order_book_stress_seq)

    rand int unsigned num_ops;
    constraint c_num_ops { num_ops inside {[500:2000]}; }

    // Track active order refs for modify-op targeting
    longint unsigned active_refs[$];
    longint unsigned m_next_ref;

    function new(string name = "order_book_stress_seq");
        super.new(name);
        num_ops    = 1000;
        m_next_ref = 64'h1000_0000;
    endfunction

    task body();
        order_book_seq_item item;
        `uvm_info("OB_STRESS", $sformatf("Starting %0d fuzz ops", num_ops), UVM_LOW)

        for (int i = 0; i < num_ops; i++) begin
            item = order_book_seq_item::type_id::create($sformatf("op_%0d", i));

            if (active_refs.size() == 0 || ($urandom() % 100) < 50) begin
                // ---- Add Order (50% baseline or when queue is empty) --------
                // Randomize using $urandom to keep Verilator-5.x compatible
                item.msg_type_e   = 8'h41;
                item.order_ref    = m_next_ref++;
                item.price        = 32'(1 + ($urandom() % 999_999));
                item.shares       = 24'(1 + ($urandom() % 10_000));
                item.side         = logic'($urandom_range(0, 1));
                item.sym_id       = 9'($urandom() % 500);
                item.new_order_ref = item.order_ref + 64'h1; // unused for Add

                active_refs.push_back(item.order_ref);

                // Boundary fuzz every ~50 ops
                if ((i % 50) == 0)  item.price  = 32'h1;                 // min price
                if ((i % 51) == 0)  item.price  = 32'hFFFF_FF00;          // near-max
                if ((i % 52) == 0)  item.shares = 24'h1;                  // min shares
                if ((i % 53) == 0)  item.shares = 24'hFF_FF00;            // near-max shares
                // Edge sym_ids
                if ((i % 40) == 0)  item.sym_id = 9'd0;
                if ((i % 41) == 0)  item.sym_id = 9'd499;
                if ((i % 43) == 0)  item.sym_id = 9'd1;
                if ((i % 47) == 0)  item.sym_id = 9'd498;

            end else begin
                // ---- Modify op on an existing order -------------------------
                automatic int pick;
                automatic int r;
                pick = int'($urandom() % active_refs.size());
                item.order_ref = active_refs[pick];
                r = int'($urandom() % 100);

                if (r < 40) begin
                    // Delete
                    item.msg_type_e   = 8'h44;
                    item.sym_id       = 9'(pick % 500);
                    item.price        = 32'h0;  // unused for delete
                    item.shares       = 24'h0;
                    item.side         = 1'b0;
                    active_refs.delete(pick);
                end else if (r < 65) begin
                    // Cancel (partial share reduction)
                    item.msg_type_e = 8'h58;
                    item.sym_id     = 9'(pick % 500);
                    item.price      = 32'h0;  // unused for cancel
                    item.shares     = 24'(1 + ($urandom() % 1_000));
                    item.side       = 1'b0;
                end else if (r < 80) begin
                    // Replace — atomically deletes old ref, inserts new
                    item.msg_type_e   = 8'h55;
                    item.new_order_ref = m_next_ref++;
                    item.price        = 32'(1 + ($urandom() % 999_999));
                    item.shares       = 24'(1 + ($urandom() % 10_000));
                    item.side         = logic'($urandom_range(0, 1));
                    item.sym_id       = 9'($urandom() % 500);
                    active_refs.delete(pick);
                    active_refs.push_back(item.new_order_ref);
                end else begin
                    // Execute (partial or full)
                    item.msg_type_e = 8'h45;
                    item.sym_id     = 9'(pick % 500);
                    item.shares     = 24'(1 + ($urandom() % 1_000));
                    item.price      = 32'h0;  // unused for execute
                    item.side       = 1'b0;
                end
            end

            `uvm_info("OB_STRESS", $sformatf("op[%0d] %s", i, item.convert2string()),
                      UVM_HIGH)
            start_item(item);
            finish_item(item);
        end

        `uvm_info("OB_STRESS",
            $sformatf("Completed %0d fuzz ops, %0d refs still active",
                      num_ops, active_refs.size()), UVM_LOW)
    endtask
endclass
