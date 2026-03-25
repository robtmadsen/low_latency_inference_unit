---
name: run_uvm_test_suite
description: >
  Compile and run the UVM/Verilator testbench for the low_latency_inference_unit
  (LLIU) project. Use for: compiling the UVM testbench, running individual tests,
  running the full test suite, interpreting failures, or understanding the UVM
  testbench architecture.
applyTo: "tb/uvm/**"
---

# SKILL: Run UVM Test Suite

## 1. Testbench Root

```
tb/uvm/                     ← all commands must be run from here (or with -C tb/uvm)
├── Makefile
├── tb_top.sv               ← DUT + interfaces + UVM launch + SVA binds
├── axi4_stream_if.sv
├── axi4_lite_if.sv
├── agents/
│   ├── axi4_stream_agent/
│   └── axi4_lite_agent/
├── env/                    ← lliu_env, predictor, scoreboard, coverage
├── sequences/              ← weight_load, itch_replay, itch_random, backpressure, error, edge
├── tests/                  ← lliu_*_test.sv + lliu_test_pkg.sv
├── sva/                    ← 6 SVA bind modules
├── perf/                   ← lliu_latency_monitor.sv
├── golden_model/           ← dpi_bridge.c + golden_model.py (DPI-C, disabled by default)
└── sim_build/verilator/    ← Verilator build artefacts (auto-generated)
```

---

## 2. Prerequisites

### UVM_HOME

`UVM_HOME` must point to the Accellera UVM source tree (the directory containing `uvm_pkg.sv`).

```bash
export UVM_HOME=/Users/robertmadsen/Documents/projects/uvm-reference/src
```

Verify:
```bash
ls $UVM_HOME/uvm_pkg.sv   # must exist
```

### Python (for DPI-C golden model)

DPI-C is **disabled by default** (`+define+UVM_NO_DPI`). The `+GOLDEN_MODEL=` plusarg
is available for VCS/Questa only. No Python dependency when running with `SIM=verilator`.

---

## 3. Running the Full Regression (Preferred)

### Pre-flight: delete stale artifacts

> ⚠️ **MANDATORY before every regression run.** The following persist from prior runs
> and will give a false pass/fail picture if not deleted first:
>
> | File / Directory | Why it must be deleted |
> |---|---|
> | `tb/uvm/sim_build/verilator/` (entire directory) | Contains stale per-test `.log` files; old PASSED logs survive even when the new run FAILs |
> | `reports/uvm_results.xml` | Merged output from a previous regression |
>
> **The agent cannot run `rm -rf` (blocked by policy).** Tell the user:
> *"Please delete `tb/uvm/sim_build/verilator/` and `reports/uvm_results.xml` if they exist.
> Let me know when done."* Then **wait for confirmation** before proceeding.

### Run with the regression script

From the repo root:

```bash
export UVM_HOME=/Users/robertmadsen/Documents/projects/uvm-reference/src
python3 scripts/run_uvm_regression.py
```

This script:
1. Compiles the UVM testbench (`make compile`) — skipped with `--no-compile`.
2. Runs each of the 7 tests via `simv`, writing full logs to `tb/uvm/sim_build/verilator/<test>.log`.
3. Parses each log for verdict + UVM error/warning/fatal counts.
4. Writes `reports/uvm_results.xml` with a `<summary>` element at the top and one `<testcase>` per test.
5. Exits non-zero if any test failed.

Optional flags:

| Flag | Effect |
|---|---|
| `--no-compile` | Skip `make compile`; use existing `simv` binary |
| `--no-run` | Skip running tests; parse existing log files and produce the report only |
| `--output <path>` | Write XML to a custom path instead of `reports/uvm_results.xml` |

The merged report path to share with the user is: **`reports/uvm_results.xml`**

---

## 4. Compile (Manual / Partial Runs)

Compilation is done **once** per clean build. All UVM tests share the same binary.

```bash
cd tb/uvm
make SIM=verilator UVM_HOME=$UVM_HOME compile
```

This runs Verilator with `--binary --timing --trace -sv +define+UVM_NO_DPI`
and produces `sim_build/verilator/simv`.

> **Compile order (Makefile-managed):**
> `lliu_pkg.sv` → RTL sources → interfaces → agent packages → env package →
> seq package → test package → SVA bind modules → perf modules → `tb_top.sv`

After a clean compile, log is at `sim_build/verilator/compile.log`.
Recompilation is only needed after RTL or testbench source changes.

---

## 4. Run a Single Test

After compiling, run any test directly:

```bash
make SIM=verilator UVM_HOME=$UVM_HOME TEST=<test_name> run
```

Or invoke the binary directly (faster, skips Makefile dependency check):
```bash
sim_build/verilator/simv \
    +UVM_TESTNAME=<test_name> \
    +UVM_VERBOSITY=UVM_MEDIUM \
    +DATA_DIR=../../data \
    +GOLDEN_MODEL=golden_model/golden_model.py
```

### Optional plusargs

| Plusarg | Default | Effect |
|---|---|---|
| `+UVM_TESTNAME=` | `lliu_base_test` | Selects which UVM test class to run |
| `+UVM_VERBOSITY=` | `UVM_MEDIUM` | `UVM_NONE` / `UVM_LOW` / `UVM_MEDIUM` / `UVM_HIGH` / `UVM_FULL` |
| `+DATA_DIR=` | `../../data` | Path to directory containing `tvagg_sample.bin` (for replay test) |
| `+GOLDEN_MODEL=` | — | Path to `golden_model.py` (Verilator ignores, used by DPI-C in VCS mode) |

---

## 5. Complete Test Inventory

All tests extend `lliu_base_test`. Pass/fail is reported by `report_phase` using the
UVM report server error/fatal count; the simulation returns non-zero if any
`UVM_ERROR` or `UVM_FATAL` is raised.

| Test name | Class file | Purpose |
|---|---|---|
| `lliu_base_test` | `lliu_base_test.sv` | Baseline sanity — builds env, runs 100 µs of no-stimulus, checks for no errors |
| `lliu_smoke_test` | `lliu_smoke_test.sv` | Load weights → send 1 Add Order → poll result_ready → read RESULT reg; scoreboard checks |
| `lliu_replay_test` | `lliu_replay_test.sv` | Replay `data/tvagg_sample.bin` (real NASDAQ ITCH 5.0 data); scoreboard checks all Add Order inferences |
| `lliu_random_test` | `lliu_random_test.sv` | Constrained-random Add Orders (price ranges × buy/sell × order flow); 200 messages, scoreboard |
| `lliu_stress_test` | `lliu_stress_test.sv` | Back-to-back messages with random AXI4-Stream backpressure; checks throughput and latency bounds |
| `lliu_error_test` | `lliu_error_test.sv` | Injects truncated, malformed-type, and garbage byte sequences; checks parser recovery and no propagation |
| `lliu_coverage_test` | `lliu_coverage_test.sv` | Comprehensive functional coverage closure — runs all message type × price × side bins; checks coverage targets met |

> **`lliu_replay_test` dependency:** requires `data/tvagg_sample.bin`. If the file
> is absent the test will hit a `UVM_FATAL` when the ITCH feeder opens the file.

---

## 6. Running Individual Tests (Manual)

> For full regressions, prefer the script in Section 3. Use manual commands only
> for targeted single-test runs or debugging.

After compiling, run any test directly:

```bash
make SIM=verilator UVM_HOME=$UVM_HOME TEST=<test_name> run
```

Or invoke the binary directly (faster, skips Makefile dependency check):
```bash
sim_build/verilator/simv \
    +UVM_TESTNAME=<test_name> \
    +UVM_VERBOSITY=UVM_MEDIUM \
    +DATA_DIR=../../data \
    +GOLDEN_MODEL=golden_model/golden_model.py
```

Each run writes to `sim_build/verilator/<test_name>.log`.

Pass/fail is indicated by the UVM `report_phase` summary line:
```
UVM_INFO ... ** TEST PASSED **
```
or:
```
UVM_ERROR ... ** TEST FAILED **
```

---

## 7. Compile-Source Architecture

### Compile order (from Makefile `ALL_SV`)

```
rtl/lliu_pkg.sv                                   ← package (always first)
rtl/*.sv (excluding lliu_pkg.sv)                  ← RTL modules
tb/uvm/axi4_stream_if.sv                          ← interfaces
tb/uvm/axi4_lite_if.sv
tb/uvm/agents/axi4_stream_agent/axi4_stream_agent_pkg.sv
tb/uvm/agents/axi4_lite_agent/axi4_lite_agent_pkg.sv
tb/uvm/env/lliu_env_pkg.sv
tb/uvm/sequences/lliu_seq_pkg.sv
tb/uvm/tests/lliu_test_pkg.sv
tb/uvm/sva/*.sv                                   ← SVA bind modules (6)
tb/uvm/perf/lliu_latency_monitor.sv
tb/uvm/tb_top.sv                                  ← top-level (last)
```

### SVA bind modules (always active)

| Module | Bound to | Checks |
|---|---|---|
| `axi4_stream_sva` | `lliu_top` | `tvalid`/`tready`/`tlast` protocol compliance |
| `axi4_lite_sva` | `lliu_top` | AXI4-Lite handshake protocol compliance |
| `parser_sva` | `itch_parser` | FSM safety, `msg_valid` / `fields_valid` mutex |
| `dot_product_sva` | `dot_product_engine` | FSM sequence, `acc_clear` on start, `result_valid` pulse |
| `feature_latency_sva` | `lliu_top` | `parser_fields_valid` → `feat_valid` ≤ 5 cycles |
| `end_to_end_latency_sva` | `lliu_top` | Final AXI4-Stream beat → `dp_result_valid` < 12 cycles |

### Sequences available

| Sequence | Purpose |
|---|---|
| `weight_load_seq` | AXI4-Lite writes to `WGT_ADDR` + `WGT_DATA` for all 4 weights |
| `axil_rw_seq` / `axil_read_seq` | Generic AXI4-Lite read/write |
| `axil_poll_status_seq` | Poll `STATUS` register until `result_ready=1 && busy=0` |
| `itch_replay_seq` | Build and send encoded ITCH Add Order AXI4-Stream frames |
| `itch_random_seq` | Constrained-random Add Order generator |
| `backpressure_seq` | Inserts tready de-assertions at configurable intervals |
| `itch_error_seq` | Generates truncated / malformed / garbage ITCH byte sequences |
| `regmap_edge_seq` | Boundary-value AXI4-Lite register accesses |
| `arith_edge_seq` | Edge-case arithmetic stimulus (zero price, max price, etc.) |
| `itch_edge_seq` | Parser edge cases (short messages, non-Add-Order types, boundary fields) |

---

## 8. Common Failure Patterns

| Symptom | Likely cause |
|---|---|
| `UVM_HOME is not set` compile error | `export UVM_HOME=<path>` before calling make |
| `Couldn't open file uvm_pkg.sv` | `UVM_HOME` points to wrong directory — needs the `src/` subdirectory containing `uvm_pkg.sv` |
| `UVM_FATAL ... TIMEOUT` at 10ms | Infinite loop or stall in test — check scoreboard for prior errors; enable `UVM_HIGH` verbosity |
| `UVM_ERROR ... scoreboard mismatch` | RTL result differs from golden model; inspect `sim_build/verilator/<test>.log` |
| `UVM_FATAL ... tvagg_sample.bin` | `data/tvagg_sample.bin` missing; required by `lliu_replay_test` |
| `assert property` failure from SVA | Latency contract or protocol violation; backtrace in log shows exact cycle |
| `** TEST FAILED **` with no errors | `report_phase` saw errors printed before `run_phase` — search log for `UVM_ERROR` |
| Make `run` re-compiles unnecessarily | Use the binary directly: `sim_build/verilator/simv +UVM_TESTNAME=...` |
| `SVA: message pending for N cycles` with back-to-back messages | `itch_parser` not respecting `s_axis_tready` (AXI-S compliance bug) — both S_IDLE and S_ACCUMULATE must check `tvalid && tready` |
| `end_to_end_latency_sva` fires for non-Add-Order messages | SVA uses wrong trigger — must use `add_order_accepted` (connected to `parser_fields_valid`), not `s_axis_tlast` |

---

## 9. RTL Bugs Fixed During Baseline Bring-Up

Three RTL/TB issues were found and fixed before the baseline was stable:

### Fix 1 — `end_to_end_latency_sva.sv`: wrong trigger signal
**Symptom:** `replay_test`, `random_test`, `stress_test`, `coverage_test` all failed with SVA assertion "message pending for 12 cycles without `dp_result_valid`" immediately at simulation start.  
**Root cause:** The SVA was using `s_axis_tvalid && s_axis_tready && s_axis_tlast` as its timer start trigger — firing for **every** message type. Only Add-Order messages (`0x41`) produce `dp_result_valid`; System Event, Trade, etc. messages never do.  
**Fix:** Changed SVA input from three AXI-S signals to a single `add_order_accepted` port, connected to `parser_fields_valid` in the bind (which is already gated to Add-Order messages only by `itch_field_extract`). Same fix applied to `lliu_latency_monitor.sv`.

### Fix 2 — `itch_parser.sv`: not AXI-S compliant (ignored `tready`)
**Symptom:** Even after Fix 1, back-to-back Add-Order tests (`random_test`, `stress_test`, `coverage_test`) still failed. The SVA showed two `parser_fields_valid` pushes every 6 cycles, with only one pop per 12 cycles — queue depth growing unboundedly.  
**Root cause:** The parser's `always_ff` in S_IDLE and S_ACCUMULATE checked only `s_axis_tvalid`, ignoring `s_axis_tready`. In AXI-S, the receiver must not consume data when `tready=0`. The parser was greedily accumulating beats every clock as long as `tvalid=1`, regardless of `tready`.  
**Fix:** Changed `if (s_axis_tvalid)` → `if (s_axis_tvalid && s_axis_tready)` in both states.

### Fix 3 — `lliu_top.sv`: pipeline backpressure missing
**Symptom:** After Fix 2, the parser now respects `tready`, but back-to-back inference requests caused the dot-product engine to miss `dp_start` pulses (the sequencer returned to `SEQ_IDLE` 2 cycles before `dp_result_valid`, allowing the next message to be parsed and `feat_valid` to fire while the DPE was finishing in `S_DONE`).  
**Fix:** Added `pipeline_hold` signal: `assign pipeline_hold = feat_valid || (seq_state != SEQ_IDLE)`. Connected to `itch_parser` as a new `pipeline_hold` input that ANDs into `s_axis_tready`. This prevents new message accumulation from starting until the sequencer is proven idle and the current `feat_valid` pulse has been consumed. The `feat_valid` term in the hold condition is critical: it ensures `tready` drops to 0 immediately after the feature extractor registers its output (one clock before the sequencer transitions to `SEQ_PRELOAD`), closing the 1-cycle window where the next message could slip in.

