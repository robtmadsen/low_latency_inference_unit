// itch_parser.sv — AXI4-Stream ITCH 5.0 message parser
//
// Accepts a byte stream via AXI4-Stream (64-bit, big-endian byte order),
// aligns length-prefixed ITCH messages, and extracts Add Order fields.
//
// AXI4-Stream byte order: tdata[63:56] = first byte, tdata[7:0] = last byte
// ITCH framing: 2-byte big-endian length prefix, then message body
//
// FSM: IDLE → ACCUMULATE → EMIT
//   IDLE:       Accept first beat, extract length prefix, store first 6 msg bytes
//   ACCUMULATE: Store subsequent beats (8 bytes each) until message complete
//   EMIT:       Assert msg_valid for one cycle, backpressure upstream
//
// pipeline_hold: external backpressure from lliu_top. When high, s_axis_tready
// is de-asserted so no new message is accepted while the inference pipeline is
// busy processing the previous Add-Order message. This ensures every
// Add-Order that fires parser_fields_valid is actually processed by the DPE.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module itch_parser (
    input  logic        clk,
    input  logic        rst,

    // AXI4-Stream slave interface (big-endian byte order)
    input  logic [63:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    // Pipeline backpressure from lliu_top: hold off new messages when busy
    input  logic        pipeline_hold,

    // Message-level strobe (any complete message)
    output logic        msg_valid,

    // Extracted field outputs (from itch_field_extract, Add Order only)
    output logic [7:0]  message_type,
    output logic [63:0] order_ref,
    output logic        side,
    output logic [31:0] price,
    output logic [63:0] stock,      // 8-byte ASCII ticker (bytes 24–31)
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
    // 128 entries so 7-bit byte_cnt indexes cleanly; only first 36 used for field extract
    logic [7:0]  msg_buf [0:127];
    logic [6:0]  byte_cnt;   // bytes of message body stored so far
    logic [15:0] msg_len;    // expected message body length (from length prefix)

    // ----- AXI4-Stream handshake -----
    assign s_axis_tready = (state != S_EMIT) && !pipeline_hold;

    // ----- Message valid strobe -----
    assign msg_valid = (state == S_EMIT);

    // ----- Pack msg_buf[0:35] into msg_data for field extract -----
    logic [ITCH_ADD_ORDER_LEN*8-1:0] msg_data;

    genvar gi;
    generate
        for (gi = 0; gi < ITCH_ADD_ORDER_LEN; gi++) begin : gen_pack
            assign msg_data[(ITCH_ADD_ORDER_LEN-1-gi)*8 +: 8] = msg_buf[gi];
        end
    endgenerate

    // ----- Field extract instance -----
    itch_field_extract u_field_extract (
        .msg_data     (msg_data),
        .msg_valid    (msg_valid),
        .message_type (message_type),
        .order_ref    (order_ref),
        .side         (side),
        .price        (price),
        .stock        (stock),
        .fields_valid (fields_valid)
    );

    // ----- FSM -----
    always_ff @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            byte_cnt <= 7'd0;
            msg_len  <= 16'd0;
        end else begin
            case (state)
                // -------------------------------------------------------
                // IDLE: wait for first beat, extract length + first 6 msg bytes
                // -------------------------------------------------------
                S_IDLE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        // 2-byte big-endian length prefix
                        msg_len <= {s_axis_tdata[63:56], s_axis_tdata[55:48]};

                        // First 6 message bytes from tdata[47:0]
                        msg_buf[0] <= s_axis_tdata[47:40];
                        msg_buf[1] <= s_axis_tdata[39:32];
                        msg_buf[2] <= s_axis_tdata[31:24];
                        msg_buf[3] <= s_axis_tdata[23:16];
                        msg_buf[4] <= s_axis_tdata[15:8];
                        msg_buf[5] <= s_axis_tdata[7:0];
                        byte_cnt   <= 7'd6;

                        if ({s_axis_tdata[63:56], s_axis_tdata[55:48]} <= 16'd6) begin
                            // Short message fits in first beat
                            state <= S_EMIT;
                        end else if (s_axis_tlast) begin
                            // Truncated: no more beats but message not complete
                            state <= S_IDLE;
                        end else begin
                            state <= S_ACCUMULATE;
                        end
                    end
                end

                // -------------------------------------------------------
                // ACCUMULATE: store 8 bytes per beat until message complete
                // -------------------------------------------------------
                S_ACCUMULATE: begin
                    if (s_axis_tvalid && s_axis_tready) begin
                        // Write 8 bytes at byte_cnt .. byte_cnt+7
                        msg_buf[byte_cnt]         <= s_axis_tdata[63:56];
                        msg_buf[byte_cnt + 7'd1]  <= s_axis_tdata[55:48];
                        msg_buf[byte_cnt + 7'd2]  <= s_axis_tdata[47:40];
                        msg_buf[byte_cnt + 7'd3]  <= s_axis_tdata[39:32];
                        msg_buf[byte_cnt + 7'd4]  <= s_axis_tdata[31:24];
                        msg_buf[byte_cnt + 7'd5]  <= s_axis_tdata[23:16];
                        msg_buf[byte_cnt + 7'd6]  <= s_axis_tdata[15:8];
                        msg_buf[byte_cnt + 7'd7]  <= s_axis_tdata[7:0];

                        byte_cnt <= byte_cnt + 7'd8;

                        if ({9'b0, byte_cnt} + 16'd8 >= msg_len) begin
                            state <= S_EMIT;
                        end else if (s_axis_tlast) begin
                            // Truncated message, discard
                            state <= S_IDLE;
                        end
                    end
                end

                // -------------------------------------------------------
                // EMIT: msg_valid high for one cycle, then back to IDLE
                // -------------------------------------------------------
                S_EMIT: begin
                    state <= S_IDLE;
                end

                /* verilator coverage_off */
                default: state <= S_IDLE;
                /* verilator coverage_on */
            endcase
        end
    end

endmodule
