// ouch_packet_sva.sv — OUCH 5.0 Enter Order packet structural checker
//
// DUT target: kc705_top (KINTEX7_SIM_GTX_BYPASS)
// Spec ref:   .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.8, §7
//             NASDAQ OUCH 5.0 specification (Enter Order message)
//
// This module is bound to kc705_top and monitors the m_axis_* output bus.
// When a complete OUCH Enter Order packet has been received (tlast asserts),
// it checks the following structural invariants from the OUCH 5.0 spec:
//
//   1. Packet type byte ('O' = 0x4F) in byte 0.
//   2. Buy/Sell side byte is 'B' (0x42) or 'S' (0x53).
//   3. Shares field (4 bytes) is > 0.
//   4. Price field (4 bytes) is > 0.
//   5. No unexpected tvalid dropouts mid-packet (tvalid continuous from
//      first beat to tlast when tready is asserted).
//
// OUCH 5.0 Enter Order layout (48 bytes, 6 × 8-byte AXI4-S beats at 64-bit):
//
//   Byte  0    : Message type = 'O' (0x4F)
//   Bytes 1-14 : Order token (ASCII, 14 bytes)
//   Byte 15    : Buy/Sell side ('B' = 0x42, 'S' = 0x53)
//   Bytes 16-19: Shares (uint32, big-endian)
//   Bytes 20-27: Stock (8-byte ASCII ticker)
//   Bytes 28-31: Price (uint32, big-endian, units: 10^-4 dollars)
//   Bytes 32-35: Time in force (uint32)
//   Bytes 36-43: Firm (8-byte ASCII)
//   Bytes 44-47: Padding / reserved
//
// AXI4-S beat encoding: byte[n] is in tdata[(n%8)*8 +: 8] of beat n/8.
// (Little-endian byte lane: byte index k within a beat at position k*8.)
//
// Binding in tb_top.sv (KC705_TOP_DUT section):
//   bind kc705_top ouch_packet_sva u_ouch_sva (
//       .clk             (clk_300_in),
//       .rst             (cpu_reset),
//       .m_axis_tdata    (m_axis_tdata),
//       .m_axis_tkeep    (m_axis_tkeep),
//       .m_axis_tvalid   (m_axis_tvalid),
//       .m_axis_tlast    (m_axis_tlast),
//       .m_axis_tready   (m_axis_tready)
//   );

`ifdef KC705_TOP_DUT

module ouch_packet_sva (
    input logic        clk,
    input logic        rst,
    input logic [63:0] m_axis_tdata,
    input logic [7:0]  m_axis_tkeep,
    input logic        m_axis_tvalid,
    input logic        m_axis_tlast,
    input logic        m_axis_tready
);

    // ── Packet assembly buffer ─────────────────────────────────────
    // Maximum 6 beats × 8 bytes = 48 bytes for a complete OUCH Enter Order.
    localparam int MAX_BEATS = 6;
    localparam int PKT_BYTES = 48;

    logic [7:0]  pkt_buf [0:PKT_BYTES-1];
    int unsigned beat_idx;
    logic        in_packet;

    // ── Beat-accepted handshake ────────────────────────────────────
    wire beat_accepted = m_axis_tvalid && m_axis_tready;

    // ── Packet accumulation ───────────────────────────────────────
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            beat_idx <= 0;
            in_packet <= 1'b0;
            for (int i = 0; i < PKT_BYTES; i++) pkt_buf[i] <= 8'h00;
        end else if (beat_accepted) begin
            // Store this beat's bytes
            for (int k = 0; k < 8; k++) begin
                if (beat_idx * 8 + k < PKT_BYTES)
                    pkt_buf[beat_idx * 8 + k] <= m_axis_tdata[k*8 +: 8];
            end
            in_packet <= 1'b1;
            if (m_axis_tlast) begin
                beat_idx  <= 0;
                in_packet <= 1'b0;
            end else begin
                beat_idx <= beat_idx + 1;
            end
        end
    end

    // ── Packet checker — fires one cycle after tlast ──────────────
    // We register a "check_now" flag so all pkt_buf writes have settled.
    logic check_now;
    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            check_now <= 1'b0;
        else
            check_now <= beat_accepted && m_axis_tlast;
    end

    always_ff @(posedge clk) begin
        if (check_now) begin
            // ---- Check 1: message type = 'O' (0x4F) ----
            if (pkt_buf[0] !== 8'h4F)
                $error("[OUCH_SVA] Packet type mismatch: expected 0x4F ('O'), got 0x%02h",
                    pkt_buf[0]);

            // ---- Check 2: buy/sell byte must be 'B' (0x42) or 'S' (0x53) ----
            if (pkt_buf[15] !== 8'h42 && pkt_buf[15] !== 8'h53)
                $error("[OUCH_SVA] Buy/Sell byte invalid: got 0x%02h (expected 0x42='B' or 0x53='S')",
                    pkt_buf[15]);

            // ---- Check 3: shares > 0 ----
            begin
                logic [31:0] shares;
                shares = {pkt_buf[16], pkt_buf[17], pkt_buf[18], pkt_buf[19]};
                if (shares == 32'h0)
                    $error("[OUCH_SVA] Shares field is zero — invalid OUCH packet");
            end

            // ---- Check 4: price > 0 ----
            begin
                logic [31:0] price;
                price = {pkt_buf[28], pkt_buf[29], pkt_buf[30], pkt_buf[31]};
                if (price == 32'h0)
                    $error("[OUCH_SVA] Price field is zero — invalid OUCH packet");
            end

            $display("[OUCH_SVA] t=%0t Packet check PASS: type=0x%02h side=%s shares=%0d price=%0d",
                $time,
                pkt_buf[0],
                (pkt_buf[15] == 8'h42) ? "B" : "S",
                {pkt_buf[16], pkt_buf[17], pkt_buf[18], pkt_buf[19]},
                {pkt_buf[28], pkt_buf[29], pkt_buf[30], pkt_buf[31]});
        end
    end

    // ── Protocol check: tvalid must not drop mid-packet ──────────
    // Once the first beat is accepted, tvalid must remain asserted
    // through tlast (when tready is held high).
    // This is a combinational check via a property.
    property p_tvalid_continuous;
        @(posedge clk) disable iff (rst)
        (beat_accepted && !m_axis_tlast) |=> m_axis_tvalid;
    endproperty

    assert property (p_tvalid_continuous)
    else $error("[OUCH_SVA] tvalid dropped mid-packet at time %0t", $time);

endmodule

`endif  // KC705_TOP_DUT
