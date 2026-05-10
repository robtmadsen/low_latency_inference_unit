//      // verilator_coverage annotation
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
 000071     input  logic        clk,
%000008     input  logic        rst,
        
            // Packed message data: byte N = msg_data[(B-1-N)*8 +: 8], B = ITCH_ADD_ORDER_LEN
            input  logic [ITCH_ADD_ORDER_LEN*8-1:0] msg_data,
%000006     input  logic       msg_valid,
        
%000007     output logic [7:0]  message_type,
%000007     output logic [63:0] order_ref,
%000005     output logic        side,       // 1 = buy ('B'), 0 = sell ('S')
%000008     output logic [31:0] price,
%000009     output logic [63:0] stock,      // 8-byte ASCII ticker (bytes 24–31)
%000004     output logic        fields_valid
        );
        
            localparam int B = ITCH_ADD_ORDER_LEN; // 36
        
            // ----- Combinational decode -----
%000007     logic [7:0]  message_type_comb;
%000007     logic [63:0] order_ref_comb;
%000005     logic        side_comb;
%000008     logic [31:0] price_comb;
%000009     logic [63:0] stock_comb;
%000004     logic        fields_valid_comb;
        
            // Byte 0: message type
            assign message_type_comb = msg_data[(B-1)*8 +: 8];
        
            // Bytes 11–18: order reference number (8 bytes, big-endian)
            assign order_ref_comb = {
                msg_data[(B-1-10)*8 +: 8],
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
 000071     always_ff @(posedge clk) begin
 000048         if (rst) begin
 000023             message_type <= 8'h00;
 000023             order_ref    <= 64'd0;
 000023             side         <= 1'b0;
 000023             price        <= 32'd0;
 000023             stock        <= 64'd0;
 000048         end else begin
 000048             message_type <= message_type_comb;
 000048             order_ref    <= order_ref_comb;
 000048             side         <= side_comb;
 000048             price        <= price_comb;
 000048             stock        <= stock_comb;
 000048             fields_valid <= fields_valid_comb;
                end
            end
        
            // Bytes 1–10 (timestamp/locate) and 20–23 (shares) are not used in the
            // current feature set; sink them to suppress Verilator UNUSEDSIGNAL.
            /* verilator lint_off UNUSED */
            logic _unused_msg_bytes;
            assign _unused_msg_bytes = |{msg_data[279:192], msg_data[127:96]};
            /* verilator lint_on UNUSED */
        
        endmodule
        
