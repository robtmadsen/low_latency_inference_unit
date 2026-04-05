// order_book_monitor.sv — UVM monitor for order_book DUT
//
// Passively observes BBO update pulses (bbo_valid) and samples the
// resulting BBO state by driving bbo_query_sym = bbo_sym_id then
// waiting one clock for the registered output to settle.
//
// Each captured BBO snapshot is written to the analysis port as an
// order_book_seq_item with:
//   sym_id  = bbo_sym_id (symbol that was updated)
//   price   = bbo_bid_price  (reused field)
//   shares  = bbo_ask_price[23:0]  (reused field — ask price low 24 bits)
//   side    = 0 (not meaningful for BBO snapshots)
//
// Also monitors collision_flag and logs each collision event.

class order_book_monitor extends uvm_monitor;
    `uvm_component_utils(order_book_monitor)

    virtual order_book_if vif;
    uvm_analysis_port #(order_book_seq_item) ap;

    function new(string name = "order_book_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual order_book_if)::get(this, "", "ob_vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found for order_book_monitor")
    endfunction

    task run_phase(uvm_phase phase);
        // Wait for reset deassertion (Verilator-safe: poll on clock edges)
        do @(posedge vif.clk); while (vif.rst);

        forever begin
            @(posedge vif.clk);
            if (vif.bbo_valid)
                capture_bbo();
            if (vif.collision_flag)
                `uvm_info("OB_MON",
                    $sformatf("COLLISION detected — count=%0d",
                              vif.collision_count), UVM_LOW)
        end
    endtask

    // ------------------------------------------------------------------
    // Sample BBO registers for the symbol that just updated
    // ------------------------------------------------------------------
    task capture_bbo();
        order_book_seq_item item;
        logic [8:0]  sym;

        sym = vif.bbo_sym_id;

        // Drive the query; the DUT registered output settles one cycle later
        vif.bbo_query_sym <= sym;
        @(posedge vif.clk);

        item = order_book_seq_item::type_id::create("mon_item");
        item.sym_id  = sym;
        item.price   = vif.bbo_bid_price;        // reuse price field for bid
        item.shares  = vif.bbo_ask_price[23:0];  // reuse shares field for ask (low 24b)
        item.side    = 1'b0;                      // not meaningful for BBO snapshots

        `uvm_info("OB_MON",
            $sformatf("BBO update sym=%0d bid_price=%0d ask_price=%0d bid_size=%0d ask_size=%0d",
                      sym, vif.bbo_bid_price, vif.bbo_ask_price,
                      vif.bbo_bid_size, vif.bbo_ask_size), UVM_MEDIUM)
        ap.write(item);
    endtask
endclass
