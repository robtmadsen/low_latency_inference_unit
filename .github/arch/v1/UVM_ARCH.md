# UVM Testbench Architecture

> **Implementation plan:** [UVM_PLAN.md](../plan/UVM_PLAN.md) · **Master plan:** [MASTER_PLAN.md](../plan/MASTER_PLAN.md) · **Spec:** [SPEC.md](SPEC.md)

## Phase 4 v2 Experiment Results (2026-05-15)

Autonomous UVM testbench built and run by Claude Code (`claude-opus-4-6`, `--bare`) on Azure VM `vm-uvm` (Standard_D2s_v5). Results in `reports/v2_uvm/`.

| Metric | Result |
|--------|--------|
| Simulator | Verilator 5.046 |
| UVM framework | Accellera UVM (UVM_HOME set at runtime) |
| Test | `hft_base_test` — full ITCH→inference→OUCH pipeline |
| OUCH packets checked | 80 / 80 pass, 0 fail |
| UVM_ERROR | 0 |
| UVM_FATAL | 0 |
| RTL line coverage | **100.0%** (2362/2362 lines, all 22 DUT modules) |
| RTL bugs found | **9** (see `reports/v2_uvm/bugs_found.md`) |

### Actual Implementation (v2)

The agent built a **monolithic single-file testbench** (`tb/uvm/tb_top.sv`, ~82 KB) rather than the multi-file structure planned below. The implementation includes:

- UVM agent (driver + monitor + sequencer) for ITCH ingress over AXI4-Stream
- AXI4-Lite driver for weight loading, symbol filter, strategy/risk config
- Scoreboard with inline reference model (no DPI-C — Verilator constraint)
- 17 stimulus phases covering Add/Execute/Cancel/Delete/Replace orders, multi-symbol, back-pressure, sequence gaps, malformed frames, edge values, coverage-targeted direct forcing
- Coverage script: `tb/uvm/calc_rtl_cov.py` parses Verilator `.dat` coverage files → `reports/coverage.txt`

### Bugs Found (9)

| # | Module | Description |
|---|--------|-------------|
| 1 | `itch_parser_v2` | Off-by-one in ACCUMULATE→EMIT (`>` vs `>=`) |
| 2 | `itch_parser_v2` | Price field 1-byte offset error (indices 33:36 vs 32:35) |
| 3 | `order_book` | BBO bid comparison inverted (`<` vs `>`) |
| 4 | `ouch_engine` | Shares/price fields swapped in OUCH beat assembly |
| 5 | `itch_parser_v2` | `sym_id` hardcoded to 0 (multi-symbol broken) |
| 6 | `feature_extractor_v2` | Order flow counter increment direction inverted |
| 7 | `ouch_engine` | Back-pressure watchdog threshold 1 vs spec 64 |
| 8 | `lliu_top_v2` | `pipeline_hold` hardcoded to 0 (debug override not reverted) |
| 9 | `kc705_top` | `fifo_almost_full` threshold 127 vs spec 64 |

---

## Design Philosophy

This is a **fully self-sufficient** verification environment — not a complement to the cocotb TB, but an independent, parallel effort capable of complete verification on its own. The goal is to enable a direct head-to-head comparison of UVM vs cocotb as DV methodologies applied to the same RTL.

## Directory Structure

```
tb/uvm/
├── agents/
│   ├── axi4_stream_agent/        # Driver, monitor, sequencer for ITCH ingress
│   └── axi4_lite_agent/          # Driver, monitor, sequencer for control plane
├── env/
│   ├── lliu_env.sv               # Top environment (agents + scoreboard + coverage)
│   ├── lliu_scoreboard.sv        # Compares DUT output to golden model
│   ├── lliu_coverage.sv          # Functional coverage: msg types × prices × side
│   └── lliu_predictor.sv         # Reference model wrapper (DPI-C → Python)
├── sequences/
│   ├── itch_replay_seq.sv        # Replay real ITCH binary from data/
│   ├── itch_random_seq.sv        # Constrained-random Add Order generation
│   ├── itch_error_seq.sv         # Malformed / truncated messages
│   ├── weight_load_seq.sv        # AXI4-Lite weight preload
│   └── backpressure_seq.sv       # Stall / burst patterns
├── tests/
│   ├── lliu_base_test.sv         # Base test: build env, default config
│   ├── lliu_smoke_test.sv        # Single Add Order → verify output
│   ├── lliu_replay_test.sv       # Real ITCH data replay
│   ├── lliu_stress_test.sv       # Back-to-back + backpressure
│   └── lliu_error_test.sv        # Error injection scenarios
├── sva/
│   ├── axi4_stream_sva.sv        # AXI4-Stream protocol compliance
│   ├── axi4_lite_sva.sv          # AXI4-Lite protocol compliance
│   ├── parser_sva.sv             # Parser FSM safety, latency bounds
│   └── dot_product_sva.sv        # Engine timing, accumulator safety, no deadlock
├── golden_model/
│   ├── golden_model.py           # NumPy reference: parse → features → inference (shared source of truth)
│   └── dpi_bridge.c              # DPI-C wrapper to call Python golden model
├── perf/
│   └── lliu_latency_monitor.sv   # Cycle-accurate latency + jitter profiling
├── tb_top.sv                     # Top-level: clock, reset, DUT instantiation, interface binding
└── Makefile                      # Sim targets for VCS / Verilator
```

## Key Architecture Decisions

### 1. Two Agents, One Env

AXI4-Stream drives the ITCH ingress, AXI4-Lite drives control. Both live in a single `lliu_env` for system-level tests. Block-level envs aren't needed initially since the pipeline is a straight shot.

### 2. Scoreboard via DPI-C

The predictor calls Python through a DPI-C bridge, so the golden model is shared with cocotb. One source of truth for bit-accurate math.

### 3. Sequences Own the Stimulus Strategy

Replay vs. random vs. error injection are separate sequences, composed freely in tests. The replay sequence reads `data/tvagg_sample.bin` directly.

### 4. SVA Binds Externally

Assertions in separate files, bound to DUT interfaces in `tb_top.sv`. Keeps RTL clean and lets SVA be toggled per-sim.

### 5. Coverage is Centralized

Cross-coverage of message type × price range × side × backpressure state lives in `lliu_coverage.sv`, sampled from the monitor transactions.

### 6. Latency / Jitter Profiling

`lliu_latency_monitor.sv` timestamps every message at AXI4-Stream ingress and result readout. Reports:
- Per-message cycle count
- Min / max / mean
- Percentiles (p50, p99, p99.9)
- Jitter (stddev)

This ensures UVM can independently answer performance questions without deferring to cocotb.

### 7. Golden Model is Shared

`golden_model/golden_model.py` is the **same** Python code that cocotb calls natively. UVM calls it via DPI-C. One source of truth for bit-accurate math validation across both methodologies.

## Block-Level vs System-Level

Start system-level (stimulus in → result out) since the pipeline stages are tightly coupled. Block-level envs can be factored out later by reusing the same agents against individual module `TOPLEVEL` targets.

## Verification Completeness

This UVM environment independently covers all verification goals:

| Verification Goal               | UVM Implementation                        |
|---------------------------------|-------------------------------------------|
| Protocol compliance             | SVA bind files in `sva/`                  |
| Bit-accurate correctness        | `lliu_scoreboard.sv` + DPI-C golden model |
| Constrained-random stimulus     | `itch_random_seq.sv`                      |
| Functional coverage closure     | `lliu_coverage.sv`                        |
| Real data replay                | `itch_replay_seq.sv` + `data/`            |
| Error injection                 | `itch_error_seq.sv`                       |
| Latency / jitter profiling      | `perf/lliu_latency_monitor.sv`            |
| Backpressure handling           | `backpressure_seq.sv`                     |
| Block-level isolation           | Reusable agents, per-module TOPLEVEL      |
| System-level integration        | `lliu_replay_test.sv`, `lliu_stress_test.sv` |

## Compute-Block Verification Focus

The inference block is intentionally small enough that UVM can verify it exhaustively at block level:

- Weight load sequencing into a compact register file or SRAM bank
- Fixed-length dot-product correctness against the shared NumPy model
- Accumulator reset, saturation, and result-valid timing checks
- Latency bounds from feature arrival to inference result

## CI Integration

The UVM testbench runs in GitHub Actions CI via Verilator on every push and PR.

**CI targets (Verilator):**
- `lliu_smoke_test` — single Add Order, basic sanity
- `lliu_replay_test` — real ITCH data replay with scoreboard checking
- `lliu_stress_test` — back-to-back + backpressure

**Local-only targets (VCS):**
- Full SVA evaluation (Verilator evaluates a subset of SVA; VCS is needed for complete bind-file assertion checking)
- `lliu_error_test` with detailed protocol violation SVA reporting
- Functional coverage merge and HTML report generation

The Makefile supports both simulators:

```
make SIM=verilator test    # CI-compatible, runs on GitHub Actions
make SIM=vcs test          # Full regression with SVA, local only
```

**DPI-C in CI:** The Python golden model bridge requires `libpython3.12` at link time. The CI workflow installs Python 3.12 and sets `PYTHONHOME` before Verilator elaboration.
