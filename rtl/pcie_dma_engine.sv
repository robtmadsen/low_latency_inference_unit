// pcie_dma_engine.sv — PCIe Gen2 ×4 DMA engine for LLIU v2.0 Phase 3
//
// Periodically (every 10 ms) DMA's the 8 KB order-book BBO snapshot to a
// pinned host buffer, and exposes AXI4-Lite control registers via BAR0.
//
// ── Architecture ───────────────────────────────────────────────────────────
//
//  pcie_7x_0 (Vivado IP, user_clk = 250 MHz)
//      ↕ AXI4-S TLP streams (s_axis_tx / m_axis_rx)
//  TLP Generator / BAR0 Decoder  (user_clk domain)
//      ↑ data from staging_mem read port (user_clk)
//  staging_mem (RAMB36E1 SDP, dual-clock)
//      ↑ writes from snapshot_mux (sys_clk domain)
//  snapshot_mux interface        (sys_clk domain)
//
//  CDC crossings:
//    sys_clk → user_clk : snap_done    (two-flop pulse stretch + sync)
//    user_clk → sys_clk : snap_req     (two-flop pulse stretch + sync)
//
// ── pcie_7x_0 instantiation ────────────────────────────────────────────────
//
//  The Xilinx "7 Series FPGAs Integrated Block for PCI Express" IP (pcie_7x_0)
//  must be generated from the Vivado IP Catalog before synthesis:
//
//    IP Settings:
//      Lane Width      : X4
//      Link Speed      : 5.0 GT/s (Gen2)
//      Reference Clock : 100 MHz
//      AXI Data Width  : 64-bit
//      Base Address    : BAR0 = 32-bit, 4 KB (non-prefetchable)
//
//    Tcl (run in Vivado after project creation):
//      create_ip -name pcie_7x_0 -vendor xilinx.com -library ip
//      set_property CONFIG.Bar0_Scale Kilobytes [get_ips pcie_7x_0]
//      set_property CONFIG.Bar0_Size 4          [get_ips pcie_7x_0]
//      generate_target all [get_ips pcie_7x_0]
//
// ── DMA descriptor ring ────────────────────────────────────────────────────
//
//  256-entry ring in a RAMB36E1.  Each descriptor = 96 bits:
//    [95:32] host_addr [63:0]     — 64-bit PCIe host DMA target address
//    [31: 8] byte_len  [23:0]     — transfer length in bytes (≤ 8 192)
//    [    7] valid                — 1 = descriptor is armed
//    [ 6: 0] flags                — reserved (must be 0)
//
//  Host software populates descriptors by writing to BAR0 offsets:
//    BAR0 + 0x000 : CTRL   [0]=dma_en, [1]=hist_clear, [2]=kill_switch
//    BAR0 + 0x004 : STATUS [0]=dma_busy, [1]=link_up
//    BAR0 + 0x008 : DESC_WR_PTR  [7:0]  — descriptor ring write pointer
//    BAR0 + 0x00C : DESC_HOST_LO [31:0] — host_addr lower 32 bits (stage)
//    BAR0 + 0x010 : DESC_HOST_HI [31:0] — host_addr upper 32 bits (stage)
//    BAR0 + 0x014 : DESC_LEN     [23:0] — byte length; writing fires the entry
//
// ── TLP format ─────────────────────────────────────────────────────────────
//
//  Memory Write (64-bit address, 4DW header).  64-bit AXI bus (Xilinx byte
//  order: earlier DW in higher bits of 64-bit word):
//
//  Beat 0 tdata[63:32] = DW0 : {1'b0, fmt=3'b011, type=5'b0, TC=3'b0,
//                                4'b0, TD, EP, ATTR, AT, length[9:0]}
//  Beat 0 tdata[31: 0] = DW1 : {req_id[15:0], tag[7:0],
//                                last_be[3:0], first_be[3:0]}
//  Beat 1 tdata[63:32] = DW2 : host_addr[63:32]
//  Beat 1 tdata[31: 0] = DW3 : {host_addr[31:2], 2'b00}
//  Beat 2..N           = Data (DWORD-granular, 32 DW = 128 B per TLP)
//
//  One snapshot (8 000 B) → 63 TLPs (62 × 128 B + 1 × 64 B).

/* verilator lint_off IMPORTSTAR */
import lliu_pkg::*;
/* verilator lint_on IMPORTSTAR */

/* verilator lint_off MULTITOP */
module pcie_dma_engine (
    // ── System clock domain (312.5 MHz) ──────────────────────────────────
    input  logic        sys_clk,
    input  logic        sys_rst,

    // ── PCIe physical interface ───────────────────────────────────────────
    // 100 MHz LVDS reference clock from board (connect via IBUFDS_GTE2 in top)
    input  logic        pcie_clk_p,
    input  logic        pcie_clk_n,
    // Active-low PCIe reset from edge connector (PERST#)
    input  logic        pcie_rst_n,
    // GTP lane pairs (Gen2, ×4)
    input  logic [3:0]  pcie_rxp,
    input  logic [3:0]  pcie_rxn,
    output logic [3:0]  pcie_txp,
    output logic [3:0]  pcie_txn,

    // ── Snapshot interface (sys_clk domain, from lliu_top_v2) ────────────
    output logic        snap_req,    // one-cycle pulse: start a snapshot
    input  logic [63:0] snap_data,   // 64-bit beat from snapshot_mux
    input  logic        snap_valid,  // beat is valid
    output logic        snap_ready,  // backpressure to snapshot_mux
    input  logic        snap_done,   // snapshot capture complete (1-cycle pulse)

    // ── Status (sys_clk domain) ───────────────────────────────────────────
    output logic        dma_active,  // DMA transfer in progress
    output logic        dma_err      // PCIe error (TX drop or link lost)
);

    // ==================================================================
    // pcie_7x_0 — Vivado-generated IP (declare signals; see header note)
    // The module is not instantiated at the RTL level here; it is added
    // to the synthesis design via the Vivado IP catalog and the .xci file.
    // Un-comment and fill in the instance below after IP generation.
    // ==================================================================

    // user_clk domain (250 MHz from PCIe IP)
    logic        user_clk;
    logic        user_rst;
    logic        user_lnk_up;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        user_app_rdy;
    /* verilator lint_on UNUSEDSIGNAL */

    // TX AXI4-S (FPGA → Host, user_clk)
    // These signals are driven by the DMA FSM and consumed by the pcie_7x_0 IP
    // (currently in a block comment pending Vivado IP generation).
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] ax_tx_tdata;
    logic [7:0]  ax_tx_tkeep;
    logic        ax_tx_tvalid;
    logic        ax_tx_tready;
    logic        ax_tx_tlast;
    logic [3:0]  ax_tx_tuser;   // [3]=discontinue [2]=streamed [1]=ecrc_en [0]=strobe
    /* verilator lint_on UNUSEDSIGNAL */

    // RX AXI4-S (Host → FPGA, user_clk) — used for BAR0 writes from host
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] ax_rx_tdata;
    logic [7:0]  ax_rx_tkeep;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        ax_rx_tvalid;
    logic        ax_rx_tready;
    logic        ax_rx_tlast;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [21:0] ax_rx_tuser;
    /* verilator lint_on UNUSEDSIGNAL */

    logic [5:0]  tx_buf_av;      // available TX descriptor buffers

    // PCIe configuration (used to fill requester_id in TLP headers)
    logic [7:0]  cfg_bus_number;
    logic [4:0]  cfg_device_number;
    logic [2:0]  cfg_function_number;

    /*
    //  ── Un-comment after IP generation ────────────────────────────────
    logic pcie_refclk;
    IBUFDS_GTE2 u_refclk_buf (
        .I   (pcie_clk_p), .IB (pcie_clk_n),
        .CEB (1'b0),
        .O   (pcie_refclk), .ODIV2 ()
    );

    pcie_7x_0 u_pcie (
        .sys_clk                (pcie_refclk),
        .sys_rst_n              (pcie_rst_n),
        .pci_exp_txp            (pcie_txp),
        .pci_exp_txn            (pcie_txn),
        .pci_exp_rxp            (pcie_rxp),
        .pci_exp_rxn            (pcie_rxn),

        .user_clk_out           (user_clk),
        .user_reset_out         (user_rst),
        .user_lnk_up            (user_lnk_up),
        .user_app_rdy           (user_app_rdy),

        .s_axis_tx_tdata        (ax_tx_tdata),
        .s_axis_tx_tkeep        (ax_tx_tkeep),
        .s_axis_tx_tvalid       (ax_tx_tvalid),
        .s_axis_tx_tready       (ax_tx_tready),
        .s_axis_tx_tlast        (ax_tx_tlast),
        .s_axis_tx_tuser        (ax_tx_tuser),
        .tx_buf_av              (tx_buf_av),
        .tx_err_drop            (),
        .tx_cfg_req             (),
        .tx_cfg_gnt             (1'b1),

        .m_axis_rx_tdata        (ax_rx_tdata),
        .m_axis_rx_tkeep        (ax_rx_tkeep),
        .m_axis_rx_tvalid       (ax_rx_tvalid),
        .m_axis_rx_tready       (ax_rx_tready),
        .m_axis_rx_tlast        (ax_rx_tlast),
        .m_axis_rx_tuser        (ax_rx_tuser),

        .cfg_bus_number         (cfg_bus_number),
        .cfg_device_number      (cfg_device_number),
        .cfg_function_number    (cfg_function_number),
        .cfg_status             (),
        .cfg_command            (),
        .cfg_dstatus            (),
        .cfg_dcommand           (),
        .fc_ph                  (),
        .fc_pd                  (),
        .fc_nph                 (),
        .fc_npd                 (),
        .fc_cplh                (),
        .fc_cpld                (),
        .fc_sel                 (3'b000)
    );
    */

    // Simulation stubs (replaced by pcie_7x_0 in synthesis)
    /* verilator lint_off UNUSED */
    logic [3:0] pcie_rxp_w; assign pcie_rxp_w = pcie_rxp;
    logic [3:0] pcie_rxn_w; assign pcie_rxn_w = pcie_rxn;
    logic       pcie_clk_p_w; assign pcie_clk_p_w = pcie_clk_p;
    logic       pcie_clk_n_w; assign pcie_clk_n_w = pcie_clk_n;
    logic       pcie_rst_n_w; assign pcie_rst_n_w = pcie_rst_n;
    /* verilator lint_on UNUSED */
    assign pcie_txp = 4'h0;
    assign pcie_txn = 4'hF;

    // Drive stubs for user_clk domain (simulation only)
    assign user_clk     = sys_clk;    // use sys_clk as surrogate in sim
    assign user_rst     = sys_rst;
    assign user_lnk_up  = 1'b1;
    assign user_app_rdy = 1'b1;
    assign ax_tx_tready = 1'b1;
    assign ax_rx_tdata  = 64'h0;
    assign ax_rx_tkeep  = 8'h0;
    assign ax_rx_tvalid = 1'b0;
    assign ax_rx_tlast  = 1'b0;
    assign ax_rx_tuser  = 22'h0;
    assign tx_buf_av    = 6'h3F;
    assign cfg_bus_number      = 8'h0;
    assign cfg_device_number   = 5'h0;
    assign cfg_function_number = 3'h0;

    // ==================================================================
    // Staging buffer: dual-clock SDP BRAM (sys_clk write, user_clk read)
    //   Depth = 1 024, Width = 64 b → infers 2 × RAMB36E1
    //   Holds one complete snapshot (1 000 beats of 64 b = 8 000 B).
    // ==================================================================
    (* ram_style = "block" *) logic [63:0] staging_mem [0:1023];

    // ── Write side (sys_clk domain) ──────────────────────────────────────
    logic [9:0]  stg_wr_ptr;
    logic        capt_active_sys;   // snapshot capture in progress
    logic        capt_done_sys;     // snapshot fully captured (1-cycle pulse)

    assign snap_ready = capt_active_sys;  // accept beats while capturing

    always_ff @(posedge sys_clk) begin
        if (sys_rst) begin
            stg_wr_ptr     <= 10'h0;
            capt_active_sys <= 1'b0;
            capt_done_sys   <= 1'b0;
        end else begin
            capt_done_sys <= 1'b0;

            if (snap_req_sys_pulse) begin
                stg_wr_ptr      <= 10'h0;
                capt_active_sys <= 1'b1;
            end else if (capt_active_sys && snap_valid) begin
                staging_mem[stg_wr_ptr] <= snap_data;
                if (snap_done) begin
                    capt_active_sys <= 1'b0;
                    capt_done_sys   <= 1'b1;
                end else begin
                    stg_wr_ptr <= stg_wr_ptr + 10'h1;
                end
            end
        end
    end

    // ── Read side (user_clk domain) ──────────────────────────────────────
    logic [9:0]  stg_rd_ptr;
    logic [63:0] stg_rd_data;

    always_ff @(posedge user_clk) begin
        stg_rd_data <= staging_mem[stg_rd_ptr];
    end

    // ==================================================================
    // CDC: user_clk → sys_clk (snap_req)
    //   DMA engine stretches the trigger into a level; sys_clk detects edge.
    // ==================================================================
    logic snap_req_level_uc;     // user_clk domain: level toggle
    logic [1:0] snap_req_sync_sc; // sys_clk two-flop sync
    logic snap_req_prev_sc;
    logic snap_req_sys_pulse;    // sys_clk one-cycle pulse after edge

    always_ff @(posedge sys_clk) begin
        if (sys_rst) begin
            snap_req_sync_sc <= 2'b00;
            snap_req_prev_sc <= 1'b0;
            snap_req_sys_pulse <= 1'b0;
        end else begin
            snap_req_sync_sc <= {snap_req_sync_sc[0], snap_req_level_uc};
            snap_req_sys_pulse <= snap_req_sync_sc[1] & ~snap_req_prev_sc;
            snap_req_prev_sc   <= snap_req_sync_sc[1];
        end
    end

    assign snap_req = snap_req_sys_pulse;

    // ==================================================================
    // CDC: sys_clk → user_clk (capt_done)
    //   sys_clk generates a toggle on capt_done; user_clk detects edge.
    // ==================================================================
    logic capt_done_toggle_sc;  // sys_clk toggle register
    logic [1:0] capt_done_sync_uc;
    logic capt_done_prev_uc;
    logic capt_done_uc;         // user_clk one-cycle pulse

    always_ff @(posedge sys_clk) begin
        if (sys_rst)
            capt_done_toggle_sc <= 1'b0;
        else if (capt_done_sys)
            capt_done_toggle_sc <= ~capt_done_toggle_sc;
    end

    always_ff @(posedge user_clk) begin
        if (user_rst) begin
            capt_done_sync_uc <= 2'b00;
            capt_done_prev_uc <= 1'b0;
            capt_done_uc      <= 1'b0;
        end else begin
            capt_done_sync_uc <= {capt_done_sync_uc[0], capt_done_toggle_sc};
            capt_done_uc      <= capt_done_sync_uc[1] ^ capt_done_prev_uc;
            capt_done_prev_uc <= capt_done_sync_uc[1];
        end
    end

    // ==================================================================
    // Descriptor ring: 256 × 12 bytes in BRAM
    //   Entry [95:0]: {host_addr[63:0], byte_len[23:0], valid[0], flags[6:0]}
    //   Ports: single-clock (user_clk only — host writes via BAR0 RX TLP handler)
    // ==================================================================
    localparam int DESC_WIDTH = 96;

    (* ram_style = "block" *) logic [DESC_WIDTH-1:0] desc_ring [0:255];

    logic [7:0]  desc_rd_ptr;      // DMA consumer pointer (user_clk)
    /* verilator lint_off UNUSEDSIGNAL */
    logic [7:0]  desc_wr_ptr_r;    // host write pointer (written via BAR0)
    /* verilator lint_on UNUSEDSIGNAL */

    // Descriptor fields
    logic [63:0] desc_host_addr;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [23:0] desc_byte_len;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        desc_valid_bit;

    // Staging registers for BAR0 descriptor writes (host → FPGA via RX TLPs)
    logic [31:0] bar0_stage_host_lo;
    logic [31:0] bar0_stage_host_hi;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] bar0_ctrl_r;
    /* verilator lint_on UNUSEDSIGNAL */
    logic [7:0]  bar0_desc_wr_ptr;

    // Read descriptor (1-cycle BRAM latency)
    /* verilator lint_off UNUSEDSIGNAL */
    logic [DESC_WIDTH-1:0] desc_rd_data;
    /* verilator lint_on UNUSEDSIGNAL */
    always_ff @(posedge user_clk) begin
        desc_rd_data <= desc_ring[desc_rd_ptr];
    end

    assign desc_host_addr = desc_rd_data[95:32];
    assign desc_byte_len  = desc_rd_data[31:8];
    assign desc_valid_bit = desc_rd_data[7];

    // ==================================================================
    // BAR0 RX TLP handler (user_clk domain)
    //   Accepts Memory Write TLPs targeting BAR0 from the host.
    //   Decodes DW0-DW1 (header) and DW2 (data) to update registers.
    //
    //   Simplified: expects 3DW header + 1DW data (32-bit BAR0 address).
    //   Beat 0 → {DW0, DW1}   (header)
    //   Beat 1 → {bar0_addr[31:0], wdata[31:0]}
    //
    //   BAR0 decode:
    //     0x000 CTRL       [0]=dma_en [1]=hist_clear [2]=kill_switch
    //     0x008 DESC_WR_PTR  — write pointer for descriptor ring
    //     0x00C DESC_HOST_LO — host DMA address [31:0]
    //     0x010 DESC_HOST_HI — host DMA address [63:32]
    //     0x014 DESC_LEN    — byte length; triggers descriptor write to ring
    // ==================================================================
    typedef enum logic [1:0] {
        RX_IDLE  = 2'b00,
        RX_HDR1  = 2'b01,   // beat 0: {DW0,DW1}
        RX_DATA  = 2'b10    // beat 1: {bar0_addr_lo, wdata}
    } rx_state_t;

    rx_state_t rx_state;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0] rx_bar0_addr;
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge user_clk) begin
        if (user_rst) begin
            rx_state         <= RX_IDLE;
            rx_bar0_addr     <= 32'h0;
            bar0_ctrl_r      <= 32'h0;
            bar0_desc_wr_ptr <= 8'h0;
            bar0_stage_host_lo <= 32'h0;
            bar0_stage_host_hi <= 32'h0;
            desc_wr_ptr_r    <= 8'h0;
        end else begin
            case (rx_state)
                RX_IDLE: begin
                    if (ax_rx_tvalid & ax_rx_tready) begin
                        // DW0[28:24]=fmt/type: 3DW no data = 3'b000, type=5'b0
                        // MWr 3DW = fmt=3'b010; MWr 4DW = fmt=3'b011
                        // We accept any 64-bit read but latch only MWr to BAR0
                        rx_state <= ax_rx_tlast ? RX_IDLE : RX_HDR1;
                    end
                end
                RX_HDR1: begin
                    // beat 0 on 64-bit bus: tdata[63:32]=DW0, tdata[31:0]=DW1
                    // For a 3DW MWr header, beat 1 carries {addr_lo[31:2],2'b0, data[31:0]}
                    if (ax_rx_tvalid & ax_rx_tready) begin
                        rx_bar0_addr <= ax_rx_tdata[31:0]; // DW1 for 3DW = addr_lo
                        rx_state <= RX_DATA;
                    end
                end
                RX_DATA: begin
                    if (ax_rx_tvalid & ax_rx_tready) begin
                        // ax_rx_tdata[63:32] = bar0 word address or data continuation
                        // ax_rx_tdata[31: 0] = write data
                        begin : bar0_decode
                            automatic logic [31:0] wdata = ax_rx_tdata[31:0];
                            automatic logic [11:0] addr  = rx_bar0_addr[11:0];
                            case (addr)
                                12'h000: bar0_ctrl_r      <= wdata;
                                12'h008: bar0_desc_wr_ptr <= wdata[7:0];
                                12'h00C: bar0_stage_host_lo <= wdata;
                                12'h010: bar0_stage_host_hi <= wdata;
                                12'h014: begin
                                    // Arm a descriptor in the ring
                                    desc_ring[bar0_desc_wr_ptr] <= {
                                        bar0_stage_host_hi,
                                        bar0_stage_host_lo,
                                        wdata[23:0],    // byte_len
                                        1'b1,           // valid
                                        7'h0            // flags
                                    };
                                    desc_wr_ptr_r <= bar0_desc_wr_ptr;
                                end
                                default: ;
                            endcase
                        end
                        rx_state <= ax_rx_tlast ? RX_IDLE : RX_DATA;
                    end
                end
                default: rx_state <= RX_IDLE;
            endcase
        end
    end

    assign ax_rx_tready = 1'b1;  // always accept RX TLPs

    // ==================================================================
    // 10 ms periodic timer (user_clk = 250 MHz → 2 500 000 cycles)
    // ==================================================================
    localparam int TIMER_PERIOD_UC = 2_500_000;

    logic [21:0] periodic_timer;
    logic        periodic_tick;

    always_ff @(posedge user_clk) begin
        if (user_rst) begin
            periodic_timer <= 22'h0;
            periodic_tick  <= 1'b0;
        end else begin
            periodic_tick <= 1'b0;
            if (periodic_timer == 22'(TIMER_PERIOD_UC - 1)) begin
                periodic_timer <= 22'h0;
                periodic_tick  <= 1'b1;
            end else begin
                periodic_timer <= periodic_timer + 22'h1;
            end
        end
    end

    // ==================================================================
    // DMA state machine (user_clk domain)
    //
    //  DMA_IDLE     : wait for periodic_tick (and dma_en=1)
    //  DMA_TRIG     : toggle snap_req_level to request snapshot from sys_clk
    //  DMA_CAPT_WAIT: wait for capt_done_uc (staging BRAM fully populated)
    //  DMA_DESCR    : read descriptor from ring; advance rd_ptr
    //  DMA_DESCR_LAT: 1-cycle BRAM read latency
    //  DMA_TLP      : generate TLP headers + stream data beats from staging
    //
    // TLP payload granularity: 32 DW = 128 bytes per TLP.
    //  8 000 B → 62 TLPs of 128 B + 1 TLP of 64 B (16 DW).
    // ==================================================================
    localparam int TLP_PAYLOAD_DW  = 32;    // 128 bytes per TLP
    localparam int TLP_PAYLOAD_B   = TLP_PAYLOAD_DW * 4;  // 128
    localparam int SNAP_BEATS      = 1000;  // total 64-bit beats in snapshot
    localparam int FULL_TLPS       = (SNAP_BEATS * 8) / TLP_PAYLOAD_B;  // 62
    localparam int LAST_TLP_BEATS  = SNAP_BEATS - FULL_TLPS * (TLP_PAYLOAD_DW / 2); // 8

    typedef enum logic [2:0] {
        DMA_IDLE      = 3'b000,
        DMA_TRIG      = 3'b001,
        DMA_CAPT_WAIT = 3'b010,
        DMA_DESCR     = 3'b011,
        DMA_DESCR_LAT = 3'b100,
        DMA_TLP       = 3'b101
    } dma_state_t;

    dma_state_t dma_state;

    // Current transfer tracking
    logic [63:0] dma_host_addr;    // base address for this snapshot
    logic [9:0]  tlp_beat_cnt;     // beats sent in current TLP (header + data)
    logic [9:0]  stg_rd_ptr_r;     // staging buffer read pointer
    logic [6:0]  tlp_num;          // which TLP within this snapshot (0..62)
    logic [15:0] req_id;

    assign req_id = {cfg_bus_number, cfg_device_number, cfg_function_number};

    // DMA active status (cross to sys_clk with two-flop sync in status register)
    logic dma_busy_uc;

    always_ff @(posedge user_clk) begin
        if (user_rst) begin
            dma_state          <= DMA_IDLE;
            snap_req_level_uc  <= 1'b0;
            desc_rd_ptr        <= 8'h0;
            stg_rd_ptr         <= 10'h0;
            stg_rd_ptr_r       <= 10'h0;
            tlp_beat_cnt       <= 10'h0;
            tlp_num            <= 7'h0;
            dma_host_addr      <= 64'h0;
            ax_tx_tdata        <= 64'h0;
            ax_tx_tkeep        <= 8'h0;
            ax_tx_tvalid       <= 1'b0;
            ax_tx_tlast        <= 1'b0;
            ax_tx_tuser        <= 4'h0;
            dma_busy_uc        <= 1'b0;
        end else begin
            ax_tx_tvalid <= 1'b0;  // default
            ax_tx_tlast  <= 1'b0;

            case (dma_state)
                // ── Idle ──────────────────────────────────────────────
                DMA_IDLE: begin
                    dma_busy_uc <= 1'b0;
                    if (periodic_tick && bar0_ctrl_r[0] && user_lnk_up) begin
                        dma_state <= DMA_TRIG;
                    end
                end

                // ── Request snapshot ──────────────────────────────────
                DMA_TRIG: begin
                    // Toggle the level to generate an edge in sys_clk domain
                    snap_req_level_uc <= ~snap_req_level_uc;
                    dma_state         <= DMA_CAPT_WAIT;
                    dma_busy_uc       <= 1'b1;
                end

                // ── Wait for staging BRAM to fill ─────────────────────
                DMA_CAPT_WAIT: begin
                    if (capt_done_uc) begin
                        desc_rd_ptr <= desc_rd_ptr; // hold; read via DESCR
                        dma_state   <= DMA_DESCR;
                    end
                end

                // ── Load descriptor ──────────────────────────────────
                DMA_DESCR: begin
                    // Issue BRAM read for current desc_rd_ptr
                    dma_state    <= DMA_DESCR_LAT;
                end

                DMA_DESCR_LAT: begin
                    // BRAM output (desc_rd_data) now valid
                    if (!desc_valid_bit) begin
                        // Descriptor not armed — skip transfer, go idle
                        dma_state <= DMA_IDLE;
                    end else begin
                        dma_host_addr <= desc_host_addr;
                        stg_rd_ptr    <= 10'h0;
                        stg_rd_ptr_r  <= 10'h0;
                        tlp_beat_cnt  <= 10'h0;
                        tlp_num       <= 7'h0;
                        dma_state     <= DMA_TLP;
                    end
                end

                // ── Stream TLPs ───────────────────────────────────────
                // Each TLP: 2 header beats + 16 data beats (or 8 for last TLP)
                // Beat 0 (tlp_beat_cnt=0): TLP header DW0+DW1
                // Beat 1 (tlp_beat_cnt=1): TLP header DW2+DW3 (address)
                // Beat 2..N (tlp_beat_cnt≥2): data from staging_mem
                DMA_TLP: begin
                    if (!ax_tx_tready || tx_buf_av == 6'h0)
                        ; // stall
                    else begin
                        automatic logic is_last_tlp;
                        automatic logic [9:0] cur_tlp_data_beats;
                        automatic logic [9:0] tlp_length_dw;
                        /* verilator lint_off UNUSEDSIGNAL */
                        automatic logic [63:0] tlp_host_addr;
                        /* verilator lint_on UNUSEDSIGNAL */

                        is_last_tlp = (tlp_num == 7'(FULL_TLPS));
                        cur_tlp_data_beats = is_last_tlp
                            ? 10'(LAST_TLP_BEATS)
                            : 10'(TLP_PAYLOAD_DW / 2);  // 16 beats for 32 DW
                        tlp_length_dw = is_last_tlp
                            ? 10'(LAST_TLP_BEATS * 2)   // 16 DW
                            : 10'(TLP_PAYLOAD_DW);       // 32 DW
                        tlp_host_addr = dma_host_addr +
                            64'(tlp_num) * TLP_PAYLOAD_B;

                        ax_tx_tvalid <= 1'b1;
                        ax_tx_tuser  <= 4'b0000;

                        case (tlp_beat_cnt)
                            10'h0: begin
                                // Beat 0: DW0 (MWr 64-bit, 4DW header) + DW1
                                // DW0: fmt=3'b011 (4DW+data), type=5'b0, len
                                ax_tx_tdata <= {
                                    3'b011, 5'b0_0000,         // fmt/type MWr64
                                    1'b0, 3'b000,              // T9, TC
                                    1'b0, 1'b0, 1'b0, 1'b0,   // T8,attr,LN,TH
                                    1'b0, 1'b0, 2'b00, 2'b00, // TD EP ATTR AT
                                    tlp_length_dw,             // LENGTH [9:0]
                                    req_id,                    // DW1: requester ID
                                    8'h00,                     // tag
                                    4'hF,                      // last_dw_be
                                    4'hF                       // first_dw_be
                                };
                                ax_tx_tkeep <= 8'hFF;
                                ax_tx_tlast <= 1'b0;
                                tlp_beat_cnt <= tlp_beat_cnt + 10'h1;
                            end

                            10'h1: begin
                                // Beat 1: DW2 (addr[63:32]) + DW3 (addr[31:2], 2'b00)
                                ax_tx_tdata <= {
                                    tlp_host_addr[63:32],
                                    tlp_host_addr[31:2], 2'b00
                                };
                                ax_tx_tkeep  <= 8'hFF;
                                ax_tx_tlast  <= 1'b0;
                                // Issue first staging BRAM read
                                stg_rd_ptr   <= stg_rd_ptr_r;
                                tlp_beat_cnt <= tlp_beat_cnt + 10'h1;
                            end

                            default: begin
                                // Data beats: one staging_mem entry per beat
                                // stg_rd_data is the result of the PREVIOUS cycle's read.
                                // We read ahead by 1 cycle in tlp_beat_cnt=1.
                                automatic logic [9:0] data_idx;
                                data_idx = tlp_beat_cnt - 10'h2;

                                ax_tx_tdata  <= stg_rd_data;
                                ax_tx_tkeep  <= 8'hFF;

                                // Issue next BRAM read (prefetch for next beat)
                                if (data_idx + 10'h1 < cur_tlp_data_beats)
                                    stg_rd_ptr <= stg_rd_ptr_r + (data_idx + 10'h1);

                                // Last data beat of this TLP?
                                if (data_idx == cur_tlp_data_beats - 10'h1) begin
                                    ax_tx_tlast  <= 1'b1;
                                    tlp_beat_cnt <= 10'h0;

                                    if (is_last_tlp) begin
                                        // All TLPs sent: invalidate descriptor and go idle
                                        desc_ring[desc_rd_ptr][7] <= 1'b0;
                                        desc_rd_ptr  <= desc_rd_ptr + 8'h1;
                                        dma_busy_uc  <= 1'b0;
                                        dma_state    <= DMA_IDLE;
                                    end else begin
                                        tlp_num      <= tlp_num + 7'h1;
                                        stg_rd_ptr_r <= stg_rd_ptr_r +
                                            10'(TLP_PAYLOAD_DW / 2);
                                    end
                                end else begin
                                    tlp_beat_cnt <= tlp_beat_cnt + 10'h1;
                                end
                            end
                        endcase
                    end
                end

                default: dma_state <= DMA_IDLE;
            endcase
        end
    end

    // ==================================================================
    // Status outputs — cross dma_busy to sys_clk domain
    // ==================================================================
    logic [1:0] dma_busy_sync_sc;

    always_ff @(posedge sys_clk) begin
        if (sys_rst) begin
            dma_busy_sync_sc <= 2'b00;
            dma_active       <= 1'b0;
            dma_err          <= 1'b0;
        end else begin
            dma_busy_sync_sc <= {dma_busy_sync_sc[0], dma_busy_uc};
            dma_active       <= dma_busy_sync_sc[1];
            dma_err          <= user_lnk_up ? 1'b0 : dma_busy_sync_sc[1];
        end
    end

endmodule
