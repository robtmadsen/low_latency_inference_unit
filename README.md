# Low-Latency Inference Unit (LLIU)

[![CI](https://github.com/robtmadsen/low_latency_inference_unit/actions/workflows/ci.yml/badge.svg)](https://github.com/robtmadsen/low_latency_inference_unit/actions/workflows/ci.yml)

A hardware accelerator for real-time inference on streaming NASDAQ ITCH 5.0 market data, verified independently with both UVM and cocotb.

> **100% AI-agent built.** Every RTL module, testbench, golden model, CI workflow, and this README was authored by a GitHub Copilot agent — no hand-written code.

## What It Does

Parses live-format NASDAQ ITCH 5.0 binary data, extracts trading features, and runs single-sample inference through a pipelined bfloat16 dot-product engine with a verified full-path latency of fewer than 12 cycles at 300 MHz, measured from final AXI4-Stream beat accepted to `dp_result_valid`.

```
AXI4-Stream → ITCH Parser → Feature Extractor → Dot-Product Engine → Result
                                                       ↑
                                              AXI4-Lite (weights)
```

## RTL Architecture

| Module | Description |
|--------|-------------|
| `lliu_top` | System integrator, AXI interfaces, pipeline interconnect |
| `itch_parser` | Message alignment across AXI beats, type detection |
| `itch_field_extract` | Field extraction for Add Order: price, order ref, side |
| `feature_extractor` | Price normalization, order flow encoding |
| `dot_product_engine` | Pipelined MAC for small feature vectors |
| `bfloat16_mul` | bfloat16 multiplier |
| `fp32_acc` | float32 accumulator |
| `weight_mem` | Double-buffered on-chip SRAM for weights |
| `axi4_lite_slave` | Control plane: weight loading, config, result readout |
| `output_buffer` | Holds inference result for readout |

## Dual Verification

Both environments are fully independent and self-sufficient — each can verify the entire design alone. The goal is a head-to-head comparison of UVM vs cocotb.

### UVM (ASIC-Grade)

- AXI4-Stream + AXI4-Lite agents with full scoreboard
- DPI-C bridge to shared Python golden model (NumPy)
- Real ITCH data replay with synthetic Add Order injection
- Constrained-random ITCH sequences (price, side, shares constraints)
- Functional coverage model (message type, price range, side, cross-coverage)
- SVA bind files for protocol compliance and FSM safety (AXI4-Lite, AXI4-Stream, dot-product, parser)
- Backpressure sequences, error injection, stress tests
- Smoke, replay, random, error, and stress test classes
- Cycle-accurate latency profiling monitor (bind module, reports min/max/mean/median/p99/stddev)

### cocotb (Python-Native)

- AXI4-Stream + AXI4-Lite drivers/monitors with transaction scoreboard
- Shared golden model called natively from Python
- Block-level and system-level tests via Makefile TOPLEVEL selection
- Protocol compliance checkers (AXI4-Stream, AXI4-Lite, parser, dot-product)
- Functional coverage with bin tracking and cross-coverage reporting
- Constrained-random stimulus with adversarial edge cases
- Backpressure modeling and error injection tests
- Latency profiler with histogram + statistical report (min/max/mean/p99/stddev)
- End-to-end latency contract check for final AXI beat accepted to `dp_result_valid` (< 12 cycles)
- 12 test modules covering all RTL blocks and system scenarios

### Shared

- **Golden model**: Single Python/NumPy reference used by both environments
- **Sample data**: Real NASDAQ ITCH 5.0 binary (`data/tvagg_sample.bin`) from [NASDAQ TotalView-ITCH](https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/)

## CI

GitHub Actions runs on every push and PR to `main`. All jobs use Verilator 5.046 built from source (cached).

| Job | What it does |
|-----|-------------|
| **lint** | `verilator --lint-only` on all RTL |
| **cocotb** | 7-job test matrix (block-level + system-level) via cocotb 2.0 + Verilator |
| **uvm** | Compile + run `lliu_base_test` and `lliu_smoke_test` with the bound end-to-end latency checker via Verilator |

Primary performance contract in CI:

- Full hardware datapath latency: final AXI4-Stream beat accepted to `dp_result_valid` in fewer than 12 cycles
- Stage-level latency: `parser_fields_valid` to `feat_valid` in fewer than 5 cycles

Waveforms (VCD) are uploaded as artifacts on UVM test failure.

## Project Structure

```
rtl/                          # SystemVerilog RTL
tb/
├── uvm/                      # UVM testbench (VCS / Verilator)
└── cocotb/                   # cocotb testbench (Verilator)
data/
├── tvagg_sample.bin          # Decompressed ITCH 5.0 binary (~3.7 MB)
└── tvagg_sample.gz           # Compressed source
.github/workflows/ci.yml     # CI pipeline
```

## Toolchain

| Category | Tool |
|----------|------|
| HDL | SystemVerilog 2017 |
| Simulation | Verilator 5.046 / Synopsys VCS |
| UVM Verification | Accellera uvm-core (IEEE 1800.2), DPI-C |
| cocotb Verification | cocotb 2.0+, Python 3.12, NumPy |
| CI | GitHub Actions (Ubuntu), Verilator built from source |

## v1 DUT — First Iteration Complete

The first complete DUT iteration is archived under [`reports/v1_dut/`](reports/v1_dut/).

### What It Was

A minimal but end-to-end ITCH 5.0 inference pipeline: ITCH parser → field extractor → feature extractor → bfloat16 dot-product engine → AXI4-Lite result readout. 11 RTL modules, ~1,340 RTL LOC, parameterised for a 4-element feature vector.

### Verification Summary

Both testbenches achieved **100% line coverage** independently.

| Metric | cocotb | UVM |
|--------|--------|-----|
| Tests | 113 tests, 18 suites | 6 tests |
| Line coverage | 100% (502 / 502 lines) | 100% (449 / 449 lines) |
| Baseline line coverage (before closure) | 91.4% | 91.4% |

> Coverable line counts differ because UVM closed 13 pragma-excluded lines vs. 8 for cocotb.

#### cocotb test suites (113 tests, 18 suites)

| Suite | Tests |
|-------|------:|
| `bfloat16_mul` | 2 |
| `bfloat16_mul` edge cases | 12 |
| `fp32_acc` | 2 |
| `fp32_acc` edge cases | 21 |
| `dot_product_engine` | 3 |
| `itch_parser` | 4 |
| `itch_parser` edge cases | 13 |
| `feature_extractor` | 4 |
| `feature_extractor` edge cases | 8 |
| `axi4_lite_slave` register map | 11 |
| `lliu_top` smoke | 2 |
| `lliu_top` constrained random | 2 |
| `lliu_top` backpressure | 3 |
| `lliu_top` latency contract | 4 |
| `lliu_top` error injection | 3 |
| `lliu_top` replay | 2 |
| `lliu_top` weight mem / output buffer | 7 |
| `lliu_top` integration sweep | 10 |

#### UVM tests (6 tests)

| Test | Strategy |
|------|----------|
| `lliu_smoke_test` | Single order, basic sanity |
| `lliu_random_test` | Random orders with fixed weights |
| `lliu_replay_test` | Captured ITCH data replay |
| `lliu_error_test` | AXI protocol error injection |
| `lliu_stress_test` | High-throughput with backpressure |
| `lliu_coverage_test` | Hybrid constrained-random + directed |

### Mutation Testing — 10/10 Bugs Detected (Both TBs)

10 bugs were injected one at a time; both testbenches detected all 10 (100% kill rate).

| Bug | Module | Mutation |
|-----|--------|----------|
| 1 | `itch_parser` | Byte-swapped length prefix |
| 2 | `itch_parser` | ACCUMULATE stride 7 instead of 8 |
| 3 | `itch_field_extract` | Price MSB off-by-one byte |
| 4 | `itch_field_extract` | Side decode checks `'S'` not `'B'` |
| 5 | `feature_extractor` | Price delta uses `+` instead of `−` |
| 6 | `feature_extractor` | Side encoding sign inverted |
| 7 | `bfloat16_mul` | Exponent bias 126 instead of 127 |
| 8 | `fp32_acc` | Accumulator clear disabled |
| 9 | `dot_product_engine` | Early termination at element N−2 |
| 10 | `weight_mem` | Read address stuck at 0 |

Full campaign notes: [`reports/v1_dut/bug_detection.md`](reports/v1_dut/bug_detection.md)

---

## Design Choices


- **ITCH 5.0**: Real HFT protocol, not a toy — validated against actual NASDAQ sample data
- **bfloat16 multiply + float32 accumulate**: Mixed-precision arithmetic used in production ML accelerators
- **Batch size = 1**: Latency-optimized for HFT, not throughput-optimized for training
- **Small inference engine**: Verification is the focus, not model complexity
