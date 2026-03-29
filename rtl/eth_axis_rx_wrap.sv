// eth_axis_rx_wrap.sv — Drop-on-full Ethernet RX wrapper
//
// Thin wrapper around the Forencich eth_axis_rx module that implements a
// frame-granular Drop-on-Full policy for the KC705 10GbE stack.
//
// Policy:
//   When fifo_almost_full is asserted, the NEXT complete Ethernet frame is
//   silently dropped before it enters the downstream ip_complete_64 path.
//   The current frame is always completed (partial frames are never dropped).
//   dropped_frames[31:0] saturates at 32'hFFFF_FFFF; never overflows.
//
// Key constraints:
//   • mac_rx_tready is always 1 when drop_current is asserted — the MAC is
//     never stalled and frame alignment is never corrupted.
//   • Only whole frames enter ip_complete_64 — no partial frames.
//   • Both the MAC interface and fifo_almost_full are in the 156.25 MHz domain
//     (same clock); no CDC is required here.
//
// NOTE: This wrapper is **structurally complete** but the Forencich
//       eth_axis_rx module is vendor IP not under rtl/; it is not instantiated
//       here.  kc705_top connects the MAC and IP-layer ports around this
//       wrapper.  During Verilator simulation (KINTEX7_SIM_MAC_BYPASS),
//       the mac_rx_* signals are driven directly from the testbench.
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

    // To ip_complete_64
    output logic [63:0] eth_payload_tdata,
    output logic [7:0]  eth_payload_tkeep,
    output logic        eth_payload_tvalid,
    output logic        eth_payload_tlast,
    input  logic        eth_payload_tready,

    // Drop-on-full control (from axis_async_fifo write-side almost_full)
    input  logic        fifo_almost_full,

    // Monitor register (AXI4-Lite readable via kc705_top / axi4_lite_slave)
    output logic [31:0] dropped_frames
);

    // ---------------------------------------------------------------
    // Frame-tracking state
    // ---------------------------------------------------------------
    logic frame_active;   // high from first beat to tlast (inclusive)
    logic drop_next;      // latch fifo_almost_full at frame boundary
    logic drop_current;   // drop the entire current frame

    // ---------------------------------------------------------------
    // Frame-boundary detection
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            frame_active <= 1'b0;
            drop_next    <= 1'b0;
            drop_current <= 1'b0;
        end else begin
            if (mac_rx_tvalid && mac_rx_tready) begin
                if (mac_rx_tlast) begin
                    // End of frame: close frame_active; sample fifo_almost_full
                    // for the NEXT frame; clear drop_current
                    frame_active <= 1'b0;
                    drop_next    <= fifo_almost_full;
                    drop_current <= 1'b0;
                end else if (!frame_active) begin
                    // First beat of a new frame: commit the drop decision
                    frame_active <= 1'b1;
                    drop_current <= drop_next;
                    // drop_next latches again at the next tlast
                end
            end else if (!frame_active) begin
                // Idle between frames: keep watching fifo_almost_full
                drop_next <= fifo_almost_full;
            end
        end
    end

    // ---------------------------------------------------------------
    // Drop counter (saturating at 32'hFFFF_FFFF)
    // ---------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            dropped_frames <= 32'd0;
        end else if (drop_current && mac_rx_tvalid && mac_rx_tlast &&
                     dropped_frames != 32'hFFFF_FFFF) begin
            dropped_frames <= dropped_frames + 32'd1;
        end
    end

    // ---------------------------------------------------------------
    // AXI4-Stream pass-through / gate
    //   When drop_current: consume all beats silently.
    //   Otherwise: pass through to eth_payload with standard flow control.
    // ---------------------------------------------------------------
    assign mac_rx_tready = drop_current ? 1'b1 : eth_payload_tready;

    assign eth_payload_tdata  = mac_rx_tdata;
    assign eth_payload_tkeep  = mac_rx_tkeep;
    assign eth_payload_tvalid = mac_rx_tvalid & ~drop_current;
    assign eth_payload_tlast  = mac_rx_tlast;

endmodule
