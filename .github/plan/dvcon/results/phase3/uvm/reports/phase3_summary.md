# Phase 3 Summary — UVM Testbench for lliu_core

## Objective

Build a UVM testbench for the `lliu_core` module targeting 100% line coverage, running under Verilator 5.046 with the Accellera UVM source.

## Coverage Result

**lliu_core line coverage: 100% (31/31)**

All executable lines in `lliu_core.sv` are covered: reset logic, all four FSM states (SEQ_IDLE, SEQ_PRELOAD, SEQ_FEED, SEQ_WAIT), feature vector latching, weight memory addressing, DPE control signal generation, and output assignments.

## Testbench Architecture

- **Interface:** `lliu_core_if` — groups all DUT signals with a clock input for virtual interface usage.
- **Driver:** Provides `do_reset()`, `load_weights()`, and `drive_features()` tasks. Drives the DUT through the virtual interface.
- **Monitor:** Watches `result_valid` in a forever loop and captures `result` for scoreboard comparison.
- **Scoreboard:** Compares DUT output against a bfloat16 reference model (`bf16_to_real` via `$bitstoreal`). Logs mismatches as UVM_WARNING and tracks pass/fail/timeout counts.
- **Agent/Env/Test:** Standard UVM hierarchy. The base test runs 8 scenarios covering positive, negative, zero, mixed, and large-value vectors.
- **DPI Stubs:** Custom `uvm_dpi_verilator.cpp` provides all DPI-C functions required by UVM (HDL backdoor, regex, command-line args, tool identification).

## Test Scenarios

| Test | Description | Result |
|------|-------------|--------|
| T1_basic | All-ones weights, ascending features | Timeout (Bug 5) |
| T2_zero_wgt | Zero weights | Timeout (Bug 5) |
| T3_mixed | Mixed positive weights and features | Timeout (Bug 5) |
| T4_neg_wgt | Alternating +/- weights | Timeout (Bug 5) |
| T5_both_neg | All-negative features and weights | Timeout (Bug 5) |
| T6_double | Double inference to complete DPE | Mismatch (0 vs 4) |
| T7_result_out | Tests output_buffer latch | Mismatch (0 vs 8) |
| T8_large | Large-magnitude values | Mismatch (0 vs 75.5) |

## Bugs Found

Six RTL bugs were identified across four modules:

1. **bfloat16_mul sign OR** (line 42): `a_sign | b_sign` should be `a_sign ^ b_sign`
2. **bfloat16_mul bias** (line 48): exponent bias uses 126 instead of 127, doubling every product
3. **output_buffer guard** (line 29): extra `!result_ready_reg` prevents re-latching after first result
4. **weight_mem combinational read** (line 36): should be registered, causes weight/feature misalignment
5. **lliu_core sequencer off-by-one** (line 151): `VEC_LEN - 2` should be `VEC_LEN - 1`, drops last element and hangs DPE
6. **fp32_acc forwarding mux** (line 67): operands swapped, corrupts merge accumulation

Bug 5 is the most severe — it completely prevents single inferences from completing. The double-inference workaround (T6-T8) forces the DPE to receive its missing element from a subsequent inference, allowing the pipeline to drain, but the accumulated result is corrupted by the other five bugs.

## Files Delivered

```
tb/
  Makefile              — build and test targets
  lliu_core_if.sv       — DUT interface
  lliu_core_tb_pkg.sv   — UVM package (driver, monitor, scoreboard, agent, env, test)
  tb_top.sv             — top module with clock, DUT, UVM launch
  uvm_dpi_verilator.cpp — DPI-C stubs for Verilator
  gen_coverage.py       — coverage annotation parser
reports/
  coverage.txt          — line coverage report (100%)
  bugs_found.md         — detailed bug descriptions
  phase3_summary.md     — this file
```

## Exit Criteria

- [x] `make -C tb/ test` exits 0
- [x] `reports/coverage.txt` shows 100% line coverage for lliu_core
- [x] `reports/bugs_found.md` exists with documented discrepancies
- [x] `reports/phase3_summary.md` exists
