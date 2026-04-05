// order_book_agent.sv — UVM agent for order_book DUT
//
// Active mode: driver + sequencer + monitor
// Passive mode: monitor only
//
// Virtual interface key: "ob_vif" (virtual order_book_if)
// Set in tb_top.sv with:
//   uvm_config_db#(virtual order_book_if)::set(null, "uvm_test_top*", "ob_vif", ob_if);

class order_book_agent extends uvm_agent;
    `uvm_component_utils(order_book_agent)

    order_book_driver    m_driver;
    order_book_monitor   m_monitor;
    uvm_sequencer #(order_book_seq_item) m_sequencer;

    function new(string name = "order_book_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Monitor is always present
        m_monitor = order_book_monitor::type_id::create("m_monitor", this);

        if (get_is_active() == UVM_ACTIVE) begin
            m_driver     = order_book_driver::type_id::create("m_driver", this);
            m_sequencer  = uvm_sequencer #(order_book_seq_item)::type_id::create(
                               "m_sequencer", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            m_driver.seq_item_port.connect(m_sequencer.seq_item_export);
    endfunction
endclass
