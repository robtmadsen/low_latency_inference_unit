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

  // Typedef for bfloat16 packed representation
  typedef logic [BF16_WIDTH-1:0] bfloat16_t;

  // Typedef for float32 packed representation
  typedef logic [FP32_WIDTH-1:0] float32_t;

/* verilator lint_on UNUSEDPARAM */

endpackage
