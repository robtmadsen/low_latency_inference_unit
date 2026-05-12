# RTL Bugs Found

## Bug 1: bfloat16_mul — Sign bit uses OR instead of XOR

- **File:** `rtl/bfloat16_mul.sv`, line 42
- **Code:** `assign r_sign = a_sign | b_sign;`
- **Expected:** `assign r_sign = a_sign ^ b_sign;`
- **Impact:** Multiplying two negative numbers produces a negative result instead of positive. Any multiplication involving a negative operand always yields a negative sign. This corrupts every dot-product that includes negative features or weights.

## Bug 2: bfloat16_mul — Exponent bias off by one

- **File:** `rtl/bfloat16_mul.sv`, line 48
- **Code:** `assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd126;`
- **Expected:** `assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd127;`
- **Impact:** Every multiplication result is scaled by 2x (exponent is 1 too high). Dot-product results are systematically doubled per element.

## Bug 3: output_buffer — Extra guard prevents re-latch

- **File:** `rtl/output_buffer.sv`, line 29
- **Code:** `end else if (result_valid && !result_ready_reg) begin`
- **Expected:** `end else if (result_valid) begin`
- **Impact:** After the first inference, `result_ready_reg` stays high (never cleared). Subsequent result_valid pulses are ignored, so `result_out` is frozen at the first result. The AXI4-Lite readout never updates after the initial inference.

## Bug 4: weight_mem — Combinational read instead of registered

- **File:** `rtl/weight_mem.sv`, line 36
- **Code:** `assign rd_data = mem[rd_addr];`
- **Expected:** Registered read: `always_ff @(posedge clk) rd_data <= mem[rd_addr];`
- **Impact:** Weight data arrives one cycle early relative to the registered feature input, causing the DPE to multiply each feature element with the *next* weight (off-by-one misalignment). The last element gets an undefined or wrapped weight.

## Bug 5: lliu_core — Sequencer feeds VEC_LEN-1 elements instead of VEC_LEN

- **File:** `rtl/lliu_core.sv`, line 151
- **Code:** `if (seq_idx == ($clog2(VEC_LEN+1))'(VEC_LEN - 2)) begin`
- **Expected:** `if (seq_idx == ($clog2(VEC_LEN+1))'(VEC_LEN - 1)) begin`
- **Impact:** The SEQ_FEED state terminates one element early. The DPE expects VEC_LEN feature_valid pulses but only receives VEC_LEN-1, so it hangs in S_STREAM indefinitely. Single inferences never produce a result. This is the most critical bug — it completely breaks the inference pipeline.

## Bug 6: fp32_acc — Forwarding mux operands swapped

- **File:** `rtl/fp32_acc.sv`, line 67
- **Code:** `assign acc_fb = acc_en_d5 ? acc_reg : partial_sum_r;`
- **Expected:** `assign acc_fb = acc_en_d5 ? partial_sum_r : acc_reg;`
- **Impact:** The forwarding mux returns the stale `acc_reg` when it should return the fresh `partial_sum_r` (and vice versa). During the DPE merge phase where accumulators are summed at 4-cycle intervals, this causes each merge addition to use wrong feedback, corrupting the final dot-product result.

## Scoreboard Results

| Test | Expected | Actual | Status |
|------|----------|--------|--------|
| T1_basic | 10 | TIMEOUT | DPE stuck (Bug 5) |
| T2_zero_wgt | 0 | TIMEOUT | DPE stuck (Bug 5) |
| T3_mixed | 18 | TIMEOUT | DPE stuck (Bug 5) |
| T4_neg_wgt | -2 | TIMEOUT | DPE stuck (Bug 5) |
| T5_both_neg | 10 | TIMEOUT | DPE stuck (Bug 5) |
| T6_double | 4 | 0 (0x00000000) | Mismatch (Bugs 1,2,4,5,6) |
| T7_result_out | 8 | 0 (0x00000000) | Mismatch (Bugs 1,2,4,5,6) |
| T8_large | 75.5 | 0 (0x00000000) | Mismatch (Bugs 1,2,4,5,6) |
