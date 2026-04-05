# Low-Latency Inference Unit (LLIU)

[![CI](https://github.com/robtmadsen/low_latency_inference_unit/actions/workflows/ci.yml/badge.svg)](https://github.com/robtmadsen/low_latency_inference_unit/actions/workflows/ci.yml)

A hardware accelerator for real-time inference on streaming NASDAQ ITCH 5.0 market data, verified independently with both UVM and cocotb, and synthesized and placed-and-routed on a Xilinx Kintex-7 XC7K160T FPGA.

> **100% AI-agent built.** Every RTL module, testbench, golden model, CI workflow, and this README was authored by a GitHub Copilot agent — no hand-written code.

---

## v2.0 — Full HFT Trading System (Planning)

Spec: [`.github/arch/kintex-7/2p0_kintex-7_MAS.md`](.github/arch/kintex-7/2p0_kintex-7_MAS.md)

Expands the timing-closed inference core into a complete trading system targeting 75–85% LUT utilization of the XC7K160T. Clock derived as 312.5 MHz (156.25 × 2) from the GTP reference, eliminating async-FIFO synchronization penalty between network and application domains.

### What's New Over v1 Kintex-7

| Capability | v1 Kintex-7 | v2.0 |
|------------|-------------|------|
| Market data | ITCH Add Order only | Full ITCH 5.0 (8 message types) |
| Order book state | None (stateless) | L3 full-depth, top 500 symbols |
| Inference engines | 1 × LLIU | 8 × LLIU (`FEATURE_VEC_LEN=32`, `HIDDEN_LAYER=32`) |
| Output | `dp_result_valid` flag | NASDAQ OUCH 5.0 packet out (template + hot-patch) |
| Risk controls | None | Price band, position limits, fat-finger, kill switch |
| Timestamping | None | 64-bit PTP v2, local sub-counter per tap (fanout mitigation) |
| Latency visibility | Cycle-count DV only | On-chip histograms (5 ns bins, P50/P99 per core) |
| Host interface | None | PCIe Gen2 ×4, DMA snapshot engine |
| Clock | 300 MHz | 312.5 MHz (156.25 × 2, period = 3.2 ns) |
| BRAM | 0 tiles | ~280 tiles (87%) — dominated by 128K-entry order-ref hash table |
| DSP48E1 | 1 | ~550 (92%) |
| LUT estimate | 1,172 | ~78,000 (77%) |

### Phase plan

| Phase | Goal | Key modules |
|-------|------|-------------|
| 1 | Order book + PTP measurement infrastructure | `itch_parser_v2`, `order_book`, `ptp_core`, `timestamp_tap`, `latency_histogram` |
| 2 | OUCH output + risk controls | `feature_extractor_v2`, 8× `lliu_core`, `risk_check`, `ouch_engine` |
| 3 | PCIe DMA + host integration | `pcie_dma_engine`, BBO snapshot, Linux driver stub |

**Key timing discipline for v2:** Pblock constraints required from Run 1. DSP columns are fixed-position; 550 DSPs at 312.5 MHz will not close timing with organic placement. Each `lliu_core` gets its own clock-region Pblock; `order_book` BRAMs placed in adjacent stripe. `report_cdc` must pass zero CRITICAL/HIGH crossings before any run is accepted (§6.1 of spec).

---

## v1 Kintex-7 — 300 MHz P&R Timing Closed ✅

**Status: Complete.** RTL changes were driven entirely by backend timing requirements (P&R iterations on `xc7k160tffg676-2`). Coverage closure and mutation testing were not performed for this iteration; those campaigns belong to the v1 simulation-core DUT below.

**v1 pipeline**
```
AXI4-Stream → ITCH Parser → Feature Extractor → Dot-Product Engine → Result
                                                       ↑
                                              AXI4-Lite (weights)
```

**v2 (Kintex-7) data path**
```
SFP+ 10GbE → eth_mac_phy_10g → [MoldUDP64 strip] → Symbol Filter
    → ITCH Parser → Feature Extractor → Dot-Product Engine → Result
```

### Synthesis Target

Original v2 target was the KC705 board (`xc7k325tffg900-2`). Two blockers disqualified it:

1. **Vivado licensing.** `xc7k325t` is not on the Vivado ML Standard free device list.
2. **No open-source P&R path.** nextpnr-xilinx/Project X-Ray has no `xc7k325t` database.

Switched to **`xc7k160tffg676-2`**: on the Vivado ML Standard free list, has GTX transceivers for 10GBASE-R SFP+, and is supported by the AWS FPGA Developer AMI. P&R runs on an EC2 `c5.4xlarge` over SSH (`lliu-par`), with Vivado 2025.2 manually installed.

- Synthesis top: `lliu_top` (RTL module) / `kc705_top` (chip-level wrapper, name kept from original development)
- Toolchain: Yosys (pre-Vivado utilization preview) → Vivado ML Standard 2025.2
- Constraints: `syn/constraints_lliu_top.xdc` (300 MHz clock, false paths on all AXI I/Os)
- Timing target: 300 MHz — **closed at Run 10** (WNS +0.001 ns, 0 failing endpoints)

### RTL Changes Were Backend-Driven

All RTL changes in this iteration existed solely to close timing — no new functional behaviour was added.

| Change | Reason |
|--------|--------|
| `fp32_acc`: 1-stage → 3-stage (A0, A1, B combined) | 25-level CARRY4 chain in Run 1 |
| `itch_field_extract`: add output register | 18-level combinational decode path in Run 2 |
| `fp32_acc`: 4-stage split (A0, A1 explicit) | A-feedback through alignment barrel shift in Run 3 |
| PBLOCK on `fp32_acc` instance | Stage A1→B routing congestion (74% route delay) in Run 4 |
| `bfloat16_mul`: `(* use_dsp = "yes" *)` + pipeline reg | LUT/CARRY4 8×8 multiply; Vivado wouldn't infer DSP48E1 automatically in Run 5 |
| `feature_extractor`: 2-stage pipeline | 17-level price CARRY4 arithmetic in Run 6 |
| `fp32_acc`: 5-stage (B1 + B2 split) | Stage B adder+normalize combined (15 levels) in Run 7 |
| `feature_extractor`: 3-stage (2a magnitude + 2b normalize) | Stage 2 CARRY4×5 + LUT×9 combined (14 levels) in Run 8 |
| `vivado_impl.tcl`: post-route `phys_opt_design -directive AggressiveExplore` | fo=24 routing net in Stage 2b (4 endpoints, WNS −0.068 ns) in Run 9 |

### P&R Run History

| Run | RTL | LUTs | FFs | WNS @ 300 MHz | Critical path |
|-----|-----|------|-----|---------------|---------------|
| 1 | `fp32_acc` 1-stage | 1,599 | 417 | −6.188 ns | `fp32_acc` CARRY4 chain (25 levels) |
| 2 | `fp32_acc` 3-stage | 1,534 | 534 | −2.322 ns | `itch_parser`→`feature_extractor` (18 levels) |
| 3 | `itch_field_extract` reg. | — | — | −2.217 ns | `fp32_acc` A-feedback (`partial_sum_r`→`aligned_small_r`) |
| 4 | `fp32_acc` 4-stage (A0+A1) | 1,466 | 700 | −2.307 ns | Stage A1→B: add+normalize (14 levels, 74% route) |
| 5 | PBLOCK `u_acc/*` | 1,460 | 697 | −2.251 ns | `bfloat16_mul` mantissa multiply (13 levels) |
| 6 | `bfloat16_mul` DSP48E1 | 1,378 | 706 | −2.142 ns | `feature_extractor` price CARRY4 (17 levels) |
| 7 | `feature_extractor` 2-stage | — | — | −1.852 ns | `fp32_acc` Stage B: adder+normalize (15 levels, 5.065 ns) |
| 8 | `fp32_acc` 5-stage (B1+B2) | — | — | −1.322 ns | `feature_extractor` Stage 2: magnitude+normalize (14 levels) |
| 9 | `feature_extractor` 3-stage (2a+2b) | 1,172 | 932 | −0.068 ns | Stage 2b fo=24 routing (7 levels, 83% route) |
| **10** | Post-route phys_opt | **1,172** | **932** | **+0.001 ns** | **✅ TIMING CLOSED — 0 failing endpoints** |

Final utilization: **1,172 LUTs (1.16%), 932 FFs (0.46%), 1 DSP48E1 (0.17%), 0 BRAM, CARRY4=47**.

### New RTL Modules (v1 Kintex-7)

| Module | Description |
|--------|-------------|
| `moldupp64_strip` | Runs at 156.25 MHz. Strips 20-byte MoldUDP64 header; validates sequence numbers; drops duplicates/malformed datagrams; exposes `seq_num` via AXI4-Lite |
| `eth_axis_rx_wrap` | Wraps Forencich `eth_axis_rx`; asserts drop-on-full when `axis_async_fifo.almost_full` is high; increments `dropped_frames` counter |
| `symbol_filter` | LUT-CAM: 64 × 64-bit registers, parallel equality reduction, single-cycle `watchlist_hit`; loaded via AXI4-Lite |
| `kc705_top` | Chip-level top: GTX pins, MMCM (300/250 MHz), dual sync-resets, Forencich network stack, LLIU core |

---

## Shared RTL Architecture

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

Primary performance contract in CI (v1 simulation core):

- Full hardware datapath latency: final AXI4-Stream beat accepted to `dp_result_valid` in fewer than 18 cycles (5-stage `fp32_acc`, 3-stage `feature_extractor`)
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
│       ├── Kintex-7_MAS.md       # v1 Kintex-7 micro-arch spec
│       └── 2p0_kintex-7_MAS.md  # v2.0 full system spec (planning)
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

## v1 Simulation Core — First DUT Iteration ✅

Archived under [`reports/v1_dut/`](reports/v1_dut/). This was a simulation-only design; coverage closure and mutation testing were performed here before any FPGA backend work began.

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
- **312.5 MHz derived from network clock**: Eliminates async-FIFO synchronization penalty (∼10–15 ns) between the 156.25 MHz GTX domain and the application domain
