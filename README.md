# Low-Latency Inference Unit (LLIU)

[![CI](https://github.com/robtmadsen/low_latency_inference_unit/actions/workflows/ci.yml/badge.svg)](https://github.com/robtmadsen/low_latency_inference_unit/actions/workflows/ci.yml)

A hardware accelerator for real-time inference on streaming NASDAQ ITCH 5.0 market data, verified independently with both UVM and cocotb.

## What It Does

Parses live-format NASDAQ ITCH 5.0 binary data, extracts trading features, and runs single-sample inference through a pipelined bfloat16 dot-product engine — all in under 5 cycles at 300 MHz.

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

**Remaining:** Cycle-accurate latency + jitter profiling monitor

### cocotb (Python-Native)

- AXI4-Stream + AXI4-Lite drivers/monitors with transaction scoreboard
- Shared golden model called natively from Python
- Block-level and system-level tests via Makefile TOPLEVEL selection
- Protocol compliance checkers (AXI4-Stream, AXI4-Lite, parser, dot-product)
- Functional coverage with bin tracking and cross-coverage reporting
- Constrained-random stimulus with adversarial edge cases
- Backpressure modeling and error injection tests
- 12 test modules covering all RTL blocks and system scenarios

**Remaining:** Latency profiler and latency + jitter tests

### Shared

- **Golden model**: Single Python/NumPy reference used by both environments
- **Sample data**: Real NASDAQ ITCH 5.0 binary (`data/tvagg_sample.bin`) from [NASDAQ TotalView-ITCH](https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/)

## CI

GitHub Actions runs on every push and PR to `main`. All jobs use Verilator 5.046 built from source (cached).

| Job | What it does |
|-----|-------------|
| **lint** | `verilator --lint-only` on all RTL |
| **cocotb** | 6-module test matrix (17 tests) via cocotb 2.0 + Verilator |
| **uvm** | Compile + run `lliu_base_test` and `lliu_smoke_test` via Verilator |

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

## Design Choices

- **ITCH 5.0**: Real HFT protocol, not a toy — validated against actual NASDAQ sample data
- **bfloat16 multiply + float32 accumulate**: Mixed-precision arithmetic used in production ML accelerators
- **Batch size = 1**: Latency-optimized for HFT, not throughput-optimized for training
- **Small inference engine**: Verification is the focus, not model complexity
