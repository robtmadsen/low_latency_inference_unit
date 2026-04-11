// lliu_top_v2.sv — Phase 2 top-level integration for LLIU v2.0 (Kintex-7, 312.5 MHz)
//
// Pipeline (all in sys_clk = 312.5 MHz domain):
//   s_axis (ITCH ingress) → itch_parser_v2 → order_book / symbol_filter
//   → (1-cy delay) → feature_extractor_v2 → 8× lliu_core → strategy_arbiter
//   → risk_check → ouch_engine → m_axis (OUCH 5.0 to 10GbE TX)
//   ptp_core → 6× timestamp_tap → latency_histogram
//
// AXI4-Lite address map (12-bit byte address, 32-bit data):
//   0x014        CAM_INDEX   [7:0]
//   0x018        CAM_DATA_LO [31:0]
//   0x01C        CAM_DATA_HI [31:0]
//   0x020        CAM_CTRL    [0]=wr_valid(self-clear), [1]=en_bit
//   0x038        CAM_INDEX_HI [1:0]
//   0x048        COLLISION_COUNT (r/o)
//   0x400        BAND_BPS [31:0]  (default 200)
//   0x404        MAX_QTY  [31:0]  (default 10000)
//   0x408        SCORE_THRESH [31:0]  (float32, default 0.0)
//   0x40C        RISK_CTRL [0]=set kill switch
//   0x410        RISK_STATUS [0]=risk_blocked_latch (r/o; clears on read)
//   0x500-0x57C  HIST_BIN[0..31] (r/o)
//   0x580        HIST_OVERFLOW (r/o)
//   0x584        HIST_CLEAR [0]=pulse
//   0x800-0xBFC  WGT: addr[11:10]=2'b10, core=addr[9:7], waddr=addr[6:2]
//   0xC00+k*4    SHARES_CORE_k [23:0]  (k=0..7, default 100)
//   0xE00        TMPL_ADDR [8:0]
//   0xE04        TMPL_DATA_LO [31:0]
//   0xE08        TMPL_DATA_HI [31:0] + fires BRAM write

// verilator lint_off IMPORTSTAR
import lliu_pkg::*;
// verilator lint_on IMPORTSTAR

// verilator lint_off MULTITOP
module lliu_top_v2 #(
    parameter int VEC_LEN = FEAT_VEC_LEN_V2,
    parameter int HIDDEN  = HIDDEN_LAYER
)(
    input  logic        clk,
    input  logic        rst,

    input  logic [63:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    output logic        s_axis_tready,
    input  logic        s_axis_tlast,

    output logic [63:0] m_axis_tdata,
    output logic [7:0]  m_axis_tkeep,
    output logic        m_axis_tvalid,
    output logic        m_axis_tlast,
    input  logic        m_axis_tready,

    input  logic [11:0] s_axil_awaddr,
    input  logic        s_axil_awvalid,
    output logic        s_axil_awready,
    input  logic [31:0] s_axil_wdata,
    /* verilator lint_off UNUSED */
    input  logic [3:0]  s_axil_wstrb,
    /* verilator lint_on UNUSED */
    input  logic        s_axil_wvalid,
    output logic        s_axil_wready,
    /* verilator coverage_off */
    output logic [1:0]  s_axil_bresp,
    /* verilator coverage_on */
    output logic        s_axil_bvalid,
    input  logic        s_axil_bready,
    input  logic [11:0] s_axil_araddr,
    input  logic        s_axil_arvalid,
    output logic        s_axil_arready,
    output logic [31:0] s_axil_rdata,
    /* verilator coverage_off */
    output logic [1:0]  s_axil_rresp,
    /* verilator coverage_on */
    output logic        s_axil_rvalid,
    input  logic        s_axil_rready,

    output logic [31:0] collision_count_out,
    output logic        tx_overflow_out,

    // ── Snapshot interface (to pcie_dma_engine in kc705_top) ─────────────
    input  logic        snap_req,    // one-cycle pulse: start snapshot
    output logic [63:0] snap_data,   // 64-bit beat
    output logic        snap_valid,  // beat valid (combinational)
    input  logic        snap_ready,  // consumer ready
    output logic        snap_done    // one-cycle pulse after last beat
);

    // ================================================================
    // PTP core
    // ================================================================
    logic        ptp_sync_pulse;
    logic [63:0] ptp_epoch;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [63:0] ptp_counter_w;
    /* verilator lint_on UNUSEDSIGNAL */

    ptp_core u_ptp (
        .clk            (clk),
        .rst            (rst),
        .ptp_sync_pulse (ptp_sync_pulse),
        .ptp_epoch      (ptp_epoch),
        .ptp_counter    (ptp_counter_w)
    );

    // ================================================================
    // ITCH parser v2
    // ================================================================
    logic        pipeline_hold;

    logic [7:0]  parser_msg_type;
    logic [63:0] parser_order_ref;
    logic [63:0] parser_new_order_ref;
    logic [31:0] parser_price;
    logic [31:0] parser_shares;
    logic        parser_side;
    logic [63:0] parser_stock;
    logic [8:0]  parser_sym_id;
    logic        parser_fields_valid;

    itch_parser_v2 u_parser (
        .clk            (clk),
        .rst            (rst),
        .s_axis_tdata   (s_axis_tdata),
        .s_axis_tvalid  (s_axis_tvalid),
        .s_axis_tready  (s_axis_tready),
        .s_axis_tlast   (s_axis_tlast),
        .pipeline_hold  (pipeline_hold),
        .msg_type       (parser_msg_type),
        .order_ref      (parser_order_ref),
        .new_order_ref  (parser_new_order_ref),
        .price          (parser_price),
        .shares         (parser_shares),
        .side           (parser_side),
        .stock          (parser_stock),
        .sym_id         (parser_sym_id),
        .fields_valid   (parser_fields_valid)
    );

    logic        ts_rx_last_event;
    logic [73:0] ts_rx_last;
    logic        ts_rx_last_valid;

    assign ts_rx_last_event = s_axis_tvalid & s_axis_tready & s_axis_tlast;

    timestamp_tap u_tap_rx_last (
        .clk (clk), .rst (rst),
        .ptp_sync_pulse (ptp_sync_pulse), .ptp_epoch (ptp_epoch),
        .tap_event      (ts_rx_last_event),
        .timestamp_out  (ts_rx_last), .timestamp_valid (ts_rx_last_valid)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    logic [73:0] ts_fields_w;
    logic        ts_fields_v;
    /* verilator lint_on UNUSEDSIGNAL */

    timestamp_tap u_tap_fields_valid (
        .clk (clk), .rst (rst),
        .ptp_sync_pulse (ptp_sync_pulse), .ptp_epoch (ptp_epoch),
        .tap_event      (parser_fields_valid),
        .timestamp_out  (ts_fields_w), .timestamp_valid (ts_fields_v)
    );

    // ================================================================
    // Order book
    // ================================================================
    logic [31:0] bbo_bid_price;
    logic [31:0] bbo_ask_price;
    logic [23:0] bbo_bid_size;
    logic [23:0] bbo_ask_size;
    logic [31:0] l2_bid_price [0:3];
    logic [23:0] l2_bid_size  [0:3];
    logic [31:0] l2_ask_price [0:3];
    logic [23:0] l2_ask_size  [0:3];
    logic [31:0] collision_count;
    logic        bbo_valid_w;
    logic [8:0]  bbo_sym_id_w;
    /* verilator lint_off UNUSEDSIGNAL */
    logic        collision_flag_w;
    logic        book_ready_w;
    /* verilator lint_on UNUSEDSIGNAL */

    assign collision_count_out = collision_count;

    order_book u_ob (
        .clk            (clk), .rst (rst),
        .msg_type       (parser_msg_type),
        .order_ref      (parser_order_ref),
        .new_order_ref  (parser_new_order_ref),
        .price          (parser_price),
        .shares         (parser_shares),
        .side           (parser_side),
        .sym_id         (parser_sym_id),
        .fields_valid   (parser_fields_valid),
        .bbo_query_sym  (parser_sym_id),
        .bbo_bid_price  (bbo_bid_price), .bbo_ask_price (bbo_ask_price),
        .bbo_bid_size   (bbo_bid_size),  .bbo_ask_size  (bbo_ask_size),
        .bbo_valid      (bbo_valid_w),   .bbo_sym_id    (bbo_sym_id_w),
        .l2_bid_price   (l2_bid_price),  .l2_bid_size   (l2_bid_size),
        .l2_ask_price   (l2_ask_price),  .l2_ask_size   (l2_ask_size),
        .collision_count(collision_count),
        .collision_flag (collision_flag_w), .book_ready (book_ready_w)
    );

    // ================================================================
    // Symbol filter
    // ================================================================
    logic        watchlist_hit;
    logic [9:0]  cam_wr_index;
    logic [63:0] cam_wr_data;
    logic        cam_wr_valid;
    logic        cam_wr_en_bit;

    symbol_filter u_sym_filter (
        .clk          (clk), .rst (rst),
        .stock        (parser_stock), .stock_valid (parser_fields_valid),
        .watchlist_hit(watchlist_hit),
        .cam_wr_index (cam_wr_index), .cam_wr_data (cam_wr_data),
        .cam_wr_valid (cam_wr_valid), .cam_wr_en_bit (cam_wr_en_bit)
    );

    // ================================================================
    // One-cycle delay: align parser fields + BBO with watchlist_hit
    // ================================================================
    logic        fields_valid_d1;
    logic [31:0] price_d1;
    logic [31:0] shares_d1;
    logic        side_d1;
    logic [8:0]  sym_id_d1;

    always_ff @(posedge clk) begin
        if (rst) begin
            fields_valid_d1 <= 1'b0;
            price_d1 <= 32'h0; shares_d1 <= 32'h0;
            side_d1  <= 1'b0;  sym_id_d1 <= 9'h0;
        end else begin
            fields_valid_d1 <= parser_fields_valid;
            price_d1        <= parser_price;
            shares_d1       <= parser_shares;
            side_d1         <= parser_side;
            sym_id_d1       <= parser_sym_id;
        end
    end

    logic feat_ext_fv;
    assign feat_ext_fv = fields_valid_d1 & watchlist_hit;

    // ================================================================
    // Feature extractor v2  (4-cy latency)
    // ================================================================
    bfloat16_t  core_features      [VEC_LEN];
    logic       core_features_valid;

    feature_extractor_v2 #(.VEC_LEN(VEC_LEN)) u_feat_ext (
        .clk            (clk), .rst (rst),
        .price          (price_d1), .shares (shares_d1),
        .side           (side_d1),  .sym_id (sym_id_d1),
        .fields_valid   (feat_ext_fv),
        .bbo_bid_price  (bbo_bid_price), .bbo_ask_price (bbo_ask_price),
        .bbo_bid_size   (bbo_bid_size),  .bbo_ask_size  (bbo_ask_size),
        .l2_bid_price   (l2_bid_price),  .l2_bid_size   (l2_bid_size),
        .l2_ask_price   (l2_ask_price),  .l2_ask_size   (l2_ask_size),
        .features       (core_features), .features_valid (core_features_valid)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    logic [73:0] ts_feat_w;
    logic        ts_feat_v;
    /* verilator lint_on UNUSEDSIGNAL */

    timestamp_tap u_tap_feat (
        .clk (clk), .rst (rst),
        .ptp_sync_pulse (ptp_sync_pulse), .ptp_epoch (ptp_epoch),
        .tap_event      (core_features_valid),
        .timestamp_out  (ts_feat_w), .timestamp_valid (ts_feat_v)
    );

    // ================================================================
    // 8x lliu_core
    // ================================================================
    float32_t  core_result        [NUM_CORES];
    logic      core_result_valid  [NUM_CORES];
    /* verilator lint_off UNUSEDSIGNAL */
    float32_t  core_result_out_w  [NUM_CORES];
    logic      core_result_rdy_w  [NUM_CORES];
    /* verilator lint_on UNUSEDSIGNAL */

    logic [4:0] wgt_wr_addr_ar [NUM_CORES];
    bfloat16_t                 wgt_wr_data_ar [NUM_CORES];
    logic                      wgt_wr_en_ar   [NUM_CORES];

    genvar k;
    generate
        for (k = 0; k < NUM_CORES; k++) begin : gen_cores
            lliu_core #(.VEC_LEN(VEC_LEN), .HIDDEN(HIDDEN)) u_core (
                .clk            (clk), .rst (rst),
                .features       (core_features),
                .features_valid (core_features_valid),
                .wgt_wr_addr    (wgt_wr_addr_ar[k]),
                .wgt_wr_data    (wgt_wr_data_ar[k]),
                .wgt_wr_en      (wgt_wr_en_ar[k]),
                .result         (core_result[k]),
                .result_valid   (core_result_valid[k]),
                .result_out     (core_result_out_w[k]),
                .result_ready   (core_result_rdy_w[k])
            );
        end
    endgenerate

    /* verilator lint_off UNUSEDSIGNAL */
    logic [73:0] ts_result_w;
    logic        ts_result_v;
    /* verilator lint_on UNUSEDSIGNAL */

    timestamp_tap u_tap_result (
        .clk (clk), .rst (rst),
        .ptp_sync_pulse (ptp_sync_pulse), .ptp_epoch (ptp_epoch),
        .tap_event      (core_result_valid[0]),
        .timestamp_out  (ts_result_w), .timestamp_valid (ts_result_v)
    );

    // ================================================================
    // Strategy arbiter
    // ================================================================
    float32_t   score_thresh_r;

    float32_t   arb_scores [NUM_CORES];
    logic       arb_valids [NUM_CORES];
    logic       arb_sides  [NUM_CORES];

    genvar gi;
    generate
        for (gi = 0; gi < NUM_CORES; gi++) begin : gen_arb_src
            assign arb_scores[gi] = core_result[gi];
            assign arb_valids[gi] = core_result_valid[gi];
            assign arb_sides[gi]  = 1'b0;
        end
    endgenerate

    float32_t   best_score;
    logic [2:0] best_core_id;
    logic       best_valid;
    /* verilator lint_off UNUSEDSIGNAL */
    logic       best_side_w;
    float32_t   best_score_w;
    /* verilator lint_on UNUSEDSIGNAL */
    assign best_score_w = best_score;

    strategy_arbiter u_arb (
        .clk            (clk), .rst (rst),
        .core_scores    (arb_scores), .core_valids (arb_valids),
        .core_sides     (arb_sides),  .score_thresh (score_thresh_r),
        .best_score     (best_score), .best_core_id (best_core_id),
        .best_valid     (best_valid), .best_side    (best_side_w)
    );

    // ================================================================
    // Hold registers
    // ================================================================
    logic [31:0] held_price_r;
    logic [8:0]  held_sym_id_r;
    logic        held_side_r;
    logic [31:0] held_ref_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            held_price_r  <= 32'h0;
            held_sym_id_r <= 9'h0;
            held_side_r   <= 1'b0;
            held_ref_r    <= 32'h0;
        end else if (feat_ext_fv) begin
            held_price_r  <= price_d1;
            held_sym_id_r <= sym_id_d1;
            held_side_r   <= side_d1;
            held_ref_r    <= (bbo_bid_price >> 1) + (bbo_ask_price >> 1);
        end
    end

    logic [23:0] core_shares_ar [NUM_CORES];

    logic [23:0] risk_proposed_shares;
    assign risk_proposed_shares = core_shares_ar[best_core_id];

    // ================================================================
    // Risk check
    // ================================================================
    logic [31:0] band_bps_r;
    logic [31:0] max_qty_r;
    logic        kill_sw_r;
    logic        tx_overflow_int;
    logic        risk_pass;
    logic        risk_blocked_w;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [1:0]  block_reason_w;
    /* verilator lint_on UNUSEDSIGNAL */
    logic        risk_blocked_latch;

    assign tx_overflow_out = tx_overflow_int;

    risk_check u_risk (
        .clk            (clk), .rst (rst),
        .score_valid    (best_valid),
        .side           (held_side_r),
        .price          (held_price_r),
        .symbol_id      (held_sym_id_r),
        .proposed_shares(risk_proposed_shares),
        .tx_overflow    (tx_overflow_int),
        .band_bps       (band_bps_r),
        .max_qty        (max_qty_r),
        .pos_limit      (24'd1000),
        .kill_sw        (kill_sw_r),
        .ref_price      (held_ref_r),
        .risk_pass      (risk_pass),
        .risk_blocked   (risk_blocked_w),
        .block_reason   (block_reason_w)
    );

    logic [73:0] ts_risk_pass;
    logic        ts_risk_pass_valid;

    timestamp_tap u_tap_risk_pass (
        .clk (clk), .rst (rst),
        .ptp_sync_pulse (ptp_sync_pulse), .ptp_epoch (ptp_epoch),
        .tap_event      (risk_pass),
        .timestamp_out  (ts_risk_pass), .timestamp_valid (ts_risk_pass_valid)
    );

    // ================================================================
    // OUCH engine
    // ================================================================
    logic [8:0]  tmpl_wr_addr;
    logic [63:0] tmpl_wr_data;
    logic        tmpl_wr_en;

    ouch_engine u_ouch (
        .clk            (clk), .rst (rst),
        .risk_pass      (risk_pass),
        .side           (held_side_r),
        .price          (held_price_r),
        .symbol_id      (held_sym_id_r[6:0]),
        .proposed_shares(risk_proposed_shares),
        .timestamp      (ptp_epoch),
        .tmpl_wr_addr   (tmpl_wr_addr),
        .tmpl_wr_data   (tmpl_wr_data),
        .tmpl_wr_en     (tmpl_wr_en),
        .m_axis_tdata   (m_axis_tdata),
        .m_axis_tkeep   (m_axis_tkeep),
        .m_axis_tvalid  (m_axis_tvalid),
        .m_axis_tlast   (m_axis_tlast),
        .m_axis_tready  (m_axis_tready),
        .tx_overflow    (tx_overflow_int)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    logic [73:0] ts_ouch_w;
    logic        ts_ouch_v;
    /* verilator lint_on UNUSEDSIGNAL */

    timestamp_tap u_tap_ouch_last (
        .clk (clk), .rst (rst),
        .ptp_sync_pulse (ptp_sync_pulse), .ptp_epoch (ptp_epoch),
        .tap_event      (m_axis_tvalid & m_axis_tready & m_axis_tlast),
        .timestamp_out  (ts_ouch_w), .timestamp_valid (ts_ouch_v)
    );

    // ================================================================
    // Latency histogram
    // ================================================================
    logic [4:0]  axil_bin_addr;
    logic [31:0] axil_bin_data;
    logic        axil_clear;
    logic [31:0] overflow_bin;

    assign axil_bin_addr = s_axil_araddr[6:2];

    latency_histogram u_hist (
        .clk (clk), .rst (rst),
        .t_start       (ts_rx_last),     .t_start_valid (ts_rx_last_valid),
        .t_end         (ts_risk_pass),   .t_end_valid   (ts_risk_pass_valid),
        .axil_bin_addr (axil_bin_addr),  .axil_bin_data (axil_bin_data),
        .axil_clear    (axil_clear),     .overflow_bin  (overflow_bin)
    );

    // ================================================================
    // Snapshot mux — BBO shadow buffer streamed to pcie_dma_engine
    // ================================================================
    snapshot_mux u_snap (
        .clk           (clk),
        .rst           (rst),
        .bbo_valid     (bbo_valid_w),
        .bbo_sym_id    (bbo_sym_id_w),
        .bbo_bid_price (bbo_bid_price),
        .bbo_ask_price (bbo_ask_price),
        .bbo_bid_size  (bbo_bid_size),
        .bbo_ask_size  (bbo_ask_size),
        .snap_req      (snap_req),
        .snap_data     (snap_data),
        .snap_valid    (snap_valid),
        .snap_ready    (snap_ready),
        .snap_done     (snap_done)
    );

    // ================================================================
    // Pipeline hold
    // ================================================================
    logic in_flight;

    always_ff @(posedge clk) begin
        if (rst)                       in_flight <= 1'b0;
        else if (core_features_valid)  in_flight <= 1'b1;
        else if (core_result_valid[0]) in_flight <= 1'b0;
    end

    assign pipeline_hold = core_features_valid | in_flight;

    // ================================================================
    // AXI4-Lite inline decode
    // ================================================================
    logic        aw_cap;
    logic        w_cap;
    logic [11:0] wr_addr_r;
    logic [31:0] wr_data_r;

    // CAM staging
    logic [7:0]  cam_idx_lo_r;
    logic [1:0]  cam_idx_hi_r;
    logic [31:0] cam_dat_lo_r;
    logic [31:0] cam_dat_hi_r;
    // OUCH template staging
    logic [8:0]  tmpl_addr_stg;
    logic [31:0] tmpl_lo_stg;

    assign s_axil_awready = !aw_cap;
    assign s_axil_wready  = !w_cap;
    assign s_axil_bresp   = 2'b00;
    assign s_axil_rresp   = 2'b00;

    always_ff @(posedge clk) begin
        if (rst) begin
            aw_cap <= 1'b0; w_cap <= 1'b0;
            wr_addr_r <= 12'h0; wr_data_r <= 32'h0;
            s_axil_bvalid <= 1'b0;
            band_bps_r     <= 32'd200;
            max_qty_r      <= 32'd10000;
            score_thresh_r <= 32'h0;
            kill_sw_r      <= 1'b0;
            axil_clear     <= 1'b0;
            risk_blocked_latch <= 1'b0;
            cam_idx_lo_r   <= 8'h0;
            cam_idx_hi_r   <= 2'h0;
            cam_dat_lo_r   <= 32'h0;
            cam_dat_hi_r   <= 32'h0;
            cam_wr_valid   <= 1'b0;
            cam_wr_data    <= 64'h0;
            cam_wr_index   <= 10'h0;
            cam_wr_en_bit  <= 1'b0;
            tmpl_addr_stg  <= 9'h0;
            tmpl_lo_stg    <= 32'h0;
            tmpl_wr_en     <= 1'b0;
            tmpl_wr_addr   <= 9'h0;
            tmpl_wr_data   <= 64'h0;
            for (int i = 0; i < NUM_CORES; i++) begin
                wgt_wr_en_ar[i]   <= 1'b0;
                wgt_wr_addr_ar[i] <= 5'h0;
                wgt_wr_data_ar[i] <= 16'h0;
                core_shares_ar[i] <= 24'd100;
            end
        end else begin
            cam_wr_valid <= 1'b0;
            tmpl_wr_en   <= 1'b0;
            axil_clear   <= 1'b0;
            for (int i = 0; i < NUM_CORES; i++)
                wgt_wr_en_ar[i] <= 1'b0;

            if (risk_blocked_w)
                risk_blocked_latch <= 1'b1;

            if (s_axil_awvalid && s_axil_awready)
                begin aw_cap <= 1'b1; wr_addr_r <= s_axil_awaddr; end

            if (s_axil_wvalid && s_axil_wready)
                begin w_cap <= 1'b1; wr_data_r <= s_axil_wdata; end

            if (s_axil_bvalid && s_axil_bready)
                s_axil_bvalid <= 1'b0;

            if (aw_cap && w_cap && !s_axil_bvalid) begin
                aw_cap <= 1'b0; w_cap <= 1'b0;
                s_axil_bvalid <= 1'b1;

                if (wr_addr_r[11:10] == 2'b10) begin
                    // Weight: core=addr[9:7], waddr=addr[6:2]
                    // addr[9:7] is 3-bit -> values 0-7 == NUM_CORES exactly
                    wgt_wr_en_ar  [wr_addr_r[9:7]] <= 1'b1;
                    wgt_wr_addr_ar[wr_addr_r[9:7]] <= wr_addr_r[6:2];
                    wgt_wr_data_ar[wr_addr_r[9:7]] <= wr_data_r[15:0];
                end else begin
                    case (wr_addr_r)
                        12'h014: cam_idx_lo_r  <= wr_data_r[7:0];
                        12'h018: cam_dat_lo_r  <= wr_data_r;
                        12'h01C: cam_dat_hi_r  <= wr_data_r;
                        12'h020: begin
                            if (wr_data_r[0]) begin
                                cam_wr_valid  <= 1'b1;
                                cam_wr_index  <= {cam_idx_hi_r, cam_idx_lo_r};
                                cam_wr_data   <= {cam_dat_hi_r, cam_dat_lo_r};
                                cam_wr_en_bit <= wr_data_r[1];
                            end
                        end
                        12'h038: cam_idx_hi_r   <= wr_data_r[1:0];
                        12'h400: band_bps_r     <= wr_data_r;
                        12'h404: max_qty_r      <= wr_data_r;
                        12'h408: score_thresh_r <= wr_data_r;
                        12'h40C: if (wr_data_r[0]) kill_sw_r <= 1'b1;
                        12'h584: axil_clear     <= wr_data_r[0];
                        12'hC00: core_shares_ar[0] <= wr_data_r[23:0];
                        12'hC04: core_shares_ar[1] <= wr_data_r[23:0];
                        12'hC08: core_shares_ar[2] <= wr_data_r[23:0];
                        12'hC0C: core_shares_ar[3] <= wr_data_r[23:0];
                        12'hC10: core_shares_ar[4] <= wr_data_r[23:0];
                        12'hC14: core_shares_ar[5] <= wr_data_r[23:0];
                        12'hC18: core_shares_ar[6] <= wr_data_r[23:0];
                        12'hC1C: core_shares_ar[7] <= wr_data_r[23:0];
                        12'hE00: tmpl_addr_stg  <= wr_data_r[8:0];
                        12'hE04: tmpl_lo_stg    <= wr_data_r;
                        12'hE08: begin
                            tmpl_wr_en   <= 1'b1;
                            tmpl_wr_addr <= tmpl_addr_stg;
                            tmpl_wr_data <= {wr_data_r, tmpl_lo_stg};
                        end
                        default: ;
                    endcase
                end
            end
        end
    end

    // Read channel
    always_ff @(posedge clk) begin
        if (rst) begin
            s_axil_arready <= 1'b0;
            s_axil_rvalid  <= 1'b0;
            s_axil_rdata   <= 32'h0;
        end else begin
            s_axil_arready <= 1'b0;
            if (s_axil_rvalid && s_axil_rready)
                s_axil_rvalid <= 1'b0;

            if (s_axil_arvalid && !s_axil_rvalid) begin
                s_axil_arready <= 1'b1;
                s_axil_rvalid  <= 1'b1;

                if (s_axil_araddr == 12'h410) begin
                    s_axil_rdata       <= {30'h0, kill_sw_r, risk_blocked_latch};
                    risk_blocked_latch <= 1'b0;
                end else if (s_axil_araddr == 12'h048)
                    s_axil_rdata <= collision_count;
                else if (s_axil_araddr == 12'h580)
                    s_axil_rdata <= overflow_bin;
                else if (s_axil_araddr[11:7] == 5'b00101)
                    s_axil_rdata <= axil_bin_data;
                else
                    s_axil_rdata <= 32'h0;
            end
        end
    end

endmodule
