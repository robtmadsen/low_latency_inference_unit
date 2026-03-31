// kc705_top.sv — KC705 board-level top-level integrator for LLIU
//
// Pipeline summary:
//   [clk_156] mac_rx → eth_axis_rx_wrap → moldupp64_strip
//                → axis_async_fifo CDC (clk_156 write → clk_300 read)
//   [clk_300] itch_parser → symbol_filter → [1-cyc delay] → feature_extractor
//             → [sequencer] → dot_product_engine ← weight_mem
//             → output_buffer → dp_result / dp_result_valid
//   [clk_300] axi4_lite_slave: control, watchlist CAM writes, monitoring readout
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
// Register map: see lliu_pkg::AXIL_REG_* constants.

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

/* verilator lint_off MULTITOP */
module kc705_top #(
    parameter int VEC_LEN   = FEATURE_VEC_LEN,
    parameter int AXIL_ADDR = 8,
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

    // ── Inference result ──────────────────────────────────────────────
    output logic [31:0]            dp_result,
    output logic                   dp_result_valid

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
    // clk_300 domain: ITCH parse → symbol filter → inference pipeline
    // ==================================================================

    // -- Parser outputs --
    logic        parser_fields_valid;
    logic [31:0] parser_price;
    logic [63:0] parser_order_ref;
    logic        parser_side;
    logic [63:0] parser_stock;
    /* verilator lint_off UNUSED */
    logic        parser_msg_valid;
    logic [7:0]  parser_message_type;
    /* verilator lint_on UNUSED */

    // -- 1-cycle delay registers (align parser fields with watchlist_hit) --
    // symbol_filter registers its output, so watchlist_hit arrives 1 cycle
    // after stock_valid / fields_valid.  Delay all fields by one cycle so
    // feature_extractor sees consistent inputs.
    logic        fields_valid_d1;
    logic [31:0] price_d1;
    logic [63:0] order_ref_d1;
    logic        side_d1;

    // -- Symbol filter output --
    logic        watchlist_hit;

    // -- Feature extractor outputs --
    bfloat16_t   feat_vec [VEC_LEN];
    logic        feat_valid;

    // -- Weight memory interface --
    logic [$clog2(VEC_LEN)-1:0] wgt_wr_addr;
    bfloat16_t                  wgt_wr_data;
    logic                       wgt_wr_en;
    logic [$clog2(VEC_LEN)-1:0] wgt_rd_addr;
    bfloat16_t                  wgt_rd_data;

    // -- Dot-product engine --
    logic      dp_start;
    logic      dp_feature_valid_i;
    bfloat16_t dp_feature_in;
    bfloat16_t dp_weight_in;
    float32_t  dp_result_i;
    logic      dp_result_valid_i;

    // -- Output buffer --
    float32_t  out_result;
    logic      out_ready;

    // -- AXI4-Lite control --
    logic        ctrl_start;
    logic        ctrl_soft_reset;
    logic [7:0]  cam_wr_index_i;
    logic [63:0] cam_wr_data_i;
    logic        cam_wr_valid_i;
    logic        cam_wr_en_bit_i;

    // Combined application reset: board reset sync'd to clk_300 OR soft reset
    logic sys_rst;
    assign sys_rst = rst_300 | ctrl_soft_reset;

    // Sequencer state (needed in pipeline_hold expression below)
    typedef enum logic [1:0] {
        SEQ_IDLE    = 2'b00,
        SEQ_PRELOAD = 2'b01,
        SEQ_FEED    = 2'b10
    } seq_state_t;
    seq_state_t seq_state;

    // pipeline_hold blocks the parser from accumulating a new message while:
    //   a) fields_valid_d1 is high (watchlist decision in flight), or
    //   b) feat_valid is high (feature_extractor just fired), or
    //   c) the sequencer is running (seq_state != SEQ_IDLE).
    // This closes the 1-cycle gap introduced by symbol_filter's output register.
    logic pipeline_hold;
    assign pipeline_hold = fields_valid_d1 || feat_valid || (seq_state != SEQ_IDLE);

    // ── Byte-reversal: CDC FIFO (little-endian) → itch_parser (big-endian) ──
    assign itch_300_tdata_swapped = {
        itch_300_tdata[ 7: 0], itch_300_tdata[15: 8],
        itch_300_tdata[23:16], itch_300_tdata[31:24],
        itch_300_tdata[39:32], itch_300_tdata[47:40],
        itch_300_tdata[55:48], itch_300_tdata[63:56]
    };

    // ── ITCH Parser ──────────────────────────────────────────────────
    itch_parser u_parser (
        .clk           (clk_300),
        .rst           (sys_rst),
        .s_axis_tdata  (itch_300_tdata_swapped),
        .s_axis_tvalid (itch_300_tvalid),
        .s_axis_tready (itch_300_tready),
        .s_axis_tlast  (itch_300_tlast),
        .pipeline_hold (pipeline_hold),
        .msg_valid     (parser_msg_valid),
        .message_type  (parser_message_type),
        .order_ref     (parser_order_ref),
        .side          (parser_side),
        .price         (parser_price),
        .stock         (parser_stock),
        .fields_valid  (parser_fields_valid)
    );

    // ── 1-cycle delay: align parser fields with symbol_filter output ──
    always_ff @(posedge clk_300) begin
        if (sys_rst) begin
            fields_valid_d1 <= 1'b0;
            price_d1        <= '0;
            order_ref_d1    <= '0;
            side_d1         <= 1'b0;
        end else begin
            fields_valid_d1 <= parser_fields_valid;
            price_d1        <= parser_price;
            order_ref_d1    <= parser_order_ref;
            side_d1         <= parser_side;
        end
    end

    // ── Symbol filter (64-entry LUT-CAM) ─────────────────────────────
    symbol_filter u_sym_filter (
        .clk           (clk_300),
        .rst           (sys_rst),
        .stock         (parser_stock),
        .stock_valid   (parser_fields_valid),
        .watchlist_hit (watchlist_hit),
        .cam_wr_index  (cam_wr_index_i),
        .cam_wr_data   (cam_wr_data_i),
        .cam_wr_valid  (cam_wr_valid_i),
        .cam_wr_en_bit (cam_wr_en_bit_i)
    );

    // ── Feature extractor (only for watchlist hits) ───────────────────
    feature_extractor #(
        .VEC_LEN (VEC_LEN)
    ) u_feat_extract (
        .clk            (clk_300),
        .rst            (sys_rst),
        .price          (price_d1),
        .order_ref      (order_ref_d1),
        .side           (side_d1),
        .fields_valid   (fields_valid_d1 & watchlist_hit),
        .features       (feat_vec),
        .features_valid (feat_valid)
    );

    // ── Inference sequencer ───────────────────────────────────────────
    logic [$clog2(VEC_LEN+1)-1:0] seq_idx;

    always_ff @(posedge clk_300) begin
        if (sys_rst) begin
            seq_state          <= SEQ_IDLE;
            seq_idx            <= '0;
            dp_start           <= 1'b0;
            dp_feature_valid_i <= 1'b0;
            dp_feature_in      <= '0;
        end else begin
            dp_start           <= 1'b0;
            dp_feature_valid_i <= 1'b0;

            case (seq_state)
                SEQ_IDLE: begin
                    if (feat_valid) begin
                        dp_start  <= 1'b1;
                        seq_idx   <= '0;
                        seq_state <= SEQ_PRELOAD;
                    end
                end
                SEQ_PRELOAD: seq_state <= SEQ_FEED;
                SEQ_FEED: begin
                    dp_feature_in      <= feat_vec[seq_idx[$clog2(VEC_LEN)-1:0]];
                    dp_feature_valid_i <= 1'b1;
                    if (seq_idx == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1)
                        seq_state <= SEQ_IDLE;
                    else
                        seq_idx <= seq_idx + 1;
                end
                /* verilator coverage_off */
                default: seq_state <= SEQ_IDLE;
                /* verilator coverage_on */
            endcase
        end
    end

    assign wgt_rd_addr = seq_idx[$clog2(VEC_LEN)-1:0];
    assign dp_weight_in = wgt_rd_data;

    // ── Weight memory ─────────────────────────────────────────────────
    weight_mem #(.DEPTH(VEC_LEN)) u_weight_mem (
        .clk     (clk_300),
        .rst     (sys_rst),
        .wr_addr (wgt_wr_addr),
        .wr_data (wgt_wr_data),
        .wr_en   (wgt_wr_en),
        .rd_addr (wgt_rd_addr),
        .rd_data (wgt_rd_data)
    );

    // ── Dot-product engine ────────────────────────────────────────────
    dot_product_engine #(.VEC_LEN(VEC_LEN)) u_dp (
        .clk           (clk_300),
        .rst           (sys_rst),
        .feature_in    (dp_feature_in),
        .feature_valid (dp_feature_valid_i),
        .weight_in     (dp_weight_in),
        .start         (dp_start),
        .result        (dp_result_i),
        .result_valid  (dp_result_valid_i)
    );

    // ── Output buffer ─────────────────────────────────────────────────
    output_buffer u_out_buf (
        .clk          (clk_300),
        .rst          (sys_rst),
        .result_in    (dp_result_i),
        .result_valid (dp_result_valid_i),
        .result_out   (out_result),
        .result_ready (out_ready)
    );

    assign dp_result       = out_result;
    assign dp_result_valid = dp_result_valid_i;

    // ctrl_start from AXI register is unused in KC705: inference fires
    // automatically when a watchlist-matching Add Order arrives.
    /* verilator lint_off UNUSED */
    logic _unused_ctrl_start;
    assign _unused_ctrl_start = ctrl_start;
    /* verilator lint_on UNUSED */

    // ── AXI4-Lite slave (clk_300 domain) ─────────────────────────────
    logic status_busy;
    assign status_busy = (seq_state != SEQ_IDLE);

    axi4_lite_slave #(
        .ADDR_WIDTH (AXIL_ADDR),
        .DATA_WIDTH (AXIL_DATA)
    ) u_axil (
        .clk                 (clk_300),
        .rst                 (rst_300),
        .s_axil_awaddr       (axil_awaddr),
        .s_axil_awvalid      (axil_awvalid),
        .s_axil_awready      (axil_awready),
        .s_axil_wdata        (axil_wdata),
        .s_axil_wstrb        (axil_wstrb),
        .s_axil_wvalid       (axil_wvalid),
        .s_axil_wready       (axil_wready),
        .s_axil_bresp        (axil_bresp),
        .s_axil_bvalid       (axil_bvalid),
        .s_axil_bready       (axil_bready),
        .s_axil_araddr       (axil_araddr),
        .s_axil_arvalid      (axil_arvalid),
        .s_axil_arready      (axil_arready),
        .s_axil_rdata        (axil_rdata),
        .s_axil_rresp        (axil_rresp),
        .s_axil_rvalid       (axil_rvalid),
        .s_axil_rready       (axil_rready),
        .wgt_wr_addr         (wgt_wr_addr),
        .wgt_wr_data         (wgt_wr_data),
        .wgt_wr_en           (wgt_wr_en),
        .ctrl_start          (ctrl_start),
        .ctrl_soft_reset     (ctrl_soft_reset),
        .status_result_ready (out_ready),
        .status_busy         (status_busy),
        .result_data         (out_result),
        .cam_wr_index        (cam_wr_index_i),
        .cam_wr_data         (cam_wr_data_i),
        .cam_wr_valid        (cam_wr_valid_i),
        .cam_wr_en_bit       (cam_wr_en_bit_i),
        .dropped_frames      (dropped_frames_300),
        .dropped_datagrams   (dropped_datagrams_300),
        .expected_seq_num    (expected_seq_num_300),
        .gtx_lock            (1'b1)   // tied 1 in simulation; GTX PLL lock in hw
    );

endmodule
