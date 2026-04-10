// lliu_pkg.sv — Shared types and parameters for the Low-Latency Inference Unit
package lliu_pkg;

/* verilator lint_off UNUSEDPARAM */

  // Feature vector length (number of bfloat16 elements per inference)
  parameter int FEATURE_VEC_LEN = 4;

  // bfloat16: 1 sign + 8 exponent + 7 mantissa = 16 bits
  parameter int BF16_WIDTH      = 16;
  parameter int BF16_EXP_WIDTH  = 8;
  parameter int BF16_MAN_WIDTH  = 7;
  parameter int BF16_EXP_BIAS   = 127;

  // float32: 1 sign + 8 exponent + 23 mantissa = 32 bits
  parameter int FP32_WIDTH      = 32;
  parameter int FP32_EXP_WIDTH  = 8;
  parameter int FP32_MAN_WIDTH  = 23;
  parameter int FP32_EXP_BIAS   = 127;

  // AXI4-Stream data width
  parameter int AXI_DATA_WIDTH  = 64;

  // ITCH 5.0 Add Order message type
  parameter logic [7:0] ITCH_MSG_ADD_ORDER = 8'h41; // 'A'

  // ITCH Add Order field widths (in bytes)
  parameter int ITCH_ADD_ORDER_LEN   = 36; // Total message body length (excluding 2-byte length prefix)
  parameter int ITCH_ORDER_REF_BYTES = 8;
  parameter int ITCH_PRICE_BYTES     = 4;

  // Pipeline depth from feature input to inference result
  // bfloat16_mul: 2 cycles (Stage 1: DSP48E1 multiply, Stage 2: normalize) +
  // fp32_acc: 5 stages (A0: exp compare, A1: align, B1: raw adder sum, B2: normalize, C: commit) +
  // drain allowance: VEC_LEN iterations + 5 drain cycles
  parameter int DOT_PRODUCT_LATENCY = FEATURE_VEC_LEN + 5; // iterate + 5 drain cycles (2-cycle bfloat16_mul + 5-stage fp32_acc)

  // AXI4-Lite register address map
  // v1 core registers
  parameter logic [7:0] AXIL_REG_CTRL          = 8'h00; // [0] start, [1] soft_reset
  parameter logic [7:0] AXIL_REG_STATUS        = 8'h04; // [0] result_ready, [1] busy
  parameter logic [7:0] AXIL_REG_WGT_ADDR      = 8'h08; // weight write address
  parameter logic [7:0] AXIL_REG_WGT_DATA      = 8'h0C; // weight write data (bfloat16)
  parameter logic [7:0] AXIL_REG_RESULT        = 8'h10; // inference result (float32)
  // KC705 extension registers
  parameter logic [7:0] AXIL_REG_CAM_INDEX     = 8'h14; // symbol-filter CAM entry index [7:0]
  parameter logic [7:0] AXIL_REG_CAM_DATA_LO   = 8'h18; // CAM key lower 32 bits
  parameter logic [7:0] AXIL_REG_CAM_DATA_HI   = 8'h1C; // CAM key upper 32 bits
  parameter logic [7:0] AXIL_REG_CAM_CTRL      = 8'h20; // [0] wr_valid (self-clearing), [1] en_bit
  parameter logic [7:0] AXIL_REG_DROPPED_FRAMES = 8'h24; // eth_axis_rx_wrap: dropped frame count
  parameter logic [7:0] AXIL_REG_DROPPED_DGRAMS = 8'h28; // moldupp64_strip: dropped datagram count
  parameter logic [7:0] AXIL_REG_SEQ_LO        = 8'h2C; // expected_seq_num[31:0]
  parameter logic [7:0] AXIL_REG_SEQ_HI        = 8'h30; // expected_seq_num[63:32]
  parameter logic [7:0] AXIL_REG_GTX_LOCK      = 8'h34; // [0] GTX PLL locked (tied 1 in sim)

  // v2.0 parameters
  parameter logic [7:0] ITCH_MSG_ADD_ORDER_MPID = 8'h46;
  parameter logic [7:0] ITCH_MSG_ORDER_CANCEL   = 8'h58;
  parameter logic [7:0] ITCH_MSG_ORDER_DELETE   = 8'h44;
  parameter logic [7:0] ITCH_MSG_ORDER_REPLACE  = 8'h55;
  parameter logic [7:0] ITCH_MSG_ORDER_EXEC     = 8'h45;
  parameter logic [7:0] ITCH_MSG_ORDER_EXEC_PX  = 8'h43;
  parameter logic [7:0] ITCH_MSG_TRADE          = 8'h50;
  parameter int ITCH_ADD_ORDER_MPID_LEN = 40;
  parameter int ITCH_ORDER_CANCEL_LEN   = 23;
  parameter int ITCH_ORDER_DELETE_LEN   = 19;
  parameter int ITCH_ORDER_REPLACE_LEN  = 35;
  parameter int ITCH_ORDER_EXEC_LEN     = 30;
  parameter int ITCH_ORDER_EXEC_PX_LEN  = 35;
  parameter int ITCH_TRADE_LEN          = 43;
  parameter int ITCH_MAX_MSG_LEN        = 43;
  parameter int OB_NUM_SYMBOLS    = 500;
  parameter int OB_LEVELS         = 16;
  parameter int OB_REF_TABLE_BITS = 15;   // 32K entries — fits in ~228 RAMB18E1
  parameter int PTP_SYNC_PERIOD  = 1024;
  parameter int PTP_SUBCNT_WIDTH = 10;
  parameter int SYM_FILTER_ENTRIES = 512;
  parameter int SYM_FILTER_IDX_W   = 9;
  parameter logic [7:0] AXIL_REG_CAM_INDEX_HI   = 8'h38;
  parameter logic [7:0] AXIL_REG_HIST_ADDR       = 8'h3C;
  parameter logic [7:0] AXIL_REG_HIST_DATA       = 8'h40;
  parameter logic [7:0] AXIL_REG_HIST_CLEAR      = 8'h44;
  parameter logic [7:0] AXIL_REG_COLLISION_COUNT = 8'h48;
  parameter logic [7:0] AXIL_REG_HIST_OVERFLOW   = 8'h4C;

  // Phase 2 parameters
  parameter int NUM_CORES           = 8;
  parameter int FEAT_VEC_LEN_V2     = 32;   // features per core in v2
  parameter int HIDDEN_LAYER        = 32;   // weights per core
  parameter int DOT_PRODUCT_LATENCY_V2 = FEAT_VEC_LEN_V2 + 5;

  // Risk check parameters (configurable via AXI4-Lite at runtime)
  parameter int RISK_PRICE_BAND_BPS_DEFAULT = 200;  // ±200 bps
  parameter int RISK_MAX_QTY_DEFAULT        = 10000;
  parameter int RISK_KILL_THRESH_DEFAULT    = 1000;  // hash collisions before kill

  // OUCH 5.0 Enter Order packet length (bytes): fixed 48-byte body
  parameter int OUCH_ENTER_ORDER_LEN = 48;

  // Phase 2 AXI4-Lite registers
  parameter logic [11:0] AXIL_REG_BAND_BPS      = 12'h400; // price band in basis points
  parameter logic [11:0] AXIL_REG_MAX_QTY        = 12'h404; // fat-finger max quantity
  parameter logic [11:0] AXIL_REG_SCORE_THRESH   = 12'h408; // strategy fire threshold (float32)
  parameter logic [11:0] AXIL_REG_RISK_CTRL      = 12'h40C; // [0] kill switch (W1S/W1C), [1] auto-clear enable
  parameter logic [11:0] AXIL_REG_RISK_STATUS    = 12'h410; // [0] kill asserted, [1] blocked_latched
  parameter logic [11:0] AXIL_REG_POSITION       = 12'h414; // net position accumulator (read-only)
  // Per-core histogram base: core k bins at 0x500 + k*0x80 + bin*4
  parameter logic [11:0] AXIL_REG_HIST_BASE_V2   = 12'h500;

  // OUCH side encoding
  parameter logic [7:0] OUCH_SIDE_BUY  = 8'h42; // 'B'
  parameter logic [7:0] OUCH_SIDE_SELL = 8'h53; // 'S'

  // Timestamp width: 64-bit {32-bit epoch, 32-bit sub_cnt}
  parameter int TIMESTAMP_WIDTH = 64;

  // Typedef for bfloat16 packed representation
  typedef logic [BF16_WIDTH-1:0] bfloat16_t;

  // Typedef for float32 packed representation
  typedef logic [FP32_WIDTH-1:0] float32_t;

  // Packed inference result from one core
  typedef struct packed {
    float32_t  score;
    logic [2:0] core_id;
    logic       valid;
  } core_result_t;

/* verilator lint_on UNUSEDPARAM */

endpackage
