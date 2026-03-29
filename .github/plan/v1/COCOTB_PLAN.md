# cocotb Verification Plan

> **Architecture:** [COCOTB_ARCH.md](../arch/COCOTB_ARCH.md) · **Master plan:** [MASTER_PLAN.md](MASTER_PLAN.md) · **Spec:** [SPEC.md](../arch/SPEC.md)

Each phase ends with a functional commit. Phases 1–4 can begin as soon as the corresponding RTL phases are complete. Phase 5+ requires `lliu_top` (RTL Phase 6).

**Prerequisite:** RTL Phase 1 must be complete before cocotb Phase 1 begins.

---

## Phase 1: Infrastructure + Arithmetic Block Tests

**Goal:** cocotb can compile, simulate, and test the arithmetic primitives in isolation.

### RTL Dependency: RTL Phase 1 (bfloat16_mul, fp32_acc)

### Steps

1. Create directory structure: `tb/cocotb/`, `drivers/`, `models/`, `tests/`, `utils/`, `stimulus/`, `scoreboard/`, `coverage/`, `checkers/`
2. Create `Makefile` with Verilator backend
   - `SIM = verilator`
   - `TOPLEVEL_LANG = verilog`
   - Parameterized `TOPLEVEL` and `MODULE` variables
   - Include `$(shell cocotb-config --makefiles)/Makefile.sim`
3. Create `conftest.py` with clock and reset fixtures
   - 10ns clock (100 MHz for initial testing, parameterizable)
   - Active-high synchronous reset, held for 5 cycles
4. Implement `utils/bfloat16.py`
   - `float_to_bfloat16(f) → int` (truncate float32 mantissa to 8 bits)
   - `bfloat16_to_float(b) → float` (expand back)
   - `bfloat16_mul_ref(a, b) → float` (reference multiply with bfloat16 truncation)
5. Implement `test_dot_product_engine.py` — but only the `bfloat16_mul` and `fp32_acc` subtests:
   - `test_bfloat16_mul_basic`: drive known operands, check product against `bfloat16.py`
   - `test_bfloat16_mul_special_cases`: zero × nonzero, subnormals, large values
   - `test_fp32_acc_accumulate`: send N addends, check running sum
   - `test_fp32_acc_clear`: verify accumulator resets on clear signal
6. Verify: `make TOPLEVEL=bfloat16_mul MODULE=test_dot_product_engine` passes
7. Verify: `make TOPLEVEL=fp32_acc MODULE=test_dot_product_engine` passes

### Commit: `cocotb: infrastructure, bfloat16 utils, arithmetic block tests`

**Files:**
```
tb/cocotb/Makefile
tb/cocotb/conftest.py
tb/cocotb/utils/__init__.py
tb/cocotb/utils/bfloat16.py
tb/cocotb/tests/test_dot_product_engine.py (partial — arithmetic only)
```

---

## Phase 2: Golden Model + Dot-Product Engine Test

**Goal:** Shared golden model exists. Dot-product engine passes end-to-end test against it.

### RTL Dependency: RTL Phase 2 (dot_product_engine, weight_mem, output_buffer)

### Steps

1. Implement `models/golden_model.py`
   - `class GoldenModel`:
     - `parse_add_order(raw_bytes) → (price, order_ref, side)` — ITCH field extraction reference
     - `extract_features(price, order_ref, side) → np.array[bfloat16]` — feature computation reference
     - `inference(features, weights) → float32` — dot product with bfloat16 mul + float32 acc semantics
   - All math uses bfloat16 truncation at multiply, float32 at accumulate — matches RTL exactly
2. Implement `test_dot_product_engine.py` — full engine tests:
   - `test_dot_product_basic`: load weights via direct port drive, send feature vector, compare result to `golden_model.inference()`
   - `test_dot_product_sweep`: randomized weight/feature pairs (seeded), batch of 100, all checked against golden model
   - `test_dot_product_back_to_back`: two consecutive inferences without reset, verify accumulator clears between runs
3. Verify: `make TOPLEVEL=dot_product_engine MODULE=test_dot_product_engine` passes

### Commit: `cocotb: golden model, dot-product engine full test`

**Files:**
```
tb/cocotb/models/__init__.py
tb/cocotb/models/golden_model.py
tb/cocotb/tests/test_dot_product_engine.py (complete)
```

---

## Phase 3: AXI4-Stream Driver + Parser Test

**Goal:** AXI4-Stream driver works. Parser correctly aligns and extracts Add Order fields.

### RTL Dependency: RTL Phase 3 (itch_parser, itch_field_extract)

### Steps

1. Implement `drivers/axi4_stream_driver.py`
   - `class AXI4StreamDriver`:
     - Drives `tdata`, `tvalid`, `tlast` on clock edges
     - Respects `tready` (waits when deasserted)
     - `async send(data: bytes)`: packetizes into 8-byte beats, asserts `tlast` on final beat
     - `async send_beats(beats: list[int])`: raw beat-level control
2. Implement `drivers/axi4_stream_monitor.py`
   - `class AXI4StreamMonitor`:
     - Passive: samples `tdata` when `tvalid & tready`
     - Collects complete transactions (accumulates until `tlast`)
     - Callback-based: calls registered function with complete transaction bytes
3. Implement `utils/itch_decoder.py`
   - `encode_add_order(order_ref, side, price, stock) → bytes` — build a valid ITCH Add Order message with 2-byte big-endian length prefix
   - `decode_add_order(raw) → dict` — parse back for verification
   - Constants for message type codes, field offsets, field widths per ITCH 5.0 spec
4. Implement `test_parser.py`
   - `test_single_add_order`: encode one Add Order, send via AXI4-Stream, verify extracted fields match
   - `test_multi_beat_message`: Add Order spanning 2+ AXI beats (message longer than 8 bytes)
   - `test_non_add_order_passthrough`: send a System Event ('S') message, verify parser discards it (no output asserted)
   - `test_back_to_back_messages`: two Add Orders in rapid succession
5. Verify: `make TOPLEVEL=itch_parser MODULE=test_parser` passes

### Commit: `cocotb: AXI4-Stream driver/monitor, ITCH decoder, parser tests`

**Files:**
```
tb/cocotb/drivers/__init__.py
tb/cocotb/drivers/axi4_stream_driver.py
tb/cocotb/drivers/axi4_stream_monitor.py
tb/cocotb/utils/itch_decoder.py
tb/cocotb/tests/test_parser.py
```

---

## Phase 4: Feature Extractor Test + AXI4-Lite Driver

**Goal:** Feature extractor verified. AXI4-Lite driver ready for weight loading.

### RTL Dependency: RTL Phase 4 (feature_extractor) and RTL Phase 5 (axi4_lite_slave)

### Steps

1. Implement `test_feature_extractor.py`
   - `test_price_delta`: send two Add Orders with known prices, verify delta feature matches golden model
   - `test_side_encoding`: verify buy → +1.0 bfloat16, sell → -1.0 bfloat16
   - `test_order_flow_imbalance`: sequence of buy/sell orders, verify running imbalance counter
   - `test_feature_vector_format`: verify output vector width and element ordering match golden model
2. Implement `drivers/axi4_lite_driver.py`
   - `class AXI4LiteDriver`:
     - `async write(addr, data)`: AXI4-Lite write transaction (AW + W → B)
     - `async read(addr) → int`: AXI4-Lite read transaction (AR → R)
     - Handles handshake: waits for READY on each channel
3. Implement `drivers/axi4_lite_monitor.py`
   - Passive: captures write and read transactions for scoreboard
4. Implement `stimulus/weight_loader.py`
   - `async load_weights(axi_lite_driver, weights: list[float])`: converts float32 weights to bfloat16, writes each to weight_mem via AXI4-Lite register map
5. Verify: `make TOPLEVEL=feature_extractor MODULE=test_feature_extractor` passes

### Commit: `cocotb: feature extractor tests, AXI4-Lite driver, weight loader`

**Files:**
```
tb/cocotb/tests/test_feature_extractor.py
tb/cocotb/drivers/axi4_lite_driver.py
tb/cocotb/drivers/axi4_lite_monitor.py
tb/cocotb/stimulus/__init__.py
tb/cocotb/stimulus/weight_loader.py
```

---

## Phase 5: End-to-End Smoke Test

**Goal:** First full-pipeline test: ITCH message in → inference result out via AXI4-Lite readback.

### RTL Dependency: RTL Phase 6 (lliu_top)

### Steps

1. Implement `test_smoke.py`
   - `test_single_inference`:
     1. Load known weights via AXI4-Lite
     2. Send one Add Order via AXI4-Stream (known price, side)
     3. Wait for inference completion (poll status register or wait N cycles)
     4. Read result via AXI4-Lite
     5. Compare to `golden_model.inference(golden_model.extract_features(price, order_ref, side), weights)`
   - This is the first test that exercises the entire pipeline through `lliu_top`
2. Implement `scoreboard/scoreboard.py`
   - `class Scoreboard`:
     - `add_expected(transaction)`: queue expected result from golden model
     - `add_actual(transaction)`: queue actual result from DUT
     - `check()`: compare queues, report mismatches with full context
     - Tracks: total checked, total mismatches, last mismatch details
3. Verify: `make TOPLEVEL=lliu_top MODULE=test_smoke` passes

### Commit: `cocotb: end-to-end smoke test with scoreboard`

**Files:**
```
tb/cocotb/tests/test_smoke.py
tb/cocotb/scoreboard/__init__.py
tb/cocotb/scoreboard/scoreboard.py
```

---

## Phase 6: Real Data Replay

**Goal:** Parse and infer on actual NASDAQ ITCH sample data.

### Steps

1. Implement `drivers/itch_feeder.py`
   - `class ITCHFeeder`:
     - Reads `data/tvagg_sample.bin`
     - Iterates ITCH messages (2-byte length prefix → payload)
     - Packetizes each message into 8-byte AXI4-Stream beats
     - Drives via `AXI4StreamDriver`
     - Configurable: filter by message type, limit count
2. Implement `stimulus/itch_replay.py`
   - `async replay_itch_file(feeder, path, max_messages=None)`: top-level replay coroutine
   - Feeds messages at wire rate (one beat per cycle) or throttled
3. Implement `test_replay.py`
   - `test_replay_add_orders`: replay sample file, filter Add Orders, verify each parsed output against `itch_decoder.decode_add_order()` on the raw bytes
   - `test_replay_with_inference`: replay + weight load, verify inference results against golden model for first N Add Orders
4. Verify: `make TOPLEVEL=lliu_top MODULE=test_replay` passes

### Commit: `cocotb: ITCH replay from real NASDAQ sample data`

**Files:**
```
tb/cocotb/drivers/itch_feeder.py
tb/cocotb/stimulus/itch_replay.py
tb/cocotb/tests/test_replay.py
```

---

## Phase 7: Protocol Checkers

**Goal:** Concurrent protocol compliance monitors running alongside all tests.

### Steps

1. Implement `checkers/axi4_stream_checker.py`
   - Concurrent coroutine (`cocotb.start_soon`)
   - Checks: `tvalid` must not deassert without handshake, `tdata` must be stable while `tvalid` is high and `tready` is low
   - Raises `TestFailure` on violation
2. Implement `checkers/axi4_lite_checker.py`
   - Write channel: WVALID/AWVALID stability, BRESP check
   - Read channel: ARVALID stability, RRESP check
3. Implement `checkers/parser_checker.py`
   - FSM state must be one-hot (if exposed via hierarchy access)
   - Latency from `tvalid` handshake to `fields_valid` < 5 cycles
4. Implement `checkers/dot_product_checker.py`
   - `result_valid` must assert within (vector_length + pipeline_depth) cycles of `start`
   - No `result_valid` without preceding `start`
5. Enable checkers in `conftest.py` so they auto-start for all system-level tests
6. Re-run all existing tests with checkers active — verify no regressions

### Commit: `cocotb: protocol compliance checkers (SVA equivalent)`

**Files:**
```
tb/cocotb/checkers/__init__.py
tb/cocotb/checkers/axi4_stream_checker.py
tb/cocotb/checkers/axi4_lite_checker.py
tb/cocotb/checkers/parser_checker.py
tb/cocotb/checkers/dot_product_checker.py
tb/cocotb/conftest.py (updated)
```

---

## Phase 8: Constrained-Random + Functional Coverage

**Goal:** Coverage-driven random testing with bin tracking.

### Steps

1. Implement `stimulus/itch_random.py`
   - `class ConstrainedRandomITCH`:
     - Seeded `random.Random` instance for reproducibility
     - `generate_add_order(constraints=None) → bytes`: random valid Add Order
     - Constraints: price range (penny/dollar/large), side distribution, stock filter
     - `generate_stream(count, constraints) → list[bytes]`: batch generation
2. Implement `coverage/functional_coverage.py`
   - `class FunctionalCoverage`:
     - Coverpoints: message_type, price_range (bins: 0–99, 100–9999, 10000+), side
     - Cross-coverage: price_range × side
     - `sample(transaction)`: increment bin counts
     - `report() → dict`: bin hit counts, percentages, uncovered bins
     - `is_covered(target_pct=100) → bool`
3. Implement `coverage/coverage_report.py`
   - Formats and prints coverage summary at test end
   - Writes JSON artifact for CI upload
4. Implement `test_constrained_random.py`
   - `test_random_100`: 100 random Add Orders with scoreboard
   - `test_random_coverage_closure`: run until 90% coverage or 10000 messages, whichever first
   - Coverage results printed and saved
5. Verify: `make TOPLEVEL=lliu_top MODULE=test_constrained_random` passes

### Commit: `cocotb: constrained-random stimulus, functional coverage`

**Files:**
```
tb/cocotb/stimulus/itch_random.py
tb/cocotb/coverage/__init__.py
tb/cocotb/coverage/functional_coverage.py
tb/cocotb/coverage/coverage_report.py
tb/cocotb/tests/test_constrained_random.py
```

---

## Phase 9: Backpressure + Error Injection

**Goal:** Stress testing under adverse conditions.

### Steps

1. Implement `stimulus/backpressure_gen.py`
   - `class BackpressureGenerator`:
     - Drives `tready` with configurable patterns: always-ready, periodic stall (N on / M off), random, bursty
     - Runs as concurrent coroutine
2. Implement `stimulus/itch_adversarial.py`
   - `generate_truncated_message() → bytes`: message shorter than declared length
   - `generate_malformed_type() → bytes`: invalid message type code
   - `generate_oversized_message() → bytes`: message exceeding max ITCH length
   - `generate_garbage() → bytes`: random bytes with no valid ITCH framing
3. Implement `test_backpressure.py`
   - `test_periodic_stall`: periodic tready deassertion, verify no data loss
   - `test_random_backpressure`: random tready pattern over 100 messages, scoreboard check
   - `test_pipeline_drain`: fill pipeline, stall, release, verify all results arrive
4. Implement `test_error_injection.py`
   - `test_truncated_message`: send truncated, verify parser recovers for next valid message
   - `test_malformed_type`: verify parser discards without hanging
   - `test_garbage_recovery`: garbage → valid message, verify valid message still parses
5. Verify all pass

### Commit: `cocotb: backpressure modeling, error injection tests`

**Files:**
```
tb/cocotb/stimulus/backpressure_gen.py
tb/cocotb/stimulus/itch_adversarial.py
tb/cocotb/tests/test_backpressure.py
tb/cocotb/tests/test_error_injection.py
```

---

## Phase 10: Latency Profiling

**Goal:** Cycle-accurate latency measurement with statistical analysis.

### Steps

1. Implement `utils/latency_profiler.py`
   - `class LatencyProfiler`:
     - `record_ingress(msg_id, cycle)`: timestamp at AXI4-Stream handshake
     - `record_egress(msg_id, cycle)`: timestamp at result valid
     - `report() → dict`: min, max, mean, median, p50, p99, p99.9, stddev (jitter)
     - `histogram(bins=20) → list`: latency distribution
2. Implement `test_latency.py`
   - `test_latency_single`: single message, verify < 5 cycle parser latency (post-alignment)
   - `test_latency_sustained`: 100 back-to-back messages, report distribution
   - `test_latency_under_backpressure`: measure latency increase under stall patterns
   - `test_jitter`: verify stddev is within expected bounds for deterministic pipeline
3. Verify: `make TOPLEVEL=lliu_top MODULE=test_latency` passes

### Commit: `cocotb: latency profiler, latency + jitter tests`

**Files:**
```
tb/cocotb/utils/latency_profiler.py
tb/cocotb/tests/test_latency.py
```

---

## Phase 11: CI Workflow

**Goal:** GitHub Actions runs cocotb regression on every push and PR.

### Steps

1. Create `.github/workflows/cocotb.yml`
   - Trigger: push to `main`, all PRs
   - Runner: `ubuntu-latest`
   - Steps:
     1. Checkout
     2. Cache Verilator build (keyed on Verilator commit hash)
     3. Build Verilator 5.0+ if not cached
     4. Setup Python 3.12
     5. `pip install cocotb numpy`
     6. Block-level tests: `make -C tb/cocotb test_parser test_feature_extractor test_dot_product_engine`
     7. System-level tests: `make -C tb/cocotb test_smoke test_replay test_end_to_end`
     8. Upload coverage JSON as artifact
2. Verify workflow passes on push

### Commit: `ci: add cocotb GitHub Actions workflow`

**Files:**
```
.github/workflows/cocotb.yml
```

---

## Summary

| Phase | Commit Message | RTL Dep | Key Deliverable |
|-------|---------------|---------|-----------------|
| 1 | `cocotb: infrastructure, bfloat16 utils, arithmetic block tests` | RTL P1 | Makefile, conftest, bfloat16 tests |
| 2 | `cocotb: golden model, dot-product engine full test` | RTL P2 | Golden model, dot-product verification |
| 3 | `cocotb: AXI4-Stream driver/monitor, ITCH decoder, parser tests` | RTL P3 | AXI4-Stream BFM, parser tests |
| 4 | `cocotb: feature extractor tests, AXI4-Lite driver, weight loader` | RTL P4–5 | AXI4-Lite BFM, feature tests |
| 5 | `cocotb: end-to-end smoke test with scoreboard` | RTL P6 | Full pipeline smoke test |
| 6 | `cocotb: ITCH replay from real NASDAQ sample data` | RTL P6 | Real data replay |
| 7 | `cocotb: protocol compliance checkers (SVA equivalent)` | RTL P6 | Concurrent checkers |
| 8 | `cocotb: constrained-random stimulus, functional coverage` | RTL P6 | Coverage-driven random |
| 9 | `cocotb: backpressure modeling, error injection tests` | RTL P6 | Stress + error tests |
| 10 | `cocotb: latency profiler, latency + jitter tests` | RTL P6 | Performance measurement |
| 11 | `ci: add cocotb GitHub Actions workflow` | All | CI pipeline |

**After Phase 11, CocoTB verification is complete with CI.**
