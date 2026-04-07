// itch_parser_v2.sv — AXI4-Stream ITCH 5.0 full message set parser
//
// Extends itch_parser to handle all order-book-relevant ITCH 5.0 message
// types.  All field extraction is performed inline (no sub-module
// instantiation).
//
// AXI4-Stream byte order: tdata[63:56] = first byte, tdata[7:0] = last byte
// ITCH framing: 2-byte big-endian length prefix, then message body
//
//   Frame layout — first 64-bit beat captured in S_IDLE:
//     tdata[63:56] = length_hi       (frame byte 0)
//     tdata[55:48] = length_lo       (frame byte 1)
//     tdata[47:40] = msg_buf[0]      (message type,  body byte 0)
//     tdata[39:32] = msg_buf[1]      (body byte 1)
//     tdata[31:24] = msg_buf[2]      (body byte 2)
//     tdata[23:16] = msg_buf[3]      (body byte 3)
//     tdata[15:8]  = msg_buf[4]      (body byte 4)
//     tdata[7:0]   = msg_buf[5]      (body byte 5)
//
// FSM: IDLE → ACCUMULATE → EMIT
//   IDLE:       Accept first beat; extract length prefix; store body bytes 0–5
//   ACCUMULATE: Store 8 bytes per beat starting at msg_buf[byte_cnt] until
//               the pre-increment check  byte_cnt + 8 >= msg_len  fires
//   EMIT:       Register all extracted fields; assert fields_valid for one
//               clock cycle; S_IDLE de-asserts fields_valid on re-entry
//
// byte_cnt tracking:
//   After S_IDLE first beat:     byte_cnt = 6   (body bytes 0–5 stored)
//   After each ACCUMULATE beat:  byte_cnt += 8
//   Transition S_ACCUMULATE→S_EMIT uses the *pre-increment* value:
//     {10'b0, byte_cnt} + 16'd8 >= msg_len
//   This is identical to the v1 approach in itch_parser.sv.
//
// Supported message types and body lengths (bytes, after 2-byte prefix):
//   'A' 0x41 = 36   'F' 0x46 = 40   'X' 0x58 = 23   'D' 0x44 = 19
//   'U' 0x55 = 35   'E' 0x45 = 30   'C' 0x43 = 35   'P' 0x50 = 43
//   Any other type: stream is drained silently; fields_valid stays 0.
//
// Field byte offsets match the NASDAQ ITCH 5.0 specification (v5.0, Sept 2019).
// Body byte 0 = message type; bytes 1-2 = stock_locate; 3-4 = tracking_number;
// 5-10 = timestamp; payload fields begin at byte 11.
//
// True ITCH 5.0 offsets used here:
//   order_ref               : bytes [11..18]  (all modifying types)
//   new_order_ref (U)       : bytes [19..26]
//   shares (A/F/P)          : bytes [20..23]
//   shares (X/E/C)          : bytes [19..22]
//   shares (U)              : bytes [27..30]
//   side (A/F/P)            : byte  [19]      ('B'=0x42 → bid=1)
//   stock (A/F/P)           : bytes [24..31]
//   price (A/F/C/P)         : bytes [32..35]
//   price (U)               : bytes [31..34]

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module itch_parser_v2 (
    input  logic        clk,
    input  logic        rst,

    // AXI4-Stream slave interface (big-endian byte order)
    input  logic [63:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    // Pipeline backpressure from lliu_top: hold off new messages when busy
    input  logic        pipeline_hold,

    // Parsed message type
    output logic [7:0]  msg_type,

    // Extracted field outputs (all stable for the one cycle fields_valid=1)
    output logic [63:0] order_ref,
    output logic [63:0] new_order_ref,
    output logic [31:0] price,
    output logic [31:0] shares,
    output logic        side,
    output logic [63:0] stock,
    output logic [8:0]  sym_id,
    output logic        fields_valid
);

    // ----- FSM states -----
    typedef enum logic [1:0] {
        S_IDLE       = 2'b00,
        S_ACCUMULATE = 2'b01,
        S_EMIT       = 2'b10
    } state_t;

    state_t state;

    // ----- Message byte buffer -----
    // 64 entries; covers the longest message body ('P' = 43 bytes).
    // Indices used: 0–5 from S_IDLE; 6–45 from S_ACCUMULATE beats.
    logic [7:0] msg_buf [0:63];
    logic [5:0] byte_cnt;    // number of message body bytes stored so far
    logic [15:0] msg_len;    // expected message body length (from length prefix)

    // ----- AXI4-Stream handshake -----
    // De-assert during S_EMIT (one cycle) and under pipeline backpressure.
    assign s_axis_tready = (state != S_EMIT) && !pipeline_hold;

    // ----- FSM + buffer fill + field registration -----
    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= S_IDLE;
            byte_cnt      <= 6'd0;
            msg_len       <= 16'd0;
            msg_type      <= 8'h0;
            order_ref     <= 64'h0;
            new_order_ref <= 64'h0;
            price         <= 32'h0;
            shares        <= 32'h0;
            side          <= 1'b0;
            stock         <= 64'h0;
            sym_id        <= 9'h0;
            fields_valid  <= 1'b0;
        end else begin
            case (state)

                // -------------------------------------------------------
                // IDLE: wait for first beat; extract length prefix and
                //       first 6 message body bytes into msg_buf[0..5]
                // -------------------------------------------------------
                S_IDLE: begin
                    fields_valid <= 1'b0;
                    if (s_axis_tvalid && s_axis_tready) begin
                        // 2-byte big-endian length prefix in tdata[63:48]
                        msg_len <= {s_axis_tdata[63:56], s_axis_tdata[55:48]};

                        // First 6 body bytes from tdata[47:0]
                        msg_buf[0] <= s_axis_tdata[47:40];   // message type
                        msg_buf[1] <= s_axis_tdata[39:32];
                        msg_buf[2] <= s_axis_tdata[31:24];
                        msg_buf[3] <= s_axis_tdata[23:16];
                        msg_buf[4] <= s_axis_tdata[15:8];
                        msg_buf[5] <= s_axis_tdata[7:0];
                        byte_cnt   <= 6'd6;

                        if ({s_axis_tdata[63:56], s_axis_tdata[55:48]} <= 16'd6) begin
                            // Complete message fits within first beat
                            state <= S_EMIT;
                        end else if (s_axis_tlast) begin
                            // Truncated: stream ended before message complete
                            state <= S_IDLE;
                        end else begin
                            state <= S_ACCUMULATE;
                        end
                    end
                end

                // -------------------------------------------------------
                // ACCUMULATE: store 8 bytes per beat at msg_buf[byte_cnt..
                //             byte_cnt+7]; advance byte_cnt; emit when done
                // -------------------------------------------------------
                S_ACCUMULATE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        msg_buf[byte_cnt + 6'd0] <= s_axis_tdata[63:56];
                        msg_buf[byte_cnt + 6'd1] <= s_axis_tdata[55:48];
                        msg_buf[byte_cnt + 6'd2] <= s_axis_tdata[47:40];
                        msg_buf[byte_cnt + 6'd3] <= s_axis_tdata[39:32];
                        msg_buf[byte_cnt + 6'd4] <= s_axis_tdata[31:24];
                        msg_buf[byte_cnt + 6'd5] <= s_axis_tdata[23:16];
                        msg_buf[byte_cnt + 6'd6] <= s_axis_tdata[15:8];
                        msg_buf[byte_cnt + 6'd7] <= s_axis_tdata[7:0];

                        byte_cnt <= byte_cnt + 6'd8;

                        // Transition when this beat completes the body
                        // (pre-increment comparison: current byte_cnt + 8 >= msg_len)
                        if ({10'b0, byte_cnt} + 16'd8 >= msg_len) begin
                            state <= S_EMIT;
                        end else if (s_axis_tlast) begin
                            // Truncated message: discard
                            state <= S_IDLE;
                        end
                    end
                end

                // -------------------------------------------------------
                // EMIT: register all extracted fields from msg_buf;
                //       assert fields_valid for supported types only;
                //       transition to S_IDLE where fields_valid is cleared
                // -------------------------------------------------------
                S_EMIT: begin
                    state <= S_IDLE;

                    // msg_type always captured
                    msg_type <= msg_buf[0];
                    sym_id   <= 9'h0;

                    // order_ref: bytes [11..18] for all modifying types
                    order_ref <= {msg_buf[11], msg_buf[12], msg_buf[13], msg_buf[14],
                                  msg_buf[15], msg_buf[16], msg_buf[17], msg_buf[18]};

                    // new_order_ref: Order Replace ('U') only — bytes [19..26]
                    if (msg_buf[0] == 8'h55) begin
                        new_order_ref <= {msg_buf[19], msg_buf[20], msg_buf[21], msg_buf[22],
                                          msg_buf[23], msg_buf[24], msg_buf[25], msg_buf[26]};
                    end else begin
                        new_order_ref <= 64'h0;
                    end

                    // price
                    if (msg_buf[0] == 8'h41 ||     // 'A'
                        msg_buf[0] == 8'h46 ||     // 'F'
                        msg_buf[0] == 8'h43 ||     // 'C'
                        msg_buf[0] == 8'h50) begin  // 'P'
                        price <= {msg_buf[32], msg_buf[33], msg_buf[34], msg_buf[35]};
                    end else if (msg_buf[0] == 8'h55) begin // 'U'
                        price <= {msg_buf[31], msg_buf[32], msg_buf[33], msg_buf[34]};
                    end else begin
                        price <= 32'h0;
                    end

                    // shares
                    if (msg_buf[0] == 8'h41 ||     // 'A'
                        msg_buf[0] == 8'h46 ||     // 'F'
                        msg_buf[0] == 8'h50) begin  // 'P'
                        shares <= {msg_buf[20], msg_buf[21], msg_buf[22], msg_buf[23]};
                    end else if (msg_buf[0] == 8'h58 ||    // 'X'
                                 msg_buf[0] == 8'h45 ||    // 'E'
                                 msg_buf[0] == 8'h43) begin // 'C'
                        shares <= {msg_buf[19], msg_buf[20], msg_buf[21], msg_buf[22]};
                    end else if (msg_buf[0] == 8'h55) begin // 'U'
                        shares <= {msg_buf[27], msg_buf[28], msg_buf[29], msg_buf[30]};
                    end else begin
                        shares <= 32'h0;
                    end

                    // side: Buy='B'(0x42)→1 for Add Orders and Trade
                    if (msg_buf[0] == 8'h41 ||     // 'A'
                        msg_buf[0] == 8'h46 ||     // 'F'
                        msg_buf[0] == 8'h50) begin  // 'P'
                        side <= (msg_buf[19] == 8'h42) ? 1'b1 : 1'b0;
                    end else begin
                        side <= 1'b0;
                    end

                    // stock: 8-byte ASCII ticker at bytes [24..31] for A/F/P
                    if (msg_buf[0] == 8'h41 ||     // 'A'
                        msg_buf[0] == 8'h46 ||     // 'F'
                        msg_buf[0] == 8'h50) begin  // 'P'
                        stock <= {msg_buf[24], msg_buf[25], msg_buf[26], msg_buf[27],
                                  msg_buf[28], msg_buf[29], msg_buf[30], msg_buf[31]};
                    end else begin
                        stock <= 64'h0;
                    end

                    // fields_valid: pulse for all supported types
                    if (msg_buf[0] == 8'h41 ||     // 'A'
                        msg_buf[0] == 8'h46 ||     // 'F'
                        msg_buf[0] == 8'h58 ||     // 'X'
                        msg_buf[0] == 8'h44 ||     // 'D'
                        msg_buf[0] == 8'h55 ||     // 'U'
                        msg_buf[0] == 8'h45 ||     // 'E'
                        msg_buf[0] == 8'h43 ||     // 'C'
                        msg_buf[0] == 8'h50) begin  // 'P'
                        fields_valid <= 1'b1;
                    end else begin
                        fields_valid <= 1'b0;
                    end
                end

                /* verilator coverage_off */
                default: state <= S_IDLE;
                /* verilator coverage_on */

            endcase
        end
    end

endmodule
