// syn/order_book_stub.sv — Black-box stub for OOC synthesis flow
//
// This file provides only the port declaration of order_book so that
// Vivado can elaborate lliu_top_v2 without synthesizing order_book inline.
// The real netlist is imported after synth_design via:
//   read_checkpoint -cell u_ob syn/order_book_ooc.dcp
//
// Port list must match rtl/order_book.sv exactly.

import lliu_pkg::*;

(* black_box *)
module order_book (
    input  logic        clk,
    input  logic        rst,
    input  logic [7:0]  msg_type,
    input  logic [63:0] order_ref,
    input  logic [63:0] new_order_ref,
    input  logic [31:0] price,
    input  logic [31:0] shares,
    input  logic        side,
    input  logic [8:0]  sym_id,
    input  logic        fields_valid,
    input  logic [8:0]  bbo_query_sym,
    output logic [31:0] bbo_bid_price,
    output logic [31:0] bbo_ask_price,
    output logic [23:0] bbo_bid_size,
    output logic [23:0] bbo_ask_size,
    output logic        bbo_valid,
    output logic [8:0]  bbo_sym_id,
    output logic [31:0] l2_bid_price [0:3],
    output logic [23:0] l2_bid_size  [0:3],
    output logic [31:0] l2_ask_price [0:3],
    output logic [23:0] l2_ask_size  [0:3],
    output logic [31:0] collision_count,
    output logic        collision_flag,
    output logic        book_ready
);
endmodule
