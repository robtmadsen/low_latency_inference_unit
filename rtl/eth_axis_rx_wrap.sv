// eth_axis_rx_wrap.sv — Drop-on-full Ethernet RX wrapper
//
// Wraps the Forencich eth_axis_rx module with a frame-granular Drop-on-Full
// policy for the KC705 10GbE stack.
//
// Policy:
//   When fifo_almost_full is asserted, the NEXT complete Ethernet frame is
//   silently dropped before it enters eth_axis_rx (and the downstream stack).
//   The current frame is always completed (partial frames are never dropped).
//   dropped_frames[31:0] saturates at 32'hFFFF_FFFF; never overflows.
//
// Key constraints:
//   • mac_rx_tready is always 1 when drop_current is asserted — the MAC is
//     never stalled and frame alignment is never corrupted.
//   • Only whole frames enter eth_axis_rx → udp_complete_64 — no partial frames.
//   • Both the MAC interface and fifo_almost_full are in the 156.25 MHz domain
//     (same clock); no CDC is required here.
//
// eth_axis_rx (Forencich) strips the 14-byte Ethernet header and presents:
//   • Header sideband: eth_hdr_valid/ready, eth_dest_mac, eth_src_mac, eth_type
//   • Payload AXI-S:   eth_payload_* → s_eth_payload_axis_* of udp_complete_64
//
// Domain: 156.25 MHz (clk_156 in kc705_top).

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

module eth_axis_rx_wrap (
    input  logic        clk,       // 156.25 MHz
    input  logic        rst,

    // From eth_mac_phy_10g (or testbench bypass)
    input  logic [63:0] mac_rx_tdata,
    input  logic [7:0]  mac_rx_tkeep,
    input  logic        mac_rx_tvalid,
    input  logic        mac_rx_tlast,
    output logic        mac_rx_tready,

    // Ethernet header sideband → udp_complete_64 s_eth_hdr_*
    output logic        eth_hdr_valid,
    input  logic        eth_hdr_ready,   // from udp_complete_64.s_eth_hdr_ready
    output logic [47:0] eth_dest_mac,
    output logic [47:0] eth_src_mac,
    output logic [15:0] eth_type,

    // Ethernet payload AXI-S → udp_complete_64 s_eth_payload_axis_*
    output logic [63:0] eth_payload_tdata,
    output logic [7:0]  eth_payload_tkeep,
    output logic        eth_payload_tvalid,
    output logic        eth_payload_tlast,
    input  logic        eth_payload_tready,

    // Drop-on-full control (from axis_async_fifo s_status_depth comparison)
    input  logic        fifo_almost_full,

    // Monitor register (AXI4-Lite readable via kc705_top / axi4_lite_slave)
    output logic [31:0] dropped_frames
);

    // ---------------------------------------------------------------
    // Frame-tracking state
    // ---------------------------------------------------------------
    logic frame_active;   // high from first beat to tlast (inclusive)
    logic drop_current;   // drop the entire current frame
    logic drop_decision;  // drop decision for the beat currently at MAC input

    // mac_rx_tready is permanently 1.  The MAC must never be stalled; the
    // drop-on-full policy discards whole frames instead of applying backpressure.
    // Previously this was gated on eth_rx_s_tready, which can be 0 for one
    // cycle immediately after reset exits, violating the SVA D1 invariant.
    assign mac_rx_tready = 1'b1;
    assign drop_decision = frame_active ? drop_current : fifo_almost_full;

    // ---------------------------------------------------------------
    // Frame-boundary detection
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            frame_active <= 1'b0;
            drop_current <= 1'b0;
        end else begin
            if (mac_rx_tvalid && mac_rx_tready) begin
                if (!frame_active && !mac_rx_tlast) begin
                    // First beat of a multi-beat frame: commit the drop
                    // decision and hold it stable until EOF.
                    frame_active <= 1'b1;
                    drop_current <= drop_decision;
                end else if (mac_rx_tlast) begin
                    // End of frame (single-beat or multi-beat): clear state
                    // so the next SOF samples fifo_almost_full again.
                    frame_active <= 1'b0;
                    drop_current <= 1'b0;
                end
            end
        end
    end

    // ---------------------------------------------------------------
    // Drop counter (saturating at 32'hFFFF_FFFF)
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            dropped_frames <= 32'd0;
        end else if (drop_decision && mac_rx_tvalid && mac_rx_tlast &&
                     dropped_frames != 32'hFFFF_FFFF) begin
            dropped_frames <= dropped_frames + 32'd1;
        end
    end

    // ---------------------------------------------------------------
    // eth_axis_rx instantiation (Forencich)
    //   Only fed when drop_current=0; silently consumed from MAC otherwise.
    // ---------------------------------------------------------------
    /* verilator lint_off UNUSED */
    logic eth_rx_busy;
    logic eth_rx_error;
    logic eth_rx_payload_tuser;
    logic eth_rx_s_tready;  // eth_axis_rx backpressure — not used for MAC; MAC is always-ready
    /* verilator lint_on UNUSED */

    eth_axis_rx #(
        .DATA_WIDTH  (64),
        .KEEP_ENABLE (1),
        .KEEP_WIDTH  (8)
    ) u_eth_rx (
        .clk                              (clk),
        .rst                              (rst),

        // AXI-S input from MAC (gated: not forwarded during drop_current)
        .s_axis_tdata                     (mac_rx_tdata),
        .s_axis_tkeep                     (mac_rx_tkeep),
        .s_axis_tvalid                    (mac_rx_tvalid & ~drop_decision),
        .s_axis_tready                    (eth_rx_s_tready),
        .s_axis_tlast                     (mac_rx_tlast),
        .s_axis_tuser                     (1'b0),   // no MAC error in bypass

        // Ethernet header sideband output
        .m_eth_hdr_valid                  (eth_hdr_valid),
        .m_eth_hdr_ready                  (eth_hdr_ready),
        .m_eth_dest_mac                   (eth_dest_mac),
        .m_eth_src_mac                    (eth_src_mac),
        .m_eth_type                       (eth_type),

        // Ethernet payload AXI-S output
        .m_eth_payload_axis_tdata         (eth_payload_tdata),
        .m_eth_payload_axis_tkeep         (eth_payload_tkeep),
        .m_eth_payload_axis_tvalid        (eth_payload_tvalid),
        .m_eth_payload_axis_tready        (eth_payload_tready),
        .m_eth_payload_axis_tlast         (eth_payload_tlast),
        .m_eth_payload_axis_tuser         (eth_rx_payload_tuser),

        // Status (unused)
        .busy                             (eth_rx_busy),
        .error_header_early_termination   (eth_rx_error)
    );

endmodule
