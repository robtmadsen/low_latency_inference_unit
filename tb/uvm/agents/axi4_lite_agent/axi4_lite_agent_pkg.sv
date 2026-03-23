package axi4_lite_agent_pkg;

    `include "uvm_macros.svh"
    import uvm_pkg::*;
    import lliu_pkg::*;

    `include "agents/axi4_lite_agent/axi4_lite_transaction.sv"
    `include "agents/axi4_lite_agent/axi4_lite_sequencer.sv"
    `include "agents/axi4_lite_agent/axi4_lite_driver.sv"
    `include "agents/axi4_lite_agent/axi4_lite_monitor.sv"
    `include "agents/axi4_lite_agent/axi4_lite_agent.sv"

endpackage
