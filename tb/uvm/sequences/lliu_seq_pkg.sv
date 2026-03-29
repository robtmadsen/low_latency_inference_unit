package lliu_seq_pkg;

    `include "uvm_macros.svh"
    import uvm_pkg::*;
    import lliu_pkg::*;
    import axi4_stream_agent_pkg::*;
    import axi4_lite_agent_pkg::*;

    `include "sequences/weight_load_seq.sv"
    `include "sequences/axil_rw_seq.sv"
    `include "sequences/itch_replay_seq.sv"
    `include "sequences/itch_random_seq.sv"
    `include "sequences/backpressure_seq.sv"
    `include "sequences/itch_error_seq.sv"
    `include "sequences/regmap_edge_seq.sv"
    `include "sequences/arith_edge_seq.sv"
    `include "sequences/itch_edge_seq.sv"

    // KC705 / kintex-7 sequences
    `include "sequences/moldupp64_seq.sv"
    `include "sequences/cam_load_seq.sv"

endpackage
