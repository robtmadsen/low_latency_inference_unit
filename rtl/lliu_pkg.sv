// lliu_pkg.sv — Shared types and parameters for the Low-Latency Inference Unit
package lliu_pkg;

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
  parameter int DOT_PRODUCT_LATENCY = FEATURE_VEC_LEN + 1; // iterate + final accumulate

  // Typedef for bfloat16 packed representation
  typedef logic [BF16_WIDTH-1:0] bfloat16_t;

  // Typedef for float32 packed representation
  typedef logic [FP32_WIDTH-1:0] float32_t;

endpackage
