package lliu_env_pkg;

    `include "uvm_macros.svh"
    import uvm_pkg::*;
    import lliu_pkg::*;
    import axi4_stream_agent_pkg::*;
    import axi4_lite_agent_pkg::*;

    `include "env/lliu_predictor.sv"
    `include "env/lliu_scoreboard.sv"
    `include "env/lliu_coverage.sv"
    `include "env/lliu_env.sv"

endpackage
