package lliu_test_pkg;

    `include "uvm_macros.svh"
    import uvm_pkg::*;
    import lliu_pkg::*;
    import axi4_stream_agent_pkg::*;
    import axi4_lite_agent_pkg::*;
    import lliu_env_pkg::*;
    import lliu_seq_pkg::*;

    `include "tests/lliu_base_test.sv"
    `include "tests/lliu_smoke_test.sv"
    `include "tests/lliu_replay_test.sv"
    `include "tests/lliu_random_test.sv"
    `include "tests/lliu_stress_test.sv"
    `include "tests/lliu_error_test.sv"
    `include "tests/lliu_coverage_test.sv"

endpackage
