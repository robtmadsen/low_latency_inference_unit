# Low-Latency Inference Unit (LLIU)

[![CI](https://github.com/robtmadsen/low_latency_inference_unit/actions/workflows/ci.yml/badge.svg)](https://github.com/robtmadsen/low_latency_inference_unit/actions/workflows/ci.yml)

A hardware accelerator for real-time inference on streaming NASDAQ ITCH 5.0 market data, verified independently with both UVM and cocotb, and now being brought up on a Xilinx Kintex-7 XC7K160T FPGA.

> **100% AI-agent built.** Every RTL module, testbench, golden model, CI workflow, and this README was authored by a GitHub Copilot agent — no hand-written code.

## What It Does

Parses live-format NASDAQ ITCH 5.0 binary data from a 10GbE feed, extracts trading features, and runs single-sample inference through a pipelined bfloat16 dot-product engine. The v1 simulation-only core has a verified full-path latency of fewer than 12 cycles at 300 MHz (final AXI4-Stream beat accepted → `dp_result_valid`). The v2 work brings the same core to real hardware via a full UDP/IP network stack.

**v1 — simulation core (complete)**
```
AXI4-Stream → ITCH Parser → Feature Extractor → Dot-Product Engine → Result
                                                       ↑
                                              AXI4-Lite (weights)
```

**v2 — XC7K160T FPGA (in progress)**
```
SFP+ 10GbE → eth_mac_phy_10g → ip_complete_64 → udp_complete_64
    → [async FIFO] → MoldUDP64 strip → Symbol Filter
    → ITCH Parser → Feature Extractor → Dot-Product Engine → Result
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
rtl/                          # SystemVerilog RTL (v1 core + v2 new modules)
syn/                          # Synthesis & P&R scripts, constraints, bitstream
tb/
├── uvm/                      # UVM testbench (VCS / Verilator)
└── cocotb/                   # cocotb testbench (Verilator)
data/
├── tvagg_sample.bin          # Decompressed ITCH 5.0 binary (~3.7 MB)
└── tvagg_sample.gz           # Compressed source
.github/
├── arch/                     # Architecture specifications
│   ├── v1/                   # Simulation-core arch docs
│   │   ├── SPEC.md           # System specification
│   │   ├── RTL_ARCH.md       # RTL module hierarchy
│   │   ├── COCOTB_ARCH.md    # cocotb testbench architecture
│   │   └── UVM_ARCH.md       # UVM testbench architecture
│   └── kintex-7/
│       └── Kintex-7_MAS.md   # KC705 micro-architectural spec
├── plan/                     # Per-target implementation plans
│   └── kintex-7/
│       ├── RTL_PLAN_kintex-7.md
│       ├── COCOTB_PLAN_kintex-7.md
│       ├── UVM_PLAN_kintex-7.md
│       └── BACKEND_PLAN_kintex-7.md
├── agents/                   # VS Code agent mode definitions
└── workflows/ci.yml          # CI pipeline
reports/v1_dut/               # Archived v1 coverage, results, waveforms
```

## Toolchain

| Category | Tool |
|----------|------|
| HDL | SystemVerilog 2017 |
| Simulation | Verilator 5.046 / Synopsys VCS |
| UVM Verification | Accellera uvm-core (IEEE 1800.2), DPI-C |
| cocotb Verification | cocotb 2.0+, Python 3.12, NumPy |
| RTL Synthesis | Yosys (`synth_xilinx`) + Vivado ML Standard |
| Place & Route | Vivado ML Standard (free tier), Vivado 2025.2 manually installed on AWS EC2 `c5.4xlarge` (FPGA Developer AMI, SSH alias `lliu-par`) |
| Target FPGA | Xilinx Kintex-7 (`xc7k160tffg676-2`) |
| Network Library | verilog-ethernet (Forencich) |
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

## v2 DUT — Kintex-7 KC705 Bring-up (In Progress)

With v1 complete (100% line coverage, 10/10 mutation kill rate on both testbenches), the design is advancing to real FPGA hardware.

### What's New

The v1 LLIU core is unchanged. v2 wraps it in a complete 10GbE receive stack connecting an SFP+ cage to the existing ITCH parser. The network stack and pre-processing all run in the **156.25 MHz** GTX clock domain; only clean, validated ITCH data crosses the async FIFO into the **300 MHz** application domain.

| Layer | Domain | Module | Role |
|-------|--------|--------|------|
| Physical + MAC | 156.25 MHz | `eth_mac_phy_10g` (Forencich) | 64b/66b, CRC32, GTX SERDES |
| Ethernet RX | 156.25 MHz | `eth_axis_rx` (drop-on-full wrapper) | Frame → payload; drops whole frames when FIFO is almost full |
| IP | 156.25 MHz | `ip_complete_64` | IPv4 checksum, multicast filter |
| UDP | 156.25 MHz | `udp_complete_64` | Port filter → raw datagram |
| Pre-FIFO (new) | 156.25 MHz | `moldupp64_strip` | Strip 20-byte MoldUDP64 header; validate & drop on bad/duplicate seq number |
| CDC | crossing | `axis_async_fifo` | 156.25 MHz → 300/250 MHz; drop-on-full policy prevents MAC stall |
| App (new) | 300/250 MHz | `symbol_filter` | LUT-CAM watchlist (64 entries, single-cycle match); gates inference engine |
| App (existing) | 300/250 MHz | LLIU v1 core | ITCH parse → feature extract → dot-product inference → result |

Full micro-architectural specification: [`.github/arch/kintex-7/Kintex-7_MAS.md`](.github/arch/kintex-7/Kintex-7_MAS.md)

### Clock Domains

| Domain | Frequency | Scope |
|--------|-----------|-------|
| `clk_156` | 156.25 MHz | GTX + Forencich network stack + pre-FIFO processing |
| `clk_300` | 300 MHz (target) | Application hot path (LLIU core) |
| `clk_250` | 250 MHz (fallback) | Used if 300 MHz P&R fails timing on DSP columns |

### Synthesis Target

The original v2 target was the KC705 board (`xc7k325tffg900-2`). During backend bring-up, two blockers disqualified it:

1. **Vivado licensing.** The XC7K325T is not on the Vivado ML Standard free device list — it requires Vivado Enterprise (≈ $4,400/year).
2. **No open-source P&R path.** The only free alternative, nextpnr-xilinx, relies on the Project X-Ray reverse-engineered bitstream database (`prjxray-db`). The XC7K325T fabric was never reverse-engineered and is absent from the database entirely, ruling out nextpnr-xilinx.

The project switched to the **`xc7k160tffg676-2`**, which satisfies all requirements:

| Requirement | How `xc7k160tffg676-2` meets it |
|-------------|--------------------------------|
| Free toolchain | On the Vivado ML Standard free device list (AMD UG973, 2025.x) |
| 10GbE | Has GTX transceivers — supports 10GBASE-R SFP+ directly |
| Enough fabric | 101,440 LUTs / 600 DSP48E1 / 162 RAMB36E1 vs < 5,000 LUTs and 0 DSPs currently used |
| Cloud P&R | AWS FPGA Developer AMI ships Vivado pre-installed; `c5.4xlarge` handles the full flow in batch mode without a GUI |

P&R is run on an AWS EC2 `c5.4xlarge` instance (FPGA Developer AMI) over SSH, keeping the local machine free of a Vivado install. The FPGA Developer AMI ships with an older Vivado version; Vivado 2025.2 was manually installed on the instance to get Kintex-7 `xc7k160tffg676-2` support on the free tier. The RTL top module retains the `kc705_top` name from its original development context.

- Device: `xc7k160tffg676-2`
- Synthesis top: `lliu_top`
- Toolchain: Yosys (pre-Vivado utilization preview) → Vivado ML Standard 2025.2 (synthesis, P&R, bitstream), running on AWS EC2 `c5.4xlarge` (FPGA Developer AMI) via SSH (`lliu-par`)
- Constraints: `syn/constraints_lliu_top.xdc` (300 MHz clock, false paths on all AXI I/Os)
- Timing target: 300 MHz; fallback to 250 MHz if `dot_product_engine` DSP routing fails — a stable 250 MHz with zero slack violations is preferable to an unreliable 300 MHz clock

### P&R Run History

| Run | RTL | LUTs | FFs | WNS @ 300 MHz | fmax | Critical path |
|-----|-----|------|-----|---------------|------|---------------|
| 1 | `fp32_acc` 1-stage | 1,599 | 417 | −6.188 ns | ≈ 105 MHz | `fp32_acc` CARRY4 chain (25 levels) |
| 2 | `fp32_acc` 3-stage | 1,534 | 534 | −2.322 ns | ≈ 177 MHz | `itch_parser`→`feature_extractor` (18 levels) |

**Run 1 critical path:** `fp32_acc` CARRY4 chain — 25 logic levels, 9.228 ns data path. Root cause: single combinational block combining exponent compare, mantissa alignment, and accumulate add.

**Run 2 critical path** (after 3-stage `fp32_acc` fix): combinational decode path from `itch_parser` message buffer through `itch_field_extract` arithmetic into `feature_extractor/features_reg` — 18 logic levels, 5.604 ns. Fix: register the `itch_field_extract` outputs at the module boundary (escalated to `rtl_engineer`).

Hold slack is met in both runs; routing is complete with 0 unrouted nets. Bitstream generation is blocked by missing board I/O pin assignments (expected).

### New RTL Modules (v2)

| Module | Description |
|--------|-------------|
| `moldupp64_strip` | Runs at 156.25 MHz. Absorbs the 20-byte MoldUDP64 header; validates sequence numbers; drops duplicate/malformed datagrams before the FIFO; outputs `seq_num` register for gap detection |
| `eth_axis_rx_wrap` | Wraps the Forencich `eth_axis_rx`; asserts drop-on-full when `axis_async_fifo.almost_full` is high; increments `dropped_frames` counter exposed via AXI4-Lite |
| `symbol_filter` | LUT-CAM: 64 × 64-bit registers, parallel equality reduction, single-cycle `watchlist_hit`; loaded via AXI4-Lite; ~512 LUTs + 4,096 FFs |
| `kc705_top` | KC705 top-level: GTX pins, MMCM (300/250 MHz), dual sync-resets, Forencich stack, LLIU core |

---

## Design Choices


- **ITCH 5.0**: Real HFT protocol, not a toy — validated against actual NASDAQ sample data
- **bfloat16 multiply + float32 accumulate**: Mixed-precision arithmetic used in production ML accelerators
- **Batch size = 1**: Latency-optimized for HFT, not throughput-optimized for training
- **Small inference engine**: Verification is the focus, not model complexity
