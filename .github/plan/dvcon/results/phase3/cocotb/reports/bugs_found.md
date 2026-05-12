# Bugs Found in lliu_core Design

## Bug 1 — bfloat16_mul: sign computed with OR instead of XOR

- **File**: `rtl/bfloat16_mul.sv`, line 42
- **Test**: `test_negative_values` (code-review confirmation)
- **Observed**: `r_sign = a_sign | b_sign` (bitwise OR)
- **Expected**: `r_sign = a_sign ^ b_sign` (bitwise XOR), as stated in the spec
  and in the code's own comment on line 41.
- **Impact**: Multiplying two negative bfloat16 numbers yields a negative
  result instead of positive. E.g. (−1.0)×(−1.0) → −1.0 instead of +1.0.
- **Root cause**: Typo — `|` instead of `^`.

## Bug 2 — bfloat16_mul: exponent bias uses 126 instead of 127

- **File**: `rtl/bfloat16_mul.sv`, line 48
- **Test**: `test_inference_ones` (code-review confirmation)
- **Observed**: `exp_sum = a_exp + b_exp - 10'd126`
- **Expected**: `exp_sum = a_exp + b_exp - 10'd127` (standard IEEE bias removal).
  The spec says `a_exp + b_exp − 127`.
- **Impact**: Every product is 2× larger than correct, making all dot-product
  results wrong by a factor that grows with VEC_LEN.
- **Root cause**: Off-by-one in the bias constant (126 vs 127).

## Bug 3 — lliu_core: SEQ_FEED off-by-one (critical — causes hang)

- **File**: `rtl/lliu_core.sv`, line 151
- **Test**: `test_inference_ones` — DUT never asserts `result_valid`
  within 150 cycles; FSM returns to IDLE but DPE hangs in S_STREAM.
- **Observed**: Terminal condition is `seq_idx == VEC_LEN - 2`, producing
  only **VEC_LEN − 1** feature-valid pulses (elements 0 … VEC_LEN−2).
- **Expected**: `seq_idx == VEC_LEN - 1`, producing **VEC_LEN** pulses
  (elements 0 … VEC_LEN−1), matching the spec's "32 cycles in SEQ_FEED."
- **Impact**: The DPE expects VEC_LEN elements but only receives VEC_LEN−1.
  `mac_elem` reaches VEC_LEN−1 in the register but never gets a valid pulse
  at that value, so `mac_last_fed` is never set. The DPE stays in S_STREAM
  forever, and no `result_valid` is ever produced. The design is completely
  non-functional.
- **Root cause**: Off-by-one — `VEC_LEN - 2` should be `VEC_LEN - 1`.

## Bug 4 — output_buffer: latch guard prevents re-latch after first result

- **File**: `rtl/output_buffer.sv`, line 29
- **Test**: `test_multiple_inferences` (code review — blocked by Bug 3)
- **Observed**: `if (result_valid && !result_ready_reg)` — the `!result_ready_reg`
  guard prevents any update after the first result is latched.
- **Expected**: `if (result_valid)` — the spec says "Holds the value until the
  next inference result arrives", meaning every new `result_valid` should
  overwrite `result_out`.
- **Impact**: Only the first inference result is captured. All subsequent
  inference results are silently dropped, making the AXI4-Lite readout stale.
- **Root cause**: Extra `!result_ready_reg` guard on the latch enable.

## Bug 5 — weight_mem: combinational read instead of registered

- **File**: `rtl/weight_mem.sv`, line 36
- **Test**: Code review / spec comparison
- **Observed**: `assign rd_data = mem[rd_addr]` — combinational (0-cycle latency).
- **Expected**: Registered read with 1-cycle latency, as specified:
  ```systemverilog
  always_ff @(posedge clk) begin
      if (rst) rd_data <= '0;
      else     rd_data <= mem[rd_addr];
  end
  ```
- **Impact**: Weight data arrives one cycle early relative to the registered
  feature data. Each `feat_latch[N]` is multiplied with `weight[N+1]` instead
  of `weight[N]`, producing an incorrect (rotated) dot product.
- **Root cause**: Read port implemented as combinational assign instead of
  registered `always_ff`.

## Bug 6 — dot_product_engine: DRAIN_EXIT_VAL off-by-one

- **File**: `rtl/dot_product_engine.sv`, line 83
- **Test**: Code review (blocked by Bug 3)
- **Observed**: `DRAIN_EXIT_VAL = DRAIN_LAST_EN[4:0] + 5'd4`
- **Expected**: `DRAIN_EXIT_VAL = DRAIN_LAST_EN + 6`. The RTL comment on
  lines 80–82 derives `DRAIN_LAST_EN + 5`, but even that is wrong because it
  says "`acc_en_d4` writes `acc_reg`" when in fact `acc_en_d5` does (5 stages,
  not 4). Correct derivation: last `merge_en_r` at `DRAIN_LAST_EN + 1`;
  `acc_en_d5` fires 5 cycles later at `DRAIN_LAST_EN + 6`.
- **Impact**: For VEC_LEN ≥ 5, the drain exits before the last accumulator's
  contribution is merged. For VEC_LEN = 32, `acc_out[4]`'s partial sum
  (elements 4, 9, 14, 19, 24, 29) is dropped from the final result.
- **Root cause**: Code uses `+ 4` instead of `+ 6`; the comment's own
  derivation is also off by 1 (says `+ 5`).
