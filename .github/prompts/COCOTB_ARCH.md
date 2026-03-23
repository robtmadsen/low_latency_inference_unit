# cocotb Testbench Architecture

## Design Philosophy

This is a **fully self-sufficient** verification environment — not a complement to the UVM TB, but an independent, parallel effort capable of complete verification on its own. The goal is to enable a direct head-to-head comparison of UVM vs cocotb as DV methodologies applied to the same RTL.

## Directory Structure

```
tb/cocotb/
├── drivers/
│   ├── axi4_stream_driver.py     # AXI4-Stream master: tdata, tvalid, tready, tlast
│   ├── axi4_stream_monitor.py    # Passive monitor, captures transactions
│   ├── axi4_lite_driver.py       # AXI4-Lite master: weight loads, config, result read
│   ├── axi4_lite_monitor.py      # Passive monitor for control plane transactions
│   └── itch_feeder.py            # Reads .bin files, packetizes into AXI4-Stream beats
├── models/
│   └── golden_model.py           # NumPy reference: parse → features → inference (shared source of truth)
├── scoreboard/
│   └── scoreboard.py             # Transaction-level comparison: DUT output vs golden model
├── coverage/
│   ├── functional_coverage.py    # Coverpoints + cross coverage (msg type × price × side × backpressure)
│   └── coverage_report.py        # Coverage collection, merge, and reporting
├── checkers/
│   ├── axi4_stream_checker.py    # Protocol compliance checks (cocotb equivalent of SVA)
│   ├── axi4_lite_checker.py      # AXI4-Lite protocol compliance
│   ├── parser_checker.py         # FSM safety, latency bounds assertions
│   └── dot_product_checker.py    # Engine timing, accumulator safety, deadlock detection
├── stimulus/
│   ├── itch_replay.py            # Replay data/tvagg_sample.bin through AXI4-Stream
│   ├── itch_random.py            # Constrained-random Add Order generation
│   ├── itch_adversarial.py       # Malformed, truncated, bursty message streams
│   ├── weight_loader.py          # AXI4-Lite weight preload sequences
│   └── backpressure_gen.py       # tready deassertion patterns (random, periodic, bursty)
├── tests/
│   ├── test_smoke.py             # Single Add Order → verify parsed fields + inference output
│   ├── test_parser.py            # Block-level: alignment, multi-beat, all message types
│   ├── test_feature_extractor.py # Price normalization, order flow encoding
│   ├── test_dot_product_engine.py # Weight load → dot product → compare to NumPy
│   ├── test_end_to_end.py        # Full pipeline: ITCH in → inference result out
│   ├── test_replay.py            # Real ITCH data replay, bit-accurate checking
│   ├── test_constrained_random.py # Random stimulus with scoreboard + coverage closure
│   ├── test_backpressure.py      # Stall patterns, recovery, pipeline drain
│   ├── test_error_injection.py   # Malformed messages, truncated packets, garbage data
│   └── test_latency.py           # Cycle-accurate latency + jitter profiling
├── utils/
│   ├── itch_decoder.py           # Python ITCH 5.0 binary decoder for stimulus + checking
│   ├── bfloat16.py               # bfloat16 ↔ float32 conversion utilities
│   └── latency_profiler.py       # Per-message cycle counts, percentiles (p50, p99, p99.9), jitter
├── conftest.py                   # pytest/cocotb fixtures: clock, reset, DUT handle setup
└── Makefile                      # Verilator sim targets, TOPLEVEL / MODULE selection
```

## Key Architecture Decisions

### 1. Two Drivers, Full Scoreboard

AXI4-Stream master drives ITCH ingress, AXI4-Lite master drives control. Both have passive monitors feeding a centralized `scoreboard.py` that compares every DUT output transaction against the golden model. This mirrors UVM's agent+scoreboard pattern in pure Python.

### 2. Constrained-Random Stimulus

`itch_random.py` implements constrained-random generation using Python's `random` module with seed control and constraint functions (valid price ranges, balanced buy/sell, legal message lengths). This is not just directed tests — it's the cocotb answer to UVM sequences with `std::randomize`.

### 3. Functional Coverage in Python

`functional_coverage.py` implements coverpoints and cross-coverage bins in Python:
- Message type bins
- Price range bins (penny, dollar, large)
- Side (buy/sell)
- Backpressure state (stalled/flowing)
- Cross: message type × price range × side

Coverage is sampled from monitor transactions and reported with bin hit counts and percentage. Enables coverage-driven verification and closure tracking — the same methodology as UVM, implemented natively.

### 4. Protocol Checkers Replace SVA

Since cocotb can't use SVA directly, `checkers/` implements equivalent protocol compliance monitors as cocotb coroutines:
- AXI4-Stream: tvalid stability, tready handshake rules, tlast framing
- AXI4-Lite: RVALID/WREADY protocol, no outstanding transaction violations
- Parser: FSM one-hot safety, latency bound assertions (< 5 cycles)
- Dot-product engine: no deadlock, deterministic output timing, accumulator control checks

These run concurrently with tests via `cocotb.start_soon()`.

### 5. Latency Profiling with Distributions

`latency_profiler.py` timestamps every message at ingress and egress, computes:
- Per-message cycle count
- Min / max / mean / median
- Percentiles: p50, p99, p99.9
- Jitter (stddev of latency)
- Histogram output for tail analysis

### 6. Block-Level and System-Level via TOPLEVEL

The Makefile supports different `TOPLEVEL` targets:
- `TOPLEVEL=itch_parser` → `test_parser.py`
- `TOPLEVEL=feature_extractor` → `test_feature_extractor.py`
- `TOPLEVEL=dot_product_engine` → `test_dot_product_engine.py`
- `TOPLEVEL=lliu_top` → all system-level tests

Each test file is self-contained and declares its own `TOPLEVEL` requirement.

### 7. Golden Model is Shared

`models/golden_model.py` is the **same** Python code that UVM calls via DPI-C. cocotb calls it natively. One source of truth for bit-accurate math validation across both methodologies.

## Verification Completeness

This cocotb environment independently covers all verification goals:

| Verification Goal               | cocotb Implementation                     |
|---------------------------------|-------------------------------------------|
| Protocol compliance             | `checkers/` (concurrent coroutines)       |
| Bit-accurate correctness        | `scoreboard.py` + `golden_model.py`       |
| Constrained-random stimulus     | `stimulus/itch_random.py`                 |
| Functional coverage closure     | `coverage/functional_coverage.py`         |
| Real data replay                | `stimulus/itch_replay.py` + `data/`       |
| Error injection                 | `stimulus/itch_adversarial.py`            |
| Latency / jitter profiling      | `utils/latency_profiler.py`               |
| Backpressure handling           | `stimulus/backpressure_gen.py`            |
| Block-level isolation           | Per-module `TOPLEVEL` in Makefile         |
| System-level integration        | `test_end_to_end.py`, `test_replay.py`    |

## Compute-Block Verification Focus

The smaller inference block shifts cocotb effort toward exhaustive block-level validation:

- Fixed-vector dot-product correctness across randomized weights and activations
- Accumulator clear / reuse behavior across consecutive transactions
- AXI4-Lite weight programming and immediate inference-readback tests
- Tight latency profiling without large-array scheduling effects

## CI Integration

The cocotb testbench is the primary CI-first verification track. Everything runs on GitHub Actions with Verilator — no commercial tools required.

**CI workflow steps:**
1. Cache and install Verilator 5.0+
2. Set up Python 3.12, `pip install cocotb numpy`
3. Block-level tests (fail fast):
   - `make TOPLEVEL=itch_parser MODULE=test_parser`
   - `make TOPLEVEL=feature_extractor MODULE=test_feature_extractor`
   - `make TOPLEVEL=dot_product_engine MODULE=test_dot_product_engine`
4. System-level tests:
   - `make TOPLEVEL=lliu_top MODULE=test_end_to_end`
   - `make TOPLEVEL=lliu_top MODULE=test_replay`
5. Collect functional coverage → upload as artifact

**Makefile targets:**

```
make test                  # Run all tests (block + system)
make test_parser           # Block-level parser only
make test_replay           # System-level ITCH replay
make coverage_report       # Generate coverage summary
```

**Pass criteria:** Zero scoreboard mismatches, zero checker violations, all TOPLEVEL targets exit cleanly. Coverage percentage is reported but not gated initially — coverage closure is a progressive goal.
