// kc705_top.sv — KC705 board-level integrator for LLIU v2.0
//
// Pipeline summary:
//   [clk_156] mac_rx → eth_axis_rx_wrap → udp_complete_64 → moldupp64_strip
//                → axis_async_fifo CDC (clk_156 write → clk_300 read)
//   [clk_300] lliu_top_v2: itch_parser_v2 → order_book → symbol_filter →
//             feature_extractor_v2 → 8×lliu_core → strategy_arbiter →
//             risk_check → ouch_engine → m_axis OUCH 5.0 output
//   [clk_300] AXI4-Lite control inline in lliu_top_v2 (12-bit byte address)
//
// KINTEX7_SIM_GTX_BYPASS (must be defined for Verilator lint/simulation):
//   - clk_156_in, clk_300_in replace IBUFDS/MMCM/GTX outputs.
//   - mac_rx_* exposed as top-level ports; testbench sends full Ethernet frames
//     (Ethernet + IPv4 + UDP + MoldUDP64 headers — see MAS §6.3).
//   - ip_complete_64, udp_complete_64, axis_async_fifo are instantiated and
//     run in simulation (not bypassed).
//   - fifo_rd_tvalid exposed for SVA latency measurement; driven from the
//     real axis_async_fifo m_axis_tvalid output.
//
// In synthesis (KINTEX7_SIM_GTX_BYPASS NOT defined):
//   Instantiate Forencich IP (eth_mac_phy_10g, ip_complete_64, udp_complete_64,
//   axis_async_fifo) with the standard Xilinx IBUFDS/IBUFDS_GTE2/MMCM_ADV
//   primitives. These modules are not in rtl/ and not compiled by Verilator.
//
// AXI4-Lite address map: see lliu_top_v2.sv header and 2p0_kintex-7_MAS.md §4.10.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

/* verilator lint_off MULTITOP */
module kc705_top #(
    parameter int AXIL_ADDR = 12,
    parameter int AXIL_DATA = 32
)(
    // ── Board oscillator (200 MHz LVDS) ──────────────────────────────
    input  logic        sys_clk_p,
    input  logic        sys_clk_n,

    // Active-high global reset (KC705 CPU_RESET button, LVCMOS15)
    input  logic        cpu_reset,

    // ── SFP+ cage (J3) — 10GbE ───────────────────────────────────────
    input  logic        sfp_rx_p,
    input  logic        sfp_rx_n,
    output logic        sfp_tx_p,
    output logic        sfp_tx_n,

    // 156.25 MHz MGT reference clock (LVDS, from KC705 SFP cage)
    input  logic        mgt_refclk_p,
    input  logic        mgt_refclk_n,

    // ── AXI4-Lite host interface (from PCIe / soft CPU) ───────────────
    input  logic [AXIL_ADDR-1:0]   axil_awaddr,
    input  logic                   axil_awvalid,
    output logic                   axil_awready,
    input  logic [AXIL_DATA-1:0]   axil_wdata,
    input  logic [AXIL_DATA/8-1:0] axil_wstrb,
    input  logic                   axil_wvalid,
    output logic                   axil_wready,
    output logic [1:0]             axil_bresp,
    output logic                   axil_bvalid,
    input  logic                   axil_bready,
    input  logic [AXIL_ADDR-1:0]   axil_araddr,
    input  logic                   axil_arvalid,
    output logic                   axil_arready,
    output logic [AXIL_DATA-1:0]   axil_rdata,
    output logic [1:0]             axil_rresp,
    output logic                   axil_rvalid,
    input  logic                   axil_rready,

    // ── PCIe Gen2 x4 — BBO snapshot DMA to host ───────────────────────
    input  logic        pcie_clk_p,
    input  logic        pcie_clk_n,
    input  logic        pcie_rst_n,
    input  logic [3:0]  pcie_rxp,
    input  logic [3:0]  pcie_rxn,
    output logic [3:0]  pcie_txp,
    output logic [3:0]  pcie_txn,

    // ── OUCH 5.0 output (to 10GbE TX MAC) ────────────────────────────
    output logic [63:0]            m_axis_tdata,
    output logic [7:0]             m_axis_tkeep,
    output logic                   m_axis_tvalid,
    output logic                   m_axis_tlast,
    input  logic                   m_axis_tready,

    // ── Monitoring outputs ────────────────────────────────────────────
    output logic [31:0]            collision_count_out,
    output logic                   tx_overflow_out,
    output logic [31:0]            dropped_frames_out,
    output logic [31:0]            dropped_datagrams_out,
    output logic [63:0]            expected_seq_num_out

`ifdef KINTEX7_SIM_GTX_BYPASS
    ,
    // Simulation: testbench drives clock sources and full Ethernet frames.
    // Both clock inputs may be tied to the same signal for single-clock sims.
    input  logic        clk_156_in,     // replaces GTX recovered clock
    input  logic        clk_300_in,     // replaces MMCM output

    // MAC RX AXI4-Stream (testbench drives full Ethernet frames)
    input  logic [63:0] mac_rx_tdata,
    input  logic [7:0]  mac_rx_tkeep,
    input  logic        mac_rx_tvalid,
    input  logic        mac_rx_tlast,
    output logic        mac_rx_tready,

    // ITCH stream valid at itch_parser input — used by SVA latency checker
    output logic        fifo_rd_tvalid
`endif
);

    // ==================================================================
    // Clocks
    // ==================================================================

    // clk_300/clk_156 are undriven in the Verilator synthesis path (no IBUFDS/
    // MMCM_ADV/GTX primitives compiled); driven via clk_*_in in sim path.
    /* verilator lint_off UNDRIVEN */
    logic clk_300, clk_156;
    /* verilator lint_on UNDRIVEN */

`ifdef KINTEX7_SIM_GTX_BYPASS
    assign clk_300 = clk_300_in;
    assign clk_156 = clk_156_in;
`else
    // Hardware: IBUFDS pads → MMCM_ADV (clk_300), GTX recovered (clk_156).
    // These Xilinx primitives are not compiled by Verilator (synthesis only).
`endif

    // SFP TX not yet driven — tie differential outputs to a fixed level.
    assign sfp_tx_p = 1'b0;
    assign sfp_tx_n = 1'b1;

    // ==================================================================
    // Reset synchronisers (2-FF, one per clock domain)
    // ==================================================================

    /* verilator lint_off SYNCASYNCNET */
    logic [1:0] rst_300_sr, rst_156_sr;
    logic       rst_300, rst_156;

    always_ff @(posedge clk_300 or posedge cpu_reset) begin
        if (cpu_reset) rst_300_sr <= 2'b11;
        else           rst_300_sr <= {rst_300_sr[0], 1'b0};
    end
    assign rst_300 = rst_300_sr[1];

    always_ff @(posedge clk_156 or posedge cpu_reset) begin
        if (cpu_reset) rst_156_sr <= 2'b11;
        else           rst_156_sr <= {rst_156_sr[0], 1'b0};
    end
    assign rst_156 = rst_156_sr[1];
    /* verilator lint_on SYNCASYNCNET */

    // Suppress Verilator UNUSEDSIGNAL warnings for board-level differential
    // inputs consumed only by hardware-side IBUFDS/GTX primitives.  These ports
    // always exist on the module and must be sunk in both sim and synthesis paths.
    /* verilator lint_off UNUSEDSIGNAL */
    logic _unused_board;
    assign _unused_board = sys_clk_p  ^ sys_clk_n
                         ^ mgt_refclk_p ^ mgt_refclk_n
                         ^ sfp_rx_p    ^ sfp_rx_n;
    /* verilator lint_on UNUSEDSIGNAL */

    // ==================================================================
    // clk_156 domain: Ethernet RX → MoldUDP64 strip
    // ==================================================================

    // FIFO almost-full feedback to eth_axis_rx_wrap (drop-on-full policy).
    // Derived from axis_async_fifo.s_status_depth in the ifdef block below.
    // Threshold: depth >= 64 (headroom < one max ITCH-message burst per MAS §2.3).
    // In synthesis path: assigned stub values; eth_axis_rx_wrap not in scope.
    /* verilator lint_off UNUSEDSIGNAL */
    logic fifo_almost_full;
    logic [7:0] fifo_s_depth;  // axis_async_fifo write-side depth [$clog2(128):0]
    /* verilator lint_on UNUSEDSIGNAL */

    // Monitoring: dropped Ethernet frames (clk_156 domain)
    logic [31:0] dropped_frames_156;

    // eth_axis_rx_wrap output → [ip_complete_64 → udp_complete_64 in hw]
    // In sim bypass, its output feeds moldupp64_strip directly as "UDP payload".
    logic [63:0] udp_payload_tdata;
    logic [7:0]  udp_payload_tkeep;
    logic        udp_payload_tvalid;
    logic        udp_payload_tlast;
    // udp_payload_tready is driven by moldupp64.s_tready but consumed only by
    // udp_complete_64 (sim path); reports UNUSEDSIGNAL in synthesis path.
    /* verilator lint_off UNUSEDSIGNAL */
    logic        udp_payload_tready;
    /* verilator lint_on UNUSEDSIGNAL */

`ifdef KINTEX7_SIM_GTX_BYPASS
    // eth_axis_rx_wrap: internally instantiates eth_axis_rx (Forencich)
    // and adds drop-on-full policy. Outputs Ethernet header sideband and
    // stripped payload stream for udp_complete_64.
    logic        eth_hdr_valid;
    logic        eth_hdr_ready;
    logic [47:0] eth_dest_mac;
    logic [47:0] eth_src_mac;
    logic [15:0] eth_type;
    logic [63:0] eth_wrap_tdata;
    logic [7:0]  eth_wrap_tkeep;
    logic        eth_wrap_tvalid;
    logic        eth_wrap_tlast;
    logic        eth_wrap_tready;

    eth_axis_rx_wrap u_eth_rx_wrap (
        .clk                (clk_156),
        .rst                (rst_156),
        .mac_rx_tdata       (mac_rx_tdata),
        .mac_rx_tkeep       (mac_rx_tkeep),
        .mac_rx_tvalid      (mac_rx_tvalid),
        .mac_rx_tlast       (mac_rx_tlast),
        .mac_rx_tready      (mac_rx_tready),
        .eth_hdr_valid      (eth_hdr_valid),
        .eth_hdr_ready      (eth_hdr_ready),
        .eth_dest_mac       (eth_dest_mac),
        .eth_src_mac        (eth_src_mac),
        .eth_type           (eth_type),
        .eth_payload_tdata  (eth_wrap_tdata),
        .eth_payload_tkeep  (eth_wrap_tkeep),
        .eth_payload_tvalid (eth_wrap_tvalid),
        .eth_payload_tlast  (eth_wrap_tlast),
        .eth_payload_tready (eth_wrap_tready),
        .fifo_almost_full   (fifo_almost_full),
        .dropped_frames     (dropped_frames_156)
    );

    // udp_complete_64: full Ethernet→IP→UDP stack (Forencich).
    // Accepts eth_hdr sideband + eth_payload stream; outputs raw UDP payload
    // (MoldUDP64 datagram) → moldupp64_strip.
    /* verilator lint_off UNUSED */
    logic        udp_hdr_valid_i;
    logic [15:0] udp_src_port_i;
    logic [15:0] udp_dest_port_i;
    logic [15:0] udp_length_i;
    logic [15:0] udp_checksum_i;
    logic        udp_payload_tuser_i;
    /* verilator lint_on UNUSED */

    /* verilator lint_off PINCONNECTEMPTY */
    udp_complete_64 u_udp (
        .clk                                    (clk_156),
        .rst                                    (rst_156),

        // Ethernet RX input (from eth_axis_rx_wrap)
        .s_eth_hdr_valid                        (eth_hdr_valid),
        .s_eth_hdr_ready                        (eth_hdr_ready),
        .s_eth_dest_mac                         (eth_dest_mac),
        .s_eth_src_mac                          (eth_src_mac),
        .s_eth_type                             (eth_type),
        .s_eth_payload_axis_tdata               (eth_wrap_tdata),
        .s_eth_payload_axis_tkeep               (eth_wrap_tkeep),
        .s_eth_payload_axis_tvalid              (eth_wrap_tvalid),
        .s_eth_payload_axis_tready              (eth_wrap_tready),
        .s_eth_payload_axis_tlast               (eth_wrap_tlast),
        .s_eth_payload_axis_tuser               (1'b0),

        // TX Ethernet output — discard (RX-only datapath)
        .m_eth_hdr_valid                        (),
        .m_eth_hdr_ready                        (1'b1),
        .m_eth_dest_mac                         (),
        .m_eth_src_mac                          (),
        .m_eth_type                             (),
        .m_eth_payload_axis_tdata               (),
        .m_eth_payload_axis_tkeep               (),
        .m_eth_payload_axis_tvalid              (),
        .m_eth_payload_axis_tready              (1'b1),
        .m_eth_payload_axis_tlast               (),
        .m_eth_payload_axis_tuser               (),

        // TX IP input — tie off (no TX path)
        .s_ip_hdr_valid                         (1'b0),
        .s_ip_hdr_ready                         (),
        .s_ip_dscp                              (6'b0),
        .s_ip_ecn                               (2'b0),
        .s_ip_length                            (16'b0),
        .s_ip_ttl                               (8'd64),
        .s_ip_protocol                          (8'h11),
        .s_ip_source_ip                         (32'h0A000001),
        .s_ip_dest_ip                           (32'hE9360C00),
        .s_ip_payload_axis_tdata                (64'b0),
        .s_ip_payload_axis_tkeep                (8'b0),
        .s_ip_payload_axis_tvalid               (1'b0),
        .s_ip_payload_axis_tready               (),
        .s_ip_payload_axis_tlast                (1'b0),
        .s_ip_payload_axis_tuser                (1'b0),

        // TX IP output — discard
        .m_ip_hdr_valid                         (),
        .m_ip_hdr_ready                         (1'b1),
        .m_ip_eth_dest_mac                      (),
        .m_ip_eth_src_mac                       (),
        .m_ip_eth_type                          (),
        .m_ip_version                           (),
        .m_ip_ihl                               (),
        .m_ip_dscp                              (),
        .m_ip_ecn                               (),
        .m_ip_length                            (),
        .m_ip_identification                    (),
        .m_ip_flags                             (),
        .m_ip_fragment_offset                   (),
        .m_ip_ttl                               (),
        .m_ip_protocol                          (),
        .m_ip_header_checksum                   (),
        .m_ip_source_ip                         (),
        .m_ip_dest_ip                           (),
        .m_ip_payload_axis_tdata                (),
        .m_ip_payload_axis_tkeep                (),
        .m_ip_payload_axis_tvalid               (),
        .m_ip_payload_axis_tready               (1'b1),
        .m_ip_payload_axis_tlast                (),
        .m_ip_payload_axis_tuser                (),

        // TX UDP input — tie off (no TX path)
        .s_udp_hdr_valid                        (1'b0),
        .s_udp_hdr_ready                        (),
        .s_udp_ip_dscp                          (6'b0),
        .s_udp_ip_ecn                           (2'b0),
        .s_udp_ip_ttl                           (8'd64),
        .s_udp_ip_source_ip                     (32'h0A000001),
        .s_udp_ip_dest_ip                       (32'hE9360C00),
        .s_udp_source_port                      (16'h0400),
        .s_udp_dest_port                        (16'd26477),
        .s_udp_length                           (16'b0),
        .s_udp_checksum                         (16'b0),
        .s_udp_payload_axis_tdata               (64'b0),
        .s_udp_payload_axis_tkeep               (8'b0),
        .s_udp_payload_axis_tvalid              (1'b0),
        .s_udp_payload_axis_tready              (),
        .s_udp_payload_axis_tlast               (1'b0),
        .s_udp_payload_axis_tuser               (1'b0),

        // RX UDP output → moldupp64_strip (via udp_payload_* wires)
        .m_udp_hdr_valid                        (udp_hdr_valid_i),
        .m_udp_hdr_ready                        (1'b1),
        .m_udp_eth_dest_mac                     (),
        .m_udp_eth_src_mac                      (),
        .m_udp_eth_type                         (),
        .m_udp_ip_version                       (),
        .m_udp_ip_ihl                           (),
        .m_udp_ip_dscp                          (),
        .m_udp_ip_ecn                           (),
        .m_udp_ip_length                        (),
        .m_udp_ip_identification                (),
        .m_udp_ip_flags                         (),
        .m_udp_ip_fragment_offset               (),
        .m_udp_ip_ttl                           (),
        .m_udp_ip_protocol                      (),
        .m_udp_ip_header_checksum               (),
        .m_udp_ip_source_ip                     (),
        .m_udp_ip_dest_ip                       (),
        .m_udp_source_port                      (udp_src_port_i),
        .m_udp_dest_port                        (udp_dest_port_i),
        .m_udp_length                           (udp_length_i),
        .m_udp_checksum                         (udp_checksum_i),
        .m_udp_payload_axis_tdata               (udp_payload_tdata),
        .m_udp_payload_axis_tkeep               (udp_payload_tkeep),
        .m_udp_payload_axis_tvalid              (udp_payload_tvalid),
        .m_udp_payload_axis_tready              (udp_payload_tready),
        .m_udp_payload_axis_tlast               (udp_payload_tlast),
        .m_udp_payload_axis_tuser               (udp_payload_tuser_i),

        // Status — discard
        .ip_rx_busy                             (),
        .ip_tx_busy                             (),
        .udp_rx_busy                            (),
        .udp_tx_busy                            (),
        .ip_rx_error_header_early_termination   (),
        .ip_rx_error_payload_early_termination  (),
        .ip_rx_error_invalid_header             (),
        .ip_rx_error_invalid_checksum           (),
        .ip_tx_error_payload_early_termination  (),
        .ip_tx_error_arp_failed                 (),
        .udp_rx_error_header_early_termination  (),
        .udp_rx_error_payload_early_termination (),
        .udp_tx_error_payload_early_termination (),

        // Configuration (driven combinationally each cycle)
        .local_mac                              (48'h020000000001),
        .local_ip                               (32'hE9360C00),    // 233.54.12.0
        .gateway_ip                             (32'h0A000001),    // 10.0.0.1
        .subnet_mask                            (32'hFFFFFF00),
        .clear_arp_cache                        (1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */
`else
    // Hardware: eth_mac_phy_10g → eth_axis_rx_wrap → udp_complete_64
    //           driving udp_payload_*.
    // (Forencich IP instantiation — not compiled by Verilator without define.)
    assign dropped_frames_156  = '0;  // suppresses Verilator UNDRIVEN in hw path
    assign udp_payload_tdata   = '0;
    assign udp_payload_tkeep   = '0;
    assign udp_payload_tvalid  = 1'b0;
    assign udp_payload_tlast   = 1'b0;
`endif

    // MoldUDP64 header strip + sequence number gap detection (clk_156)
    // itch_net_tdata/tkeep/tvalid/tlast are driven by moldupp64_strip and
    // consumed by axis_async_fifo (sim path only); unused in synthesis path.
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] itch_net_tdata;
    logic [7:0]  itch_net_tkeep;
    logic        itch_net_tvalid;
    logic        itch_net_tlast;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        itch_net_tready;

    /* verilator lint_off UNUSED */
    logic [63:0] moldupp_seq_num;
    logic [15:0] moldupp_msg_count;
    logic        moldupp_seq_valid;
    /* verilator lint_on UNUSED */
    logic [31:0] dropped_datagrams_156;
    logic [63:0] expected_seq_num_156;

    moldupp64_strip u_moldupp64 (
        .clk               (clk_156),
        .rst               (rst_156),
        .s_tdata           (udp_payload_tdata),
        .s_tkeep           (udp_payload_tkeep),
        .s_tvalid          (udp_payload_tvalid),
        .s_tlast           (udp_payload_tlast),
        .s_tready          (udp_payload_tready),
        .m_tdata           (itch_net_tdata),
        .m_tkeep           (itch_net_tkeep),
        .m_tvalid          (itch_net_tvalid),
        .m_tlast           (itch_net_tlast),
        .m_tready          (itch_net_tready),
        .seq_num           (moldupp_seq_num),
        .msg_count         (moldupp_msg_count),
        .seq_valid         (moldupp_seq_valid),
        .dropped_datagrams (dropped_datagrams_156),
        .expected_seq_num  (expected_seq_num_156)
    );

    // ==================================================================
    // CDC: clk_156 → clk_300
    //
    // axis_async_fifo (Forencich) bridges the ITCH stream across domains.
    // Under KINTEX7_SIM_GTX_BYPASS the real FIFO is instantiated; testbench
    // may run both clocks from the same source for single-clock sims.
    //
    // Monitoring counters (dropped_frames, dropped_datagrams, expected_seq_num)
    // are re-sampled in clk_300 using a 2-stage FF chain. Monotonically
    // increasing counters tolerate the occasional metastability glitch in
    // this best-effort readout path.
    // ==================================================================

    // ITCH stream on the clk_300 side (FIFO read side).
    // tkeep: no byte-enables on ITCH stream, unused after FIFO.
    // tready: driven by itch_parser but consumed only by FIFO (sim path).
    logic [63:0] itch_300_tdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0]  itch_300_tkeep;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        itch_300_tvalid;
    logic        itch_300_tlast;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        itch_300_tready;
    /* verilator lint_on UNUSEDSIGNAL */

    // moldupp64_strip outputs little-endian AXI4-S (byte 0 → tdata[7:0]);
    // itch_parser expects big-endian (tdata[63:56] = first byte of message).
    // Byte-reverse the 64-bit word here to reconcile the two conventions.
    logic [63:0] itch_300_tdata_swapped;

`ifdef KINTEX7_SIM_GTX_BYPASS
    // axis_async_fifo: CDC from clk_156 (156.25 MHz, ITCH net) → clk_300 (app).
    // s_status_depth drives fifo_almost_full threshold for drop-on-full policy.
    assign fifo_almost_full = (fifo_s_depth >= 8'd64);

    /* verilator lint_off PINCONNECTEMPTY */
    axis_async_fifo #(
        .DEPTH        (128),
        .DATA_WIDTH   (64),
        .KEEP_ENABLE  (1),
        .KEEP_WIDTH   (8),
        .LAST_ENABLE  (1),
        .ID_ENABLE    (0),
        .DEST_ENABLE  (0),
        .USER_ENABLE  (0),
        .RAM_PIPELINE (1),
        .FRAME_FIFO   (0)
    ) u_async_fifo (
        // Write side — clk_156 domain
        .s_clk                  (clk_156),
        .s_rst                  (rst_156),
        .s_axis_tdata           (itch_net_tdata),
        .s_axis_tkeep           (itch_net_tkeep),
        .s_axis_tvalid          (itch_net_tvalid),
        .s_axis_tready          (itch_net_tready),
        .s_axis_tlast           (itch_net_tlast),
        .s_axis_tid             (8'b0),
        .s_axis_tdest           (8'b0),
        .s_axis_tuser           (1'b0),
        .s_pause_req            (1'b0),
        .s_pause_ack            (),
        .s_status_depth         (fifo_s_depth),
        .s_status_depth_commit  (),
        .s_status_overflow      (),
        .s_status_bad_frame     (),
        .s_status_good_frame    (),

        // Read side — clk_300 domain
        .m_clk                  (clk_300),
        .m_rst                  (rst_300),
        .m_axis_tdata           (itch_300_tdata),
        .m_axis_tkeep           (itch_300_tkeep),
        .m_axis_tvalid          (itch_300_tvalid),
        .m_axis_tready          (itch_300_tready),
        .m_axis_tlast           (itch_300_tlast),
        .m_axis_tid             (),
        .m_axis_tdest           (),
        .m_axis_tuser           (),
        .m_pause_req            (1'b0),
        .m_pause_ack            (),
        .m_status_depth         (),
        .m_status_depth_commit  (),
        .m_status_overflow      (),
        .m_status_bad_frame     (),
        .m_status_good_frame    ()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // Expose ITCH-valid to top level for SVA latency assertions.
    // itch_300_tvalid is now sourced from the real FIFO read-side output.
    assign fifo_rd_tvalid = itch_300_tvalid;
    // tkeep is not forwarded to itch_parser (no byte-enable on ITCH stream)
    /* verilator lint_off UNUSED */
    logic _unused_tkeep_300;
    assign _unused_tkeep_300 = &itch_300_tkeep;
    /* verilator lint_on UNUSED */
`else
    // Hardware path: axis_async_fifo also instantiated here (same parameters).
    // Not compiled by Verilator without KINTEX7_SIM_GTX_BYPASS.
    assign fifo_almost_full  = 1'b0;
    /* verilator lint_off UNUSEDSIGNAL */
    assign fifo_s_depth      = 8'b0;
    /* verilator lint_on UNUSEDSIGNAL */
    assign itch_300_tdata    = '0;
    assign itch_300_tkeep    = '0;
    assign itch_300_tvalid   = 1'b0;
    assign itch_300_tlast    = 1'b0;
    assign itch_net_tready   = 1'b0;
`endif

    // 2-stage FF re-sample of clk_156 monitoring counters into clk_300
    logic [31:0] dropped_frames_s0,    dropped_frames_300;
    logic [31:0] dropped_dgrams_s0,    dropped_datagrams_300;
    logic [63:0] expected_seq_num_s0,  expected_seq_num_300;

    always_ff @(posedge clk_300) begin
        dropped_frames_s0    <= dropped_frames_156;
        dropped_dgrams_s0    <= dropped_datagrams_156;
        expected_seq_num_s0  <= expected_seq_num_156;
    end
    always_ff @(posedge clk_300) begin
        dropped_frames_300   <= dropped_frames_s0;
        dropped_datagrams_300 <= dropped_dgrams_s0;
        expected_seq_num_300 <= expected_seq_num_s0;
    end

    // ==================================================================
    // clk_300 domain: lliu_top_v2 — v2.0 ITCH→inference→OUCH pipeline
    // ==================================================================

    // Byte-reversal: axis_async_fifo output (little-endian, byte 0→tdata[7:0])
    // → itch_parser_v2 inside lliu_top_v2 expects big-endian (byte 0→tdata[63:56]).
    assign itch_300_tdata_swapped = {
        itch_300_tdata[ 7: 0], itch_300_tdata[15: 8],
        itch_300_tdata[23:16], itch_300_tdata[31:24],
        itch_300_tdata[39:32], itch_300_tdata[47:40],
        itch_300_tdata[55:48], itch_300_tdata[63:56]
    };

    lliu_top_v2 u_lliu (
        .clk            (clk_300),
        .rst            (rst_300),

        // ITCH ingress (byte-swapped to big-endian)
        .s_axis_tdata   (itch_300_tdata_swapped),
        .s_axis_tvalid  (itch_300_tvalid),
        .s_axis_tready  (itch_300_tready),
        .s_axis_tlast   (itch_300_tlast),

        // OUCH 5.0 egress
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tkeep   (m_axis_tkeep),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tready  (m_axis_tready),

        // AXI4-Lite control (12-bit byte addresses)
        .s_axil_awaddr  (axil_awaddr),
        .s_axil_awvalid (axil_awvalid),
        .s_axil_awready (axil_awready),
        .s_axil_wdata   (axil_wdata),
        .s_axil_wstrb   (axil_wstrb),
        .s_axil_wvalid  (axil_wvalid),
        .s_axil_wready  (axil_wready),
        .s_axil_bresp   (axil_bresp),
        .s_axil_bvalid  (axil_bvalid),
        .s_axil_bready  (axil_bready),
        .s_axil_araddr  (axil_araddr),
        .s_axil_arvalid (axil_arvalid),
        .s_axil_arready (axil_arready),
        .s_axil_rdata   (axil_rdata),
        .s_axil_rresp   (axil_rresp),
        .s_axil_rvalid  (axil_rvalid),
        .s_axil_rready  (axil_rready),

        .collision_count_out (collision_count_out),
        .tx_overflow_out     (tx_overflow_out),

        // BBO snapshot interface → pcie_dma_engine
        .snap_req            (snap_req_w),
        .snap_data           (snap_data_w),
        .snap_valid          (snap_valid_w),
        .snap_ready          (snap_ready_w),
        .snap_done           (snap_done_w)
    );

    // ==================================================================
    // PCIe DMA engine — periodic BBO snapshot to host
    // ==================================================================
    logic        snap_req_w;
    logic [63:0] snap_data_w;
    logic        snap_valid_w;
    logic        snap_ready_w;
    logic        snap_done_w;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        dma_active_w;
    logic        dma_err_w;
    /* verilator lint_on UNUSEDSIGNAL */

    pcie_dma_engine u_pcie_dma (
        .sys_clk    (clk_300),
        .sys_rst    (rst_300),
        .pcie_clk_p (pcie_clk_p),
        .pcie_clk_n (pcie_clk_n),
        .pcie_rst_n (pcie_rst_n),
        .pcie_rxp   (pcie_rxp),
        .pcie_rxn   (pcie_rxn),
        .pcie_txp   (pcie_txp),
        .pcie_txn   (pcie_txn),
        .snap_req   (snap_req_w),
        .snap_data  (snap_data_w),
        .snap_valid (snap_valid_w),
        .snap_ready (snap_ready_w),
        .snap_done  (snap_done_w),
        .dma_active (dma_active_w),
        .dma_err    (dma_err_w)
    );

    // Route clk_156 monitoring counters (CDC-resampled into clk_300) to outputs.
    assign dropped_frames_out    = dropped_frames_300;
    assign dropped_datagrams_out = dropped_datagrams_300;
    assign expected_seq_num_out  = expected_seq_num_300;

endmodule

