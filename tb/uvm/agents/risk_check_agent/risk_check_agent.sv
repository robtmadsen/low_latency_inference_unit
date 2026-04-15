// risk_check_agent.sv — Standard UVM agent for risk_check standalone DUT
//
// Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.6
//
// Active mode (UVM_ACTIVE, default):  driver + sequencer + monitor
// Passive mode (UVM_PASSIVE):         monitor only
//
// The agent exposes the monitor's analysis port via m_monitor.ap so that
// an enclosing environment can connect a scoreboard if needed.

class risk_check_agent extends uvm_agent;
    `uvm_component_utils(risk_check_agent)

    uvm_sequencer #(risk_check_seq_item) m_sequencer;
    risk_check_driver                    m_driver;
    risk_check_monitor                   m_monitor;

    function new(string name = "risk_check_agent", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_monitor = risk_check_monitor::type_id::create("m_monitor", this);
        if (get_is_active() == UVM_ACTIVE) begin
            m_sequencer =
                uvm_sequencer #(risk_check_seq_item)::type_id::create(
                    "m_sequencer", this);
            m_driver = risk_check_driver::type_id::create("m_driver", this);
        end
    endfunction

    function void connect_phase(uvm_phase phase);
        if (get_is_active() == UVM_ACTIVE)
            m_driver.seq_item_port.connect(m_sequencer.seq_item_export);
    endfunction

endclass
