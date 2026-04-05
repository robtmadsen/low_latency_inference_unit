// order_book_if.sv — SystemVerilog interface for order_book DUT
//
// Stimulus inputs (driven by UVM driver):
//   msg_type, order_ref, new_order_ref, price, shares, side,
//   sym_id, fields_valid
//
// Query input (driven by UVM monitor after bbo_valid):
//   bbo_query_sym
//
// Observation outputs (sampled by UVM monitor):
//   bbo_bid_price, bbo_ask_price, bbo_bid_size, bbo_ask_size,
//   bbo_valid, bbo_sym_id, collision_count, collision_flag, book_ready

interface order_book_if (input logic clk, input logic rst);
    // -----------------------------------------------------------
    // Stimulus to DUT (driver → DUT)
    // -----------------------------------------------------------
    logic [7:0]  msg_type;
    logic [63:0] order_ref;
    logic [63:0] new_order_ref;
    logic [31:0] price;
    logic [31:0] shares;      // [31:24] reserved; only [23:0] used by DUT
    logic        side;
    logic [8:0]  sym_id;
    logic        fields_valid;

    // -----------------------------------------------------------
    // BBO combinatorial query (monitor → DUT, 1-cycle FF latency)
    // -----------------------------------------------------------
    logic [8:0]  bbo_query_sym;

    // -----------------------------------------------------------
    // DUT outputs (sampled by monitor)
    // -----------------------------------------------------------
    logic [31:0] bbo_bid_price;
    logic [31:0] bbo_ask_price;
    logic [23:0] bbo_bid_size;
    logic [23:0] bbo_ask_size;
    logic        bbo_valid;
    logic [8:0]  bbo_sym_id;
    logic [31:0] collision_count;
    logic        collision_flag;
    logic        book_ready;
endinterface
