// axi4_lite_agent.sv — AXI4-Lite UVM agent
//
// Active mode: driver + sequencer + monitor
// Passive mode: monitor only

class axi4_lite_agent extends uvm_agent;
    `uvm_component_utils(axi4_lite_agent)

    axi4_lite_driver    m_driver;
    axi4_lite_monitor   m_monitor;
    axi4_lite_sequencer m_sequencer;

    function new(string name = "axi4_lite_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        m_monitor = axi4_lite_monitor::type_id::create("m_monitor", this);

        if (get_is_active() == UVM_ACTIVE) begin
            m_driver    = axi4_lite_driver::type_id::create("m_driver", this);
            m_sequencer = axi4_lite_sequencer::type_id::create("m_sequencer", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            m_driver.seq_item_port.connect(m_sequencer.seq_item_export);
    endfunction
endclass
