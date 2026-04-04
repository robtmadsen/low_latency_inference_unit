// itch_field_extract.sv — Registered field slicer for ITCH 5.0 Add Order
//
// Extracts fields from an aligned message byte buffer and registers all
// outputs to close the timing path between msg_buf (itch_parser) and
// features_reg (feature_extractor). Adds exactly one pipeline stage.
// Only asserts fields_valid for Add Order messages (type 'A' = 0x41).
//
// ITCH Add Order layout (36 bytes):
//   [0]     message_type (1 byte)
//   [1:2]   stock_locate (2 bytes)
//   [3:4]   tracking_number (2 bytes)
//   [5:10]  timestamp (6 bytes)
//   [11:18] order_reference_number (8 bytes, big-endian)
//   [19]    buy_sell_indicator (1 byte, 'B' or 'S')
//   [20:23] shares (4 bytes)
//   [24:31] stock (8 bytes)
//   [32:35] price (4 bytes, big-endian)

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module itch_field_extract (
    input  logic        clk,
    input  logic        rst,

    // Packed message data: byte N = msg_data[(B-1-N)*8 +: 8], B = ITCH_ADD_ORDER_LEN
    input  logic [ITCH_ADD_ORDER_LEN*8-1:0] msg_data,
    input  logic       msg_valid,

    output logic [7:0]  message_type,
    output logic [63:0] order_ref,
    output logic        side,       // 1 = buy ('B'), 0 = sell ('S')
    output logic [31:0] price,
    output logic [63:0] stock,      // 8-byte ASCII ticker (bytes 24–31)
    output logic        fields_valid
);

    localparam int B = ITCH_ADD_ORDER_LEN; // 36

    // ----- Combinational decode -----
    logic [7:0]  message_type_comb;
    logic [63:0] order_ref_comb;
    logic        side_comb;
    logic [31:0] price_comb;
    logic [63:0] stock_comb;
    logic        fields_valid_comb;

    // Byte 0: message type
    assign message_type_comb = msg_data[(B-1)*8 +: 8];

    // Bytes 11–18: order reference number (8 bytes, big-endian)
    assign order_ref_comb = {
        msg_data[(B-1-11)*8 +: 8],
        msg_data[(B-1-12)*8 +: 8],
        msg_data[(B-1-13)*8 +: 8],
        msg_data[(B-1-14)*8 +: 8],
        msg_data[(B-1-15)*8 +: 8],
        msg_data[(B-1-16)*8 +: 8],
        msg_data[(B-1-17)*8 +: 8],
        msg_data[(B-1-18)*8 +: 8]
    };

    // Byte 19: buy/sell indicator ('B' = 0x42 → buy, anything else → sell)
    assign side_comb = (msg_data[(B-1-19)*8 +: 8] == 8'h42);

    // Bytes 32–35: price (4 bytes, big-endian)
    assign price_comb = {
        msg_data[(B-1-32)*8 +: 8],
        msg_data[(B-1-33)*8 +: 8],
        msg_data[(B-1-34)*8 +: 8],
        msg_data[(B-1-35)*8 +: 8]
    };

    // Bytes 24–31: stock symbol (8-byte ASCII, zero-padded right)
    assign stock_comb = {
        msg_data[(B-1-24)*8 +: 8],
        msg_data[(B-1-25)*8 +: 8],
        msg_data[(B-1-26)*8 +: 8],
        msg_data[(B-1-27)*8 +: 8],
        msg_data[(B-1-28)*8 +: 8],
        msg_data[(B-1-29)*8 +: 8],
        msg_data[(B-1-30)*8 +: 8],
        msg_data[(B-1-31)*8 +: 8]
    };

    // Only assert fields_valid for Add Order messages
    assign fields_valid_comb = msg_valid && (message_type_comb == ITCH_MSG_ADD_ORDER);

    // ----- Output register stage (closes timing across module boundary) -----
    always_ff @(posedge clk) begin
        if (rst) begin
            message_type <= 8'h00;
            order_ref    <= 64'd0;
            side         <= 1'b0;
            price        <= 32'd0;
            stock        <= 64'd0;
            fields_valid <= 1'b0;
        end else begin
            message_type <= message_type_comb;
            order_ref    <= order_ref_comb;
            side         <= side_comb;
            price        <= price_comb;
            stock        <= stock_comb;
            fields_valid <= fields_valid_comb;
        end
    end

    // Bytes 1–10 (timestamp/locate) and 20–23 (shares) are not used in the
    // current feature set; sink them to suppress Verilator UNUSEDSIGNAL.
    /* verilator lint_off UNUSED */
    logic _unused_msg_bytes;
    assign _unused_msg_bytes = |{msg_data[279:200], msg_data[127:96]};
    /* verilator lint_on UNUSED */

endmodule
