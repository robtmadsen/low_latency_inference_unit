// order_book_seq_item.sv — Sequence item for order_book agent
//
// Represents one ITCH message delivered to the order_book DUT.
// Supported message types (msg_type_e):
//   0x41 'A'  Add Order
//   0x44 'D'  Order Delete
//   0x58 'X'  Order Cancel
//   0x55 'U'  Order Replace
//   0x45 'E'  Order Executed
//
// Constraint weights are calibrated to a realistic ITCH message mix.

class order_book_seq_item extends uvm_sequence_item;
    `uvm_object_utils(order_book_seq_item)

    // -----------------------------------------------------------
    // Randomizable fields
    // -----------------------------------------------------------
    rand logic [7:0]  msg_type_e;
    rand logic [63:0] order_ref;
    rand logic [63:0] new_order_ref;   // used by Replace (0x55) only
    rand logic [31:0] price;
    rand logic [23:0] shares;
    rand logic        side;            // 1 = bid, 0 = ask
    rand logic [8:0]  sym_id;          // 0–499

    // -----------------------------------------------------------
    // Constraints
    // -----------------------------------------------------------
    constraint c_msg_type {
        msg_type_e dist {
            8'h41 := 50,   // Add
            8'h44 := 20,   // Delete
            8'h58 := 15,   // Cancel
            8'h55 := 10,   // Replace
            8'h45 := 5     // Execute
        };
    }

    constraint c_sym_id  { sym_id  inside {[0:499]}; }
    constraint c_price   { price   inside {[1:999_999]}; }
    constraint c_shares  { shares  inside {[1:10_000]}; }

    constraint c_new_order_ref { new_order_ref != order_ref; }

    // -----------------------------------------------------------
    function new(string name = "order_book_seq_item");
        super.new(name);
    endfunction

    function void do_copy(uvm_object rhs);
        order_book_seq_item item;
        super.do_copy(rhs);
        if (!$cast(item, rhs))
            `uvm_fatal("CAST", "Failed to cast rhs in order_book_seq_item::do_copy")
        msg_type_e    = item.msg_type_e;
        order_ref     = item.order_ref;
        new_order_ref = item.new_order_ref;
        price         = item.price;
        shares        = item.shares;
        side          = item.side;
        sym_id        = item.sym_id;
    endfunction

    function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        order_book_seq_item item;
        if (!$cast(item, rhs)) return 0;
        return (msg_type_e    === item.msg_type_e    &&
                order_ref     === item.order_ref     &&
                new_order_ref === item.new_order_ref &&
                price         === item.price         &&
                shares        === item.shares        &&
                side          === item.side          &&
                sym_id        === item.sym_id);
    endfunction

    function string convert2string();
        return $sformatf("OB_ITEM: msg=0x%02h ref=0x%016h new_ref=0x%016h price=%0d shares=%0d side=%0b sym_id=%0d",
            msg_type_e, order_ref, new_order_ref, price, shares, side, sym_id);
    endfunction
endclass
