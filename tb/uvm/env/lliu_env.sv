// lliu_env.sv — Top-level UVM environment for Low-Latency Inference Unit
//
// Contains: AXI4-Stream agent, AXI4-Lite agent, predictor, scoreboard

class lliu_env extends uvm_env;
    `uvm_component_utils(lliu_env)

    // Agents
    axi4_stream_agent  m_axis_agent;
    axi4_lite_agent    m_axil_agent;

    // Checking
    lliu_predictor     m_predictor;
    lliu_scoreboard    m_scoreboard;

    function new(string name = "lliu_env", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_axis_agent = axi4_stream_agent::type_id::create("m_axis_agent", this);
        m_axil_agent = axi4_lite_agent::type_id::create("m_axil_agent", this);
        m_predictor  = lliu_predictor::type_id::create("m_predictor", this);
        m_scoreboard = lliu_scoreboard::type_id::create("m_scoreboard", this);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        // Stream monitor → predictor (to compute expected inference result)
        m_axis_agent.m_monitor.ap.connect(m_predictor.analysis_export);
        // Predictor → scoreboard expected port
        m_predictor.result_ap.connect(m_scoreboard.expected_export);
        // AXI-Lite monitor → scoreboard actual port (result reads)
        m_axil_agent.m_monitor.ap.connect(m_scoreboard.actual_export);
    endfunction
endclass
