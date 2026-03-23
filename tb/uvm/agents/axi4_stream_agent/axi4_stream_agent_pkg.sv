package axi4_stream_agent_pkg;

    `include "uvm_macros.svh"
    import uvm_pkg::*;
    import lliu_pkg::*;

    `include "agents/axi4_stream_agent/axi4_stream_transaction.sv"
    `include "agents/axi4_stream_agent/axi4_stream_sequencer.sv"
    `include "agents/axi4_stream_agent/axi4_stream_driver.sv"
    `include "agents/axi4_stream_agent/axi4_stream_monitor.sv"
    `include "agents/axi4_stream_agent/axi4_stream_agent.sv"

endpackage
