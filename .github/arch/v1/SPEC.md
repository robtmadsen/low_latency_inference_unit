# Design & Verification Proposal: `low_latency_inference_unit` (LLIU)

> **Master plan:** [MASTER_PLAN.md](../plan/MASTER_PLAN.md) · **Architecture:** [RTL](RTL_ARCH.md) · [UVM](UVM_ARCH.md) · [cocotb](COCOTB_ARCH.md)

## 1. Executive Summary

The `low_latency_inference_unit` (LLIU) is a hardware accelerator for real-time inference on streaming financial market data. It integrates a NASDAQ ITCH 5.0 parser with a low-latency inference engine to bridge the gap between the ultra-low latency requirements of High-Frequency Trading (HFT) and the structured compute patterns of modern AI accelerators.

The design supports replay of public NASDAQ ITCH sample datasets provided by NASDAQ, enabling realistic protocol validation while remaining license-compliant.

### Sample Data

Real NASDAQ ITCH 5.0 binary data is available in the repository:

| File | Path | Description |
|------|------|-------------|
| `tvagg_sample.gz` | `data/tvagg_sample.gz` | Compressed partial download (~1 MB) from NASDAQ TotalView-ITCH |
| `tvagg_sample.bin` | `data/tvagg_sample.bin` | Decompressed raw ITCH 5.0 binary (~3.7 MB) |

**Source:** <https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/>

The binary data contains multiple ITCH 5.0 message types including Add Order (`'A'`) messages with stock tickers, prices, order reference numbers, and buy/sell side indicators — suitable for end-to-end parser validation and cocotb replay tests.

## 2. Technical Architecture

> **See also:** [RTL_ARCH.md](RTL_ARCH.md) for the full RTL module hierarchy and decomposition.

### A. The Parser (HFT Data Plane)

| Parameter          | Value                     |
|--------------------|---------------------------|
| **Protocol**       | NASDAQ ITCH 5.0 (binary)  |
| **Interface**      | 64-bit AXI4-Stream        |
| **Target Message** | Add Order (Type `'A'`)    |

**Datapath:**

- Handles message alignment across beats
- Extracts:
  - 32-bit Price
  - 64-bit Order Reference Number
  - Side (buy/sell)

**Performance Target:**

- Primary latency metric: **final AXI4-Stream beat accepted → `dp_result_valid` < 12 cycles @ 300 MHz**
- Measurement point: internal top-level signals in `lliu_top` (`s_axis_tvalid && s_axis_tready && s_axis_tlast` as start, `dp_result_valid` as end)
- Scope: full hardware datapath from complete message ingress to inference result production with weights preloaded and no external backpressure
- Secondary stage metric: **`parser_fields_valid` → `feat_valid` < 5 cycles**
- Sustains **1 message/cycle** under no backpressure

**Corner Cases Handled:**

- Partial messages across AXI beats
- Backpressure propagation
- Malformed / truncated messages

### B. Feature Extraction Layer

Transforms raw ITCH fields into model-ready features:

- Price normalization (relative to last trade)
- Order flow encoding (buy/sell imbalance proxy)
- Optional rolling window aggregation (configurable)

This stage decouples protocol parsing from model semantics.

### C. Compute Engine (Inference Core)

| Parameter        | Value                                                                         |
|------------------|-------------------------------------------------------------------------------|
| **Architecture** | Small pipelined dot-product engine                                            |
| **Data Format**  | bfloat16 (mul) + float32 (accumulate)                                         |
| **Workload**     | Lightweight linear model / MLP for short-term price movement prediction       |

**Design Choices:**

- Batch size = 1 (latency-optimized, HFT-style)
- Narrow compute footprint sized for low-latency feature vectors rather than matrix throughput
- Fixed datapath enables:
  - Deterministic timing
  - Straightforward verification
  - Lower integration complexity

**Memory Architecture:**

- Weights preloaded via AXI4-Lite into on-chip SRAM
- Small weight register file or SRAM bank sized to the active feature vector
- Streaming activations from feature extractor

**Tradeoff:**

> Favors implementation simplicity and latency determinism over peak throughput, aligning with HFT requirements and making full-stack verification tractable for a single project.

### D. System Integration

```
AXI4-Stream → Parser → Feature Extractor → Dot-Product Engine
```

AXI4-Lite control plane:

- Weight loading
- Configuration
- Result readout

**Performance contract note:**

The primary pass/fail performance contract is the full hardware datapath latency
from the final accepted AXI4-Stream beat of an ITCH message to
`dp_result_valid` within `lliu_top`, with a target of fewer than 12 cycles.
Parser-to-feature latency remains a useful stage-level metric, but it is no
longer the top-level end-to-end requirement.

## 3. Verification Roadmap (Independent Dual Methodology)

Both verification environments are **fully self-sufficient** — each independently capable of complete verification. The goal is a head-to-head comparison of UVM vs cocotb as DV methodologies applied to the same RTL.

### Track 1: UVM (ASIC-Grade Verification)

> **See also:** [UVM_ARCH.md](UVM_ARCH.md) for the full testbench hierarchy and architecture decisions.

**Goal:** Complete, independent verification using production-level UVM methodology

**Components:**

- AXI4-Stream Agent (with backpressure + burst modeling)
- AXI4-Lite Agent
- Transaction-level scoreboard

**Golden Model:**

- DPI-C bridge to Python reference model
- Bit-accurate math validation (NumPy-based)

**Stimulus:**

- Replay of real ITCH sample data from NASDAQ
- Constrained-random ITCH message generation

**Advanced Verification:**

- **SVA:**
  - Protocol compliance
  - FSM safety
  - Latency bounds
- **Functional coverage:**
  - Message types × price ranges × side
- **Error injection:**
  - Malformed messages
  - Truncated packets

### Track 2: cocotb (Python-Native Verification)

> **See also:** [COCOTB_ARCH.md](COCOTB_ARCH.md) for the full testbench hierarchy and architecture decisions.

**Goal:** Complete, independent verification using Python-native cocotb methodology

**Environment:**

- Python 3.12 + NumPy + cocotb
- Verilator 5.0+ as simulator backend

**Full Verification Capabilities:**

- Constrained-random stimulus generation
- Functional coverage collection and closure tracking
- Protocol compliance checkers (cocotb coroutine equivalents of SVA)
- Transaction-level scoreboard with golden model
- Replay of real ITCH sample datasets
- Latency + jitter profiling (distribution, percentiles)
- Error injection (malformed, truncated, adversarial)
- Backpressure modeling
- Block-level and system-level tests

### Track 3: Synthetic Traffic Generator

Custom Python-based ITCH generator:

- Generates valid and adversarial message streams
- Models bursty market conditions
- Enables stress testing of:
  - Pipeline stalls
  - Backpressure behavior
  - Latency tail distributions

## 4. Performance Metrics

| Metric            | Description                                                   |
|-------------------|---------------------------------------------------------------|
| **Latency**       | Final AXI-stream beat accepted to `dp_result_valid` (cycle-accurate) |
| **Throughput**    | Messages/sec sustained                                        |
| **Jitter**        | Latency distribution under burst traffic                      |
| **Utilization**   | Dot-product engine occupancy / MAC activity under streaming load |
| **Correctness**   | Bit-accurate vs golden model                                  |

## 5. Technology Stack (2026 Toolchain)

| Category         | Tool / Version                                                |
|------------------|---------------------------------------------------------------|
| **HDL**          | SystemVerilog 2017                                            |
| **Verification** | UVM + SVA + cocotb                                            |
| **Simulation**   | Verilator 5.0+ / Synopsys VCS                                |
| **Languages**    | Python 3.12 (NumPy, cocotb, generators)                       |
| **CI/CD**        | GitHub Actions (automated regression + coverage tracking)     |

## 6. CI/CD Pipeline

> **See also:** `.github/workflows/` for the actual workflow definitions.

### Strategy

Two separate GitHub Actions workflows, one per verification methodology:

| Workflow | Simulator | Trigger | Runner |
|----------|-----------|---------|--------|
| `cocotb.yml` | Verilator 5.0+ | Push to `main`, all PRs | GitHub-hosted Ubuntu |
| `uvm.yml` | Verilator 5.0+ | Push to `main`, all PRs | GitHub-hosted Ubuntu |

Both workflows run on free GitHub-hosted Ubuntu runners using Verilator (open-source). VCS is used for local development and full UVM regression where needed, but CI must pass on Verilator alone to keep the pipeline accessible and reproducible.

### cocotb Workflow (`cocotb.yml`)

**Steps:**
1. Install Verilator 5.0+ (apt or build from source, cached)
2. Set up Python 3.12, install cocotb + NumPy via pip
3. Run block-level tests: `make -C tb/cocotb test_parser test_feature_extractor test_dot_product_engine`
4. Run system-level tests: `make -C tb/cocotb test_end_to_end test_replay`
5. Collect functional coverage report
6. Upload coverage artifact

**Pass criteria:** All tests pass, no scoreboard mismatches, no checker violations.

### UVM Workflow (`uvm.yml`)

**Steps:**
1. Install Verilator 5.0+ (cached)
2. Set up Python 3.12 (for DPI-C golden model bridge)
3. Compile UVM testbench with Verilator
4. Run smoke + replay + stress tests
5. Collect functional coverage report
6. Upload coverage artifact

**Note:** Verilator's UVM support covers the subset used here (agents, sequencers, scoreboards, basic phasing). Features like `uvm_reg` or advanced factory overrides are not used. Full UVM regression with SVA evaluation requires VCS and is documented as a local-only target in `tb/uvm/Makefile`.

### CI Design Principles

- **No commercial tools in CI.** Everything that runs in GitHub Actions uses Verilator. VCS targets exist in Makefiles for local use.
- **Cached Verilator builds.** Verilator is compiled once and cached via `actions/cache` to keep pipeline time under 10 minutes.
- **Coverage artifacts.** Both workflows upload coverage reports as GitHub Actions artifacts for review.
- **Fail fast.** Block-level tests run before system-level tests. If parsing is broken, the pipeline stops early.
- **Reproducible.** Pinned tool versions (Verilator commit hash, Python 3.12.x, cocotb version) in workflow files.

## 7. Key Design Insight

This project explicitly separates:

- **Protocol realism** → validated using real ITCH sample data
- **Model semantics** → flexible and dataset-agnostic

This decoupling enables rigorous hardware validation without dependence on proprietary market data.

## 8. Deployment Vision

- FPGA prototype for low-latency trading environments
- ASIC portability for production-scale deployment
- Extensible to other market data protocols or inference models