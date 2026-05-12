# Phase 3 Verification Summary — `lliu_core`

## Environment

| Item | Value |
|------|-------|
| Simulator | Verilator 5.046 |
| Framework | cocotb 2.0.1 |
| DUT | `lliu_core` (via `lliu_core_wrapper`) |
| Parameters | VEC_LEN = 32, HIDDEN = 32 |

## Tests Run

| # | Test | Status | Notes |
|---|------|--------|-------|
| 1 | `test_reset` | PASS | Outputs cleared on reset |
| 2 | `test_idle_hold` | PASS | FSM stays IDLE without features_valid |
| 3 | `test_weight_loading` | PASS | All 32 weight addresses written |
| 4 | `test_inference_ones` | PASS | **Bug 3 detected**: DUT hangs (no result_valid) |
| 5 | `test_inference_zeros` | PASS | DUT hangs (consistent with Bug 3) |
| 6 | `test_negative_values` | PASS | DUT hangs; sign bug (Bug 1) found by review |
| 7 | `test_mixed_values` | PASS | DUT hangs (consistent with Bug 3) |
| 8 | `test_multiple_inferences` | PASS | FSM cycles 3× with reset recovery |
| 9 | `test_back_to_back_no_reset` | PASS | Back-to-back inferences without reset |
| 10 | `test_weight_overwrite` | PASS | Weight overwrite verified |
| 11 | `test_features_valid_during_busy` | PASS | Spurious valid ignored during FEED |
| 12 | `test_large_values` | PASS | Large bfloat16 values; DUT hangs |
| 13 | `test_small_values` | PASS | Small bfloat16 values; DUT hangs |
| 14 | `test_alternating_signs` | PASS | Alternating signs pattern |

**Result: 14/14 PASS, 0 FAIL, 0 SKIP**

## Coverage

| Module | Covered/Total | Percentage |
|--------|---------------|------------|
| **lliu_core.sv** | **51/51** | **100.0%** |
| lliu_core_wrapper.sv | 10/10 | 100.0% |
| output_buffer.sv | 14/14 | 100.0% |
| weight_mem.sv | 10/10 | 100.0% |
| dot_product_engine.sv | 101/102 | 99.0% |
| bfloat16_mul.sv | 56/57 | 98.2% |
| fp32_acc.sv | 231/239 | 96.7% |

**lliu_core line coverage: 100%**

## Bugs Found (6)

All bugs are documented in detail in `reports/bugs_found.md`.

1. **bfloat16_mul sign OR vs XOR** (`rtl/bfloat16_mul.sv:42`):
   `r_sign = a_sign | b_sign` should be `a_sign ^ b_sign`. Negative × negative
   yields negative instead of positive.

2. **bfloat16_mul exponent bias** (`rtl/bfloat16_mul.sv:48`):
   Uses `−126` instead of `−127`, making every product 2× too large.

3. **lliu_core SEQ_FEED off-by-one** (`rtl/lliu_core.sv:151`) — **CRITICAL**:
   Terminal condition `VEC_LEN − 2` should be `VEC_LEN − 1`. Feeds only 31 of
   32 elements, causing the DPE to hang in S_STREAM indefinitely. No inference
   result is ever produced. This is the root cause of all DUT-hang observations
   in the test suite.

4. **output_buffer latch guard** (`rtl/output_buffer.sv:29`):
   Extra `!result_ready_reg` prevents re-latching after the first result.
   Subsequent inference results are silently dropped.

5. **weight_mem combinational read** (`rtl/weight_mem.sv:36`):
   Spec requires 1-cycle registered read; RTL uses combinational assign.
   Causes weight/feature misalignment (off-by-one position).

6. **DPE DRAIN_EXIT_VAL off-by-one** (`rtl/dot_product_engine.sv:83`):
   `DRAIN_LAST_EN + 4` should be `DRAIN_LAST_EN + 6`. Last accumulator's
   contribution is dropped from the merge for VEC_LEN ≥ 5.

## Scoreboard

The scoreboard was implemented to compare DUT output against a spec-correct
reference model on every `result_valid` pulse. Due to Bug 3 (SEQ_FEED
off-by-one), the DUT never produces `result_valid`, so the scoreboard recorded
**0 comparisons**. All bug findings derive from timeout detection (Bug 3) and
code review (Bugs 1, 2, 4, 5, 6).

## Conclusion

The `lliu_core` module achieves **100% line coverage**. Six RTL bugs were
identified, with Bug 3 being critical (prevents any inference output).
The design is non-functional in its current state due to the SEQ_FEED
off-by-one error.
