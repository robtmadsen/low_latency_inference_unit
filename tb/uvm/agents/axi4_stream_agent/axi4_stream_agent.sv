// axi4_stream_agent.sv — AXI4-Stream UVM agent
//
// Active mode: driver + sequencer + monitor
// Passive mode: monitor only

class axi4_stream_agent extends uvm_agent;
    `uvm_component_utils(axi4_stream_agent)

    axi4_stream_driver    m_driver;
    axi4_stream_monitor   m_monitor;
    axi4_stream_sequencer m_sequencer;

    function new(string name = "axi4_stream_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        // Monitor is always instantiated
        m_monitor = axi4_stream_monitor::type_id::create("m_monitor", this);

        // Driver and sequencer only in active mode
        if (get_is_active() == UVM_ACTIVE) begin
            m_driver    = axi4_stream_driver::type_id::create("m_driver", this);
            m_sequencer = axi4_stream_sequencer::type_id::create("m_sequencer", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (get_is_active() == UVM_ACTIVE)
            m_driver.seq_item_port.connect(m_sequencer.seq_item_export);
    endfunction
endclass
