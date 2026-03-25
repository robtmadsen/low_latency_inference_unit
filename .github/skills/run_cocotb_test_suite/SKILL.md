---
name: run_cocotb_test_suite
description: >
  Invoke and debug the cocotb/Verilator testbench for the
  low_latency_inference_unit (LLIU) project. Use for: running individual
  tests, running the full test suite, interpreting failures, or
  understanding the testbench architecture.
applyTo: "tb/cocotb/**"
---

# SKILL: Run cocotb Test Suite

## 1. Testbench Root

```
tb/cocotb/         ← all commands must be run from here (or with -C tb/cocotb)
├── Makefile
├── checkers/
├── coverage/
├── coverage_data/
├── drivers/
├── models/
├── scoreboard/
├── sim_build/     ← Verilator build artefacts (auto-generated, ignore)
├── stimulus/
├── tests/
└── utils/
```

---

## 2. Running the Full Regression (Preferred)

### Pre-flight: delete stale artifacts

> ⚠️ **MANDATORY before every regression run.** The following files persist from prior
> runs and will give a false pass/fail picture if not deleted first:
>
> | File / Directory | Why it must be deleted |
> |---|---|
> | `tb/cocotb/results.xml` | cocotb only overwrites this when a test actually runs |
> | `tb/cocotb/regression_results/results_*.xml` | per-module copies saved by the regression script |
> | `reports/cocotb_results.xml` | merged output from a previous regression |
>
> **The agent cannot run `rm` (blocked by policy).** Tell the user:
> *"Please delete `tb/cocotb/results.xml`, all files in `tb/cocotb/regression_results/`,
> and `reports/cocotb_results.xml` if they exist. Let me know when done."*
> Then **wait for confirmation** before proceeding.

### Run with the regression script

From the repo root:

```bash
python3 scripts/run_cocotb_regression.py
```

This script:
1. Iterates over every `(TOPLEVEL, MODULE)` pair, running `make clean` between toplevel changes.
2. Saves a copy of each `results.xml` to `tb/cocotb/regression_results/results_<module>.xml`.
3. Merges all saved XMLs into `reports/cocotb_results.xml` with a `<summary>` element at the top.
4. Prints a one-line summary to the terminal and exits non-zero if any test failed.

Optional flags:

| Flag | Effect |
|---|---|
| `--no-run` | Skip running; just merge existing `regression_results/*.xml` into the report |
| `--output <path>` | Write merged XML to a custom path instead of `reports/cocotb_results.xml` |

The merged report path to share with the user is: **`reports/cocotb_results.xml`**

---

## 3. Running Individual Tests

Every test is launched with:

```bash
cd tb/cocotb
make SIM=verilator TOPLEVEL=<top> MODULE=tests.<test_module>
```

`SIM` and `TOPLEVEL_LANG=verilog` are fixed defaults in the Makefile.
`TOPLEVEL` selects which RTL source files are compiled (the Makefile has
explicit `ifeq` blocks per toplevel). `MODULE` is always `tests.<filename_without_.py>`.

> **IMPORTANT:** Always run `make clean` before switching to a different `TOPLEVEL`.
> Verilator's `sim_build/` contains a compiled binary for one specific toplevel;
> reusing it with a different toplevel causes a `No root handle found` error.
> Multiple tests with the **same** `TOPLEVEL` can share the build without cleaning.

### Optional environment variables

| Variable | Default | Effect |
|---|---|---|
| `LLIU_MAX_LATENCY` | `12` | Cycle budget asserted by `test_end_to_end_latency_spec` in `test_latency.py` |

---

## 3. Complete Test Inventory

> Column "MODULE" is the value passed as `MODULE=tests.<MODULE>`.

### 3.1 Unit Tests — Arithmetic Primitives

#### `TOPLEVEL=bfloat16_mul`

| File | MODULE | Test functions |
|---|---|---|
| `tests/test_bfloat16_mul.py` | `test_bfloat16_mul` | `test_bfloat16_mul_basic`, `test_bfloat16_mul_special_cases` |
| `tests/test_bf16_mul_edge.py` | `test_bf16_mul_edge` | `test_bf16_mul_zero_both`, `test_bf16_mul_zero_a`, `test_bf16_mul_zero_b`, `test_bf16_mul_neg_neg`, `test_bf16_mul_neg_pos`, `test_bf16_mul_pos_neg`, `test_bf16_mul_denormal`, `test_bf16_mul_large_overflow`, `test_bf16_mul_underflow`, `test_bf16_mul_all_mantissa_bits`, `test_bf16_mul_norm_shift_decision`, `test_bf16_mul_exponent_sweep` |

RTL compiled: `lliu_pkg.sv`, `bfloat16_mul.sv`. Combinational DUT — tests use `Timer(1, unit='ns')` rather than a clock.

#### `TOPLEVEL=fp32_acc`

| File | MODULE | Test functions |
|---|---|---|
| `tests/test_fp32_acc.py` | `test_fp32_acc` | `test_fp32_acc_accumulate`, `test_fp32_acc_clear` |
| `tests/test_fp32_acc_edge.py` | `test_fp32_acc_edge` | `test_acc_zero_addend`, `test_acc_addend_to_zero`, `test_acc_both_zero`, `test_acc_effective_subtraction`, `test_acc_subtraction_negative_result`, `test_acc_near_cancellation`, `test_acc_deep_normalization_shifts`, `test_acc_carry_out`, `test_acc_exact_cancellation`, `test_acc_large_exp_diff`, `test_acc_negative_accumulation`, `test_acc_alternating_signs` |

RTL compiled: `lliu_pkg.sv`, `fp32_acc.sv`. Clocked DUT — tests use `Clock(dut.clk, 10, unit='ns')`.

#### `TOPLEVEL=dot_product_engine`

| File | MODULE | Test functions |
|---|---|---|
| `tests/test_dot_product_engine.py` | `test_dot_product_engine` | `test_dot_product_basic`, `test_dot_product_sweep`, `test_dot_product_back_to_back` |

RTL compiled: `lliu_pkg.sv`, `bfloat16_mul.sv`, `fp32_acc.sv`, `dot_product_engine.sv`.

---

### 3.2 Unit Tests — Protocol / Parsing

#### `TOPLEVEL=itch_parser`

| File | MODULE | Test functions |
|---|---|---|
| `tests/test_parser.py` | `test_parser` | `test_single_add_order`, `test_multi_beat_message`, `test_non_add_order_passthrough`, `test_back_to_back_messages` |
| `tests/test_parser_edge.py` | `test_parser_edge` | `test_min_length_message`, `test_body_len_exactly_6`, `test_body_len_7`, `test_body_len_8`, `test_body_len_14`, `test_truncated_in_idle`, `test_truncated_in_accumulate`, `test_back_to_back_no_idle`, `test_multiple_non_add_order_types`, `test_max_length_message`, `test_valid_invalid_interleave`, `test_boundary_prices`, `test_boundary_order_refs` |

RTL compiled: `lliu_pkg.sv`, `itch_field_extract.sv`, `itch_parser.sv`.
Tests send byte-accurate, 8-bytes-per-beat AXI4-Stream frames and check
`fields_valid`, `msg_valid`, `message_type`, `order_ref`, `side`, `price`.

#### `TOPLEVEL=feature_extractor`

| File | MODULE | Test functions |
|---|---|---|
| `tests/test_feature_extractor.py` | `test_feature_extractor` | `test_price_delta`, `test_side_encoding`, `test_order_flow_imbalance`, `test_feature_vector_format` |
| `tests/test_feat_edge.py` | `test_feat_edge` | `test_zero_price_input`, `test_max_price_input`, `test_negative_price_delta`, `test_negative_order_flow`, `test_order_flow_oscillation`, `test_small_magnitude_values`, `test_power_of_two_prices`, `test_large_price_delta_sweep` |

RTL compiled: `lliu_pkg.sv`, `feature_extractor.sv`.
Tests drive `fields_valid`, `price`, `side`, `order_ref` and read `features[0..3]`, `features_valid`.

#### `TOPLEVEL=axi4_lite_slave`

| File | MODULE | Test functions |
|---|---|---|
| `tests/test_axil_regmap.py` | `test_axil_regmap` | `test_write_all_registers`, `test_read_all_registers`, `test_write_to_readonly_registers`, `test_back_to_back_writes`, `test_back_to_back_reads` |

RTL compiled: `lliu_pkg.sv`, `axi4_lite_slave.sv`.
Register map: `CTRL=0x00`, `STATUS=0x04`, `WGT_ADDR=0x08`, `WGT_DATA=0x0C`, `RESULT=0x10`.
Unmapped reads return `0xDEADBEEF`.

---

### 3.3 Full-Pipeline Integration Tests

#### `TOPLEVEL=lliu_top`

RTL compiled: `lliu_pkg.sv` + all `*.sv` under `rtl/` (glob, excluding `lliu_pkg.sv`).

| File | MODULE | Test functions |
|---|---|---|
| `tests/test_smoke.py` | `test_smoke` | `test_single_inference`, `test_two_sequential_inferences` |
| `tests/test_constrained_random.py` | `test_constrained_random` | `test_random_100`, `test_random_coverage_closure` |
| `tests/test_backpressure.py` | `test_backpressure` | `test_periodic_stall`, `test_random_backpressure`, `test_pipeline_drain` |
| `tests/test_latency.py` | `test_latency` | `test_feature_latency_spec`, `test_end_to_end_latency_spec`, `test_latency_single`, `test_latency_sustained`, `test_latency_under_backpressure`, `test_jitter` |
| `tests/test_error_injection.py` | `test_error_injection` | `test_truncated_message`, `test_malformed_type`, `test_garbage_recovery` |
| `tests/test_replay.py` | `test_replay` | `test_replay_non_add_orders`, `test_replay_with_injected_add_orders` |
| `tests/test_wgtmem_outbuf.py` | `test_wgtmem_outbuf` | `test_weight_boundary_addresses`, `test_weight_overwrite`, `test_weight_data_bit_toggle`, `test_all_zero_weights`, `test_output_buffer_result_ready`, `test_output_buffer_holds_result`, `test_weight_reload_between_inferences` |
| `tests/test_integration_sweep.py` | `test_integration_sweep` | `test_back_to_back_inferences`, `test_soft_reset_mid_inference`, `test_weight_reload`, `test_pipeline_stall_resume`, `test_read_status_during_busy`, `test_alternating_buy_sell_sweep`, `test_non_add_order_at_top`, `test_zero_price_inference`, `test_hard_reset_recovery`, `test_ctrl_start_toggle` |

**Note on `test_replay`:** requires the sample data file
`data/tvagg_sample.bin` (real NASDAQ TotalView-ITCH 5.0 binary). If absent
the test will `FileNotFoundError` at the `feeder.parse_file(SAMPLE_FILE)` call.

**Note on `test_latency`:** respects `LLIU_MAX_LATENCY` env var (default 12 cycles)
for the end-to-end spec check.

---

### 3.4 Legacy / Not Recommended

| File | MODULE | Notes |
|---|---|---|
| `tests/test_arith.py` | — | Contains duplicate bfloat16_mul and fp32_acc tests. Can be run with `TOPLEVEL=bfloat16_mul` or `TOPLEVEL=fp32_acc`, but the two DUTs have incompatible port sets so this file mixes tests that target different toplevels — **use the dedicated files instead.** |

---

## 4. Quick-Reference Examples

```bash
# Run one arithmetic test
make TOPLEVEL=bfloat16_mul MODULE=tests.test_bfloat16_mul

# Run with VCD trace (always on — EXTRA_ARGS includes --trace)
make TOPLEVEL=itch_parser MODULE=tests.test_parser
# produces dump.vcd in tb/cocotb/

# Tighten latency budget (assert < 8 cycles instead of 12)
make TOPLEVEL=lliu_top MODULE=tests.test_latency LLIU_MAX_LATENCY=8
```

---

## 5. Support Infrastructure

### `tests/`

Python test modules. `MODULE=tests.<stem>` is always the convention.
Each file is independently importable; `sys.path.insert` points at the
parent `tb/cocotb/` directory so sibling packages (utils, drivers, etc.) resolve.

### `drivers/`

| File | Purpose |
|---|---|
| `axi4_lite_driver.py` | `AXI4LiteDriver` — async `read(addr)` / `write(addr, data)` over AXI4-Lite manager port |
| `axi4_lite_monitor.py` | Passive AXI4-Lite monitor |
| `axi4_stream_driver.py` | `AXI4StreamDriver` — `send(bytes)` splits into 8-byte beats with `tlast` |
| `axi4_stream_monitor.py` | Passive AXI4-Stream monitor |
| `itch_feeder.py` | `ITCHFeeder` — parses a binary ITCH 5.0 file and feeds messages via `AXI4StreamDriver` |

### `models/`

| File | Purpose |
|---|---|
| `golden_model.py` | `GoldenModel` — numpy dot-product reference used by `test_dot_product_engine.py` |

### `checkers/`

| File | Class | Monitors |
|---|---|---|
| `axi4_lite_checker.py` | `AXI4LiteChecker` | Protocol compliance on AXI4-Lite channel |
| `axi4_stream_checker.py` | `AXI4StreamChecker` | `tvalid`/`tready`/`tlast` handshake compliance |
| `dot_product_checker.py` | `DotProductChecker` | `result_valid`, accumulator monitoring in `dot_product_engine` |
| `parser_checker.py` | `ParserChecker` | `fields_valid` / `msg_valid` protocol in `itch_parser` |

### `scoreboard/`

| File | Class | Purpose |
|---|---|---|
| `scoreboard.py` | `Scoreboard` | FIFO-ordered expected vs. actual with configurable `tolerance` (relative) |

### `stimulus/`

| File | Class/Function | Purpose |
|---|---|---|
| `backpressure_gen.py` | `BackpressureGenerator` | Pattern-based inter-message delays (`periodic`, `random`, `none`) |
| `itch_adversarial.py` | `generate_truncated_message`, `generate_malformed_type`, `generate_garbage` | Malformed ITCH byte sequences for error-injection tests |
| `itch_random.py` | `ConstrainedRandomITCH` | Seeded random valid Add-Order message generator |
| `itch_replay.py` | `replay_itch_file` | Replay messages from a binary ITCH file |
| `weight_loader.py` | `load_weights`, `float_to_bfloat16` | Sequential AXI4-Lite writes to `WGT_ADDR`/`WGT_DATA` for all 4 weights |

### `utils/`

| File | Module | Key symbols |
|---|---|---|
| `bfloat16.py` | `utils.bfloat16` | `float_to_bfloat16`, `bfloat16_to_float`, `bfloat16_mul_ref`, `fp32_to_bits`, `bits_to_fp32` |
| `itch_decoder.py` | `utils.itch_decoder` | `encode_add_order`, `encode_system_event`, `decode_add_order`, `ADD_ORDER_LEN` |
| `latency_profiler.py` | `utils.latency_profiler` | `LatencyProfiler` — records ingress/egress cycle stamps, computes per-message latency |

---

## 6. RTL Source Mapping

```
rtl/lliu_pkg.sv          — package: types, parameters (always first in VERILOG_SOURCES)
rtl/bfloat16_mul.sv      — combinational BF16 multiplier (TOPLEVEL=bfloat16_mul)
rtl/fp32_acc.sv          — pipelined FP32 accumulator (TOPLEVEL=fp32_acc)
rtl/dot_product_engine.sv— 4-element dot product (TOPLEVEL=dot_product_engine)
rtl/itch_field_extract.sv— byte-lane field extraction
rtl/itch_parser.sv       — AXI4-Stream ITCH 5.0 parser (TOPLEVEL=itch_parser)
rtl/feature_extractor.sv — price_delta / side / order_flow / norm_price (TOPLEVEL=feature_extractor)
rtl/axi4_lite_slave.sv   — register map: CTRL, STATUS, WGT_ADDR, WGT_DATA, RESULT (TOPLEVEL=axi4_lite_slave)
rtl/weight_mem.sv        — 4-entry BF16 weight RAM (integrated only — no standalone TOPLEVEL)
rtl/output_buffer.sv     — result latch / result_ready flag (integrated only)
rtl/lliu_top.sv          — top-level integration (TOPLEVEL=lliu_top, uses all *.sv)
```

`weight_mem` and `output_buffer` have **no standalone make target** — they are
tested through `lliu_top` via `test_wgtmem_outbuf.py`.

---

## 7. Verilator Flags

Applied unconditionally:
- `--trace` — emit `dump.vcd` in `tb/cocotb/`
- `-Wno-IMPORTSTAR -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL`

Sim binary lands in `sim_build/Vtop`.

---

## 8. Common Failure Patterns

| Symptom | Likely cause |
|---|---|
| `result_valid never asserted` / `TimeoutError` in lliu_top tests | Weights not loaded before sending ITCH message — call `load_weights()` first |
| `fields_valid never asserted` | Message bytes out of order / wrong `tlast` placement; check `AXI4StreamDriver.send()` byte-order |
| Relative error exceeds tolerance (0.05) | Golden model not matching RTL `int_to_bf16` path — use the `int_to_bf16_ref()` helper defined in each test file, not a simple Python float cast |
| `FileNotFoundError: tvagg_sample.bin` | `data/tvagg_sample.bin` missing; `test_replay` tests require real ITCH binary at `data/` |
| `assert dead == 0xDEADBEEF` for unmapped AXI4-Lite read | RTL default read path not returning sentinel; read address > 0x10 with no mapping |
