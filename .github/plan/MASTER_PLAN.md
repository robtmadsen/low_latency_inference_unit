# Master Plan

This is the execution order across all three tracks. Each row is a functional commit. RTL and cocotb interleave early so you're never writing RTL without tests. UVM begins once the full RTL is integrated.

> **Individual plans:** [RTL_PLAN.md](RTL_PLAN.md) · [COCOTB_PLAN.md](COCOTB_PLAN.md) · [UVM_PLAN.md](UVM_PLAN.md)
>
> **Architecture:** [SPEC.md](../arch/SPEC.md) · [RTL_ARCH.md](../arch/RTL_ARCH.md) · [UVM_ARCH.md](../arch/UVM_ARCH.md) · [COCOTB_ARCH.md](../arch/COCOTB_ARCH.md)

---

## Stage 1: Build + Test in Lockstep (RTL + cocotb)

RTL modules land with immediate cocotb verification. Every pair of commits produces tested RTL.

| # | Commit | Plan Reference |
|---|--------|---------------|
| 1 | `rtl: add bfloat16_mul and fp32_acc arithmetic primitives` | RTL Phase 1 |
| 2 | `cocotb: infrastructure, bfloat16 utils, arithmetic block tests` | cocotb Phase 1 |
| 3 | `rtl: add dot_product_engine, weight_mem, output_buffer` | RTL Phase 2 |
| 4 | `cocotb: golden model, dot-product engine full test` | cocotb Phase 2 |
| 5 | `rtl: add itch_parser and itch_field_extract` | RTL Phase 3 |
| 6 | `cocotb: AXI4-Stream driver/monitor, ITCH decoder, parser tests` | cocotb Phase 3 |

**Checkpoint:** All block-level RTL is implemented and tested. Parser, feature extractor, and inference engine each pass cocotb tests independently.

---

## Stage 2: Complete RTL + cocotb System Tests

Finish the RTL pipeline, then bring up end-to-end cocotb verification.

| # | Commit | Plan Reference |
|---|--------|---------------|
| 7 | `rtl: add feature_extractor` | RTL Phase 4 |
| 8 | `rtl: add axi4_lite_slave` | RTL Phase 5 |
| 9 | `cocotb: feature extractor tests, AXI4-Lite driver, weight loader` | cocotb Phase 4 |
| 10 | `rtl: add lliu_top system integration` | RTL Phase 6 |
| 11 | `rtl: lint clean, interface hardening, Makefile` | RTL Phase 7 |
| 12 | `cocotb: end-to-end smoke test with scoreboard` | cocotb Phase 5 |
| 13 | `cocotb: ITCH replay from real NASDAQ sample data` | cocotb Phase 6 |

**Checkpoint:** Full RTL is integrated, lint-clean, and passing end-to-end cocotb tests with real NASDAQ data. The design is functionally verified at the system level by one methodology.

---

## Stage 3: UVM Environment Bring-Up

Build the UVM testbench against the stable, integrated RTL. cocotb advanced features develop in parallel.

| # | Commit | Plan Reference |
|---|--------|---------------|
| 14 | `uvm: testbench skeleton, tb_top, interfaces, base test, Makefile` | UVM Phase 1 |
| 15 | `uvm: AXI4-Stream agent (driver, monitor, sequencer)` | UVM Phase 2 |
| 16 | `uvm: AXI4-Lite agent, weight load sequence` | UVM Phase 3 |
| 17 | `uvm: DPI-C golden model bridge, predictor, scoreboard` | UVM Phase 4 |
| 18 | `uvm: smoke test — single Add Order end-to-end with scoreboard` | UVM Phase 5 |
| 19 | `uvm: real ITCH data replay test` | UVM Phase 6 |

**Checkpoint:** Both verification environments independently pass end-to-end smoke and replay tests. The dual-methodology comparison is now demonstrable.

---

## Stage 4: Advanced Verification (Parallel Tracks)

cocotb and UVM advanced features can proceed in any order. Listed interleaved for balanced progress.

| # | Commit | Plan Reference |
|---|--------|---------------|
| 20 | `cocotb: protocol compliance checkers (SVA equivalent)` | cocotb Phase 7 |
| 21 | `uvm: constrained-random ITCH sequence` | UVM Phase 7 |
| 22 | `cocotb: constrained-random stimulus, functional coverage` | cocotb Phase 8 |
| 23 | `uvm: functional coverage model` | UVM Phase 8 |
| 24 | `uvm: SVA bind files for protocol compliance and FSM safety` | UVM Phase 9 |
| 25 | `cocotb: backpressure modeling, error injection tests` | cocotb Phase 9 |
| 26 | `uvm: backpressure sequences, error injection, stress + error tests` | UVM Phase 10 |
| 27 | `cocotb: latency profiler, latency + jitter tests` | cocotb Phase 10 |
| 28 | `uvm: cycle-accurate latency + jitter profiling monitor` | UVM Phase 11 |

**Checkpoint:** Both environments have full coverage, assertions, stress tests, error injection, and latency profiling. Verification is complete.

---

## Stage 5: CI

| # | Commit | Plan Reference |
|---|--------|---------------|
| 29 | `ci: add cocotb GitHub Actions workflow` | cocotb Phase 11 |
| 30 | `ci: add UVM GitHub Actions workflow` | UVM Phase 12 |

**Checkpoint:** Green CI on every push. Project is complete.

---

## Progress Tracker

```
Stage 1: Build + Test in Lockstep
  [x] #1  RTL Phase 1 — arithmetic primitives
  [x] #2  cocotb Phase 1 — arithmetic block tests
  [x] #3  RTL Phase 2 — dot-product engine
  [x] #4  cocotb Phase 2 — golden model + engine test
  [x] #5  RTL Phase 3 — ITCH parser
  [x] #6  cocotb Phase 3 — parser tests

Stage 2: Complete RTL + cocotb System Tests
  [x] #7  RTL Phase 4 — feature extractor
  [x] #8  RTL Phase 5 — AXI4-Lite slave
  [x] #9  cocotb Phase 4 — feature extractor + AXI4-Lite tests
  [x] #10 RTL Phase 6 — lliu_top integration
  [x] #11 RTL Phase 7 — lint clean + Makefile
  [x] #12 cocotb Phase 5 — end-to-end smoke test
  [x] #13 cocotb Phase 6 — real data replay

Stage 3: UVM Environment Bring-Up
  [ ] #14 UVM Phase 1 — TB skeleton
  [ ] #15 UVM Phase 2 — AXI4-Stream agent
  [ ] #16 UVM Phase 3 — AXI4-Lite agent
  [ ] #17 UVM Phase 4 — DPI-C golden model + scoreboard
  [ ] #18 UVM Phase 5 — smoke test
  [ ] #19 UVM Phase 6 — replay test

Stage 4: Advanced Verification
  [ ] #20 cocotb Phase 7 — protocol checkers
  [ ] #21 UVM Phase 7 — constrained-random
  [ ] #22 cocotb Phase 8 — random + coverage
  [ ] #23 UVM Phase 8 — functional coverage
  [ ] #24 UVM Phase 9 — SVA bind files
  [ ] #25 cocotb Phase 9 — backpressure + errors
  [ ] #26 UVM Phase 10 — stress + errors
  [ ] #27 cocotb Phase 10 — latency profiling
  [ ] #28 UVM Phase 11 — latency profiling

Stage 5: CI
  [ ] #29 cocotb Phase 11 — CI workflow
  [ ] #30 UVM Phase 12 — CI workflow
```
