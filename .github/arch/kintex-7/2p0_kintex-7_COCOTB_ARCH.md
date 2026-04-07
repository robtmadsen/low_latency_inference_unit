# cocotb Testbench Architecture — LLIU v2.0 (Kintex-7)

> **Status:** Phase 1 complete (PR #41 on `main`, April 2026)
> **Simulator:** Verilator 5.046
> **Spec reference:** [2p0_kintex-7_MAS.md](2p0_kintex-7_MAS.md)
> **Testbench root:** `tb/cocotb/`

---

## 1. Directory Structure

```
tb/cocotb/
├── Makefile                     ← per-TOPLEVEL VERILOG_SOURCES, Verilator flags
├── tests/                       ← test modules (one file per suite)
│   ├── [v1 tests — see v1 section below]
│   ├── test_order_book.py       ← Phase 1: order book functional tests
│   ├── test_order_book_collision.py ← Phase 1: hash-collision stress
│   ├── test_ptp.py              ← Phase 1: ptp_core counter + sync pulse
│   ├── test_timestamp_tap.py   ← Phase 1: timestamp_tap sub-counter behavior
│   └── test_histogram.py       ← Phase 1: latency_histogram bin logic
├── models/
│   ├── golden_model.py          ← FP32 dot-product reference (v1)
│   └── order_book_model.py      ← Python L3 order book reference model (Phase 1)
├── drivers/                     ← AXI4-Lite, AXI4-Stream, ITCH feeder drivers
├── checkers/                    ← Protocol compliance checkers
├── scoreboard/                  ← FIFO-ordered expected vs. actual
├── stimulus/                    ← Backpressure, adversarial ITCH, constrained-random
├── coverage/                    ← Coverage collector helpers
└── regression_results/          ← Per-module results_<module>.xml (auto-generated)
```

---

## 2. Test Inventory

### 2.1 v1 Suites (retained, unmodified)

| TOPLEVEL | MODULE | Test functions |
|----------|--------|----------------|
| `bfloat16_mul` | `test_bfloat16_mul` | `test_bfloat16_mul_basic`, `test_bfloat16_mul_special_cases` |
| `bfloat16_mul` | `test_bf16_mul_edge` | 12 edge / boundary tests |
| `fp32_acc` | `test_fp32_acc` | `test_fp32_acc_accumulate`, `test_fp32_acc_clear` |
| `fp32_acc` | `test_fp32_acc_edge` | 12 edge tests |
| `dot_product_engine` | `test_dot_product_engine` | `test_dot_product_basic`, `test_dot_product_sweep`, `test_dot_product_back_to_back` |
| `itch_parser` | `test_parser` | 4 functional tests |
| `itch_parser` | `test_parser_edge` | 13 edge tests |
| `feature_extractor` | `test_feature_extractor` | 4 functional tests |
| `feature_extractor` | `test_feat_edge` | 8 edge tests |
| `axi4_lite_slave` | `test_axil_regmap` | 5 register-map tests |
| `lliu_top` | `test_smoke` | `test_single_inference`, `test_two_sequential_inferences` |
| `lliu_top` | `test_constrained_random` | `test_random_100`, `test_random_coverage_closure` |
| `lliu_top` | `test_backpressure` | `test_periodic_stall`, `test_random_backpressure`, `test_pipeline_drain` |
| `lliu_top` | `test_latency` | 6 latency / jitter tests |
| `lliu_top` | `test_error_injection` | `test_truncated_message`, `test_malformed_type`, `test_garbage_recovery` |
| `lliu_top` | `test_wgtmem_outbuf` | 7 weight-memory / output-buffer tests |
| `lliu_top` | `test_integration_sweep` | 10 integration sweep tests |
| `lliu_top` | `test_replay` | `test_replay_non_add_orders`, `test_replay_with_injected_add_orders` *(requires `data/tvagg_sample.bin`)* |

**v1 total: ~110 tests across 18 suites.**

---

### 2.2 Phase 1 v2.0 Suites (new in PRs #40 + #41)

#### `TOPLEVEL = order_book` — `test_order_book.py`

RTL compiled: `lliu_pkg.sv`, `order_book.sv`
Makefile extra flag: `-Wno-MULTIDRIVEN`

| Test function | Spec §ref | Description |
|---------------|-----------|-------------|
| `test_add_order_basic` | §4.3 | Single Add Order; verify BBO registers update |
| `test_delete_order` | §4.3 | Delete resets BBO to 0 when at BBO price |
| `test_replace_order` | §4.3 | Type U atomic cancel + re-add |
| `test_cancel_order` | §4.3 | Partial cancel (type X) reduces shares |
| `test_execute_order` | §4.3 | Execution reduces / removes resting order |
| `test_bbo_best_bid_wins` | §4.3 | Multiple adds; highest bid price wins |
| `test_bbo_best_ask_wins` | §4.3 | Multiple adds; lowest ask price wins |
| `test_stress_10k_adds_5k_deletes_2k_replaces` | §5 Phase 1 | 17K-operation stress; BBO correct at each step |

Drives parsed-ITCH input bus directly (bypasses `itch_parser_v2`).
BBO checked via registered `bbo_query_sym` interface.
Uses `models/order_book_model.py` as the scoreboard reference.

---

#### `TOPLEVEL = order_book` — `test_order_book_collision.py`

Same RTL compilation as `test_order_book`.

| Test function | `expect_fail` | Description |
|---------------|---------------|-------------|
| `test_hash_collision_detected` | **Yes** (step 4–5) | Constructs two `order_ref` values with identical CRC-17 fold; verifies `collision_flag` asserted on modify-type lookup; steps 4–5 document intended Add-collision detection (not yet implemented in RTL — see note) |
| `test_collision_bbo_unaffected` | No | After collision on one side, BBO for non-colliding side remains accurate |
| `test_collision_then_clean_add` | No | Post-collision state; clean add to the same bucket succeeds |

> **RTL note:** Current `order_book.sv` only raises `collision_flag` for modify
> operations (D/X/U/E/C). A colliding Add silently overwrites the ref_mem entry.
> Steps 4–5 of `test_hash_collision_detected` are marked `expect_fail=True`
> to document the gap; they will pass once RTL is updated.

---

#### `TOPLEVEL = ptp_core` — `test_ptp.py`

RTL compiled: `lliu_pkg.sv`, `ptp_core.sv`

| Test function | Description |
|---------------|-------------|
| `test_counter_monotonic` | `ptp_counter` increments by 1 every cycle for 2,048 cycles |
| `test_sync_pulse_period` | Measures cycles between consecutive `ptp_sync_pulse` edges; asserts period = 1,024 |
| `test_epoch_latches_at_sync` | `ptp_epoch` captures `ptp_counter_r` one cycle after `ptp_sync_pulse` |
| `test_counter_after_reset` | `ptp_counter` and `ptp_epoch` return to 0 after synchronous reset |

Clock: 3.2 ns (312.5 MHz). Does **not** instantiate a servo stub — full servo deferred.

---

#### `TOPLEVEL = timestamp_tap` — `test_timestamp_tap.py`

RTL compiled: `lliu_pkg.sv`, `timestamp_tap.sv`

| Test function | Description |
|---------------|-------------|
| `test_timestamp_tap_sub_counter_reset` | Drives `ptp_sync_pulse` and `ptp_epoch` directly from Python; verifies `local_sub_cnt` resets on pulse, `timestamp_out = {epoch_latch, sub_cnt}`, `timestamp_valid` pulses for 1 cycle |

Clock: 3.2 ns. Acts as a stub for `ptp_core`.

---

#### `TOPLEVEL = latency_histogram` — `test_histogram.py`

RTL compiled: `lliu_pkg.sv`, `latency_histogram.sv`

| Test function | Description |
|---------------|-------------|
| `test_single_measurement_bin0` | Delta = 0 → bin[0] increments |
| `test_bin_selection` | Delta = k → bin[k] increments for k in {1, 5, 10, 31} |
| `test_overflow_bin` | Delta = 32 → `overflow_bin` increments |
| `test_multiple_increments` | 100 events to same bin; count = 100 |
| `test_clear` | `axil_clear` resets all bins to 0 |
| `test_sub_counter_wrap` | Delta computed by 10-bit wrap subtraction; wrap-around result maps to correct bin |

Clock: 3.2 ns. Drives `t_start`/`t_end` with raw 74-bit vectors (bypasses `timestamp_tap`).

---

## 3. Models

### `models/order_book_model.py`

Python reference implementation of the Phase 1 order book.
Mirrors the RTL Phase 1 BBO simplification rules:

- **Add / Add-MPID:** update BBO if order is strictly better (bid: higher price; ask: lower price)
- **Delete (D) / Cancel (X):** reset BBO to `(0, 0)` when the removed order was at BBO price
- **Execute (E/C):** same as cancel on the affected qty
- **Replace (U):** delete old ref + add new ref

Used by `test_order_book.py` and `test_order_book_collision.py` as the scoreboard oracle.
**Class:** `OrderBookModel`
**Key methods:** `process_message(msg_type, order_ref, new_order_ref, price, shares, side, sym_id)`, `get_bbo(sym_id)`

> Full rescan logic for accurate L2 BBO after deletes is deferred to Phase 2.

---

## 4. Regression Script

**Command (from repo root):**
```bash
bash scripts/clean_regression_artifacts.sh   # mandatory pre-flight
python3 scripts/run_cocotb_regression.py
```

**Output:** `reports/cocotb_results.xml` — merged JUnit XML with `<summary>` element.

**Total suites registered (Phase 1 + v1):** 23 `(TOPLEVEL, MODULE)` pairs.

Phase 1 entries in `TEST_MODULES`:
```python
("order_book",         "test_order_book"),
("order_book",         "test_order_book_collision"),
("ptp_core",           "test_ptp"),
("timestamp_tap",      "test_timestamp_tap"),
("latency_histogram",  "test_histogram"),
```

**`make clean`** is called automatically between TOPLEVEL changes.
Individual run: `cd tb/cocotb && make SIM=verilator TOPLEVEL=<top> MODULE=tests.<module>`

---

## 5. Regression Baseline (Phase 1 HEAD: `b82688b`)

Full analysis in `reports/phase1_regression.md`. Summary:

| Suite | Tests | Pass | Status |
|-------|-------|------|--------|
| `test_order_book` | 8 | 8 | ✓ |
| `test_order_book_collision` | 3 | 3 | ✓ |
| `test_ptp` | 4 | 4 | ✓ |
| `test_timestamp_tap` | 1 | 1 | ✓ |
| `test_histogram` | 6 | 6 | ✓ |
| `test_feature_extractor` | 4 | 4 | ✓ |
| `test_parser` | 4 | 4 | ✓ |
| `test_parser_edge` | 13 | 13 | ✓ |
| `test_integration_sweep` | 10 | 10 | ✓ |
| `test_wgtmem_outbuf` | 7 | 7 | ✓ |
| `test_axil_regmap` | 11 | 10 | ⚠ 1 new test expects unmapped-register sentinel (0xDEADBEEF) not yet in RTL |
| `test_latency` | 6 | 5 | ⚠ `test_end_to_end_latency_spec` boundary (latency=18, spec `< 18`) — from PR #37 |
| `test_feat_edge` | 8 | 7 | ⚠ `test_zero_price_input`: 0-price gives 0x3f00 not 0 — from PR #37 feature_extractor 2-stage |
| `test_bfloat16_mul` | 2 | 0 | ✗ cocotb v2 pre-NBA read on registered output (from PR #35) |
| `test_bf16_mul_edge` | 12 | 8 | ✗ Same root cause; zero-output tests pass by coincidence |
| `test_fp32_acc` | 3 | 0 | ✗ Same root cause |
| `test_fp32_acc_edge` | 21 | 7 | ✗ Same root cause |
| `test_backpressure` | 3 | 0 | ✗ Pre-existing v1 era + timing regression from PR #37 |
| `test_error_injection` | 3 | 0 | ✗ 1 pre-existing + 2 from PR #37 latency change |
| `test_constrained_random` | 2 | 0 | ✗ Pre-existing v1 era |
| `test_replay` | 2 | 1 | ✗ `test_replay_with_injected_add_orders` pre-existing v1 era |
| `test_smoke` | 2 | — | ⚡ Exit 2 (build race during run; not a real failure) |
| `test_dot_product_engine` | 3 | — | ⚡ Exit 2 (build race during run; not a real failure) |

**Phase 1 (PRs #40/#41) introduced zero new failures.**

### Known fix required — cocotb v2 registered-output read

After `await RisingEdge(dut.clk)`, registered FF outputs are not settled in Verilator + cocotb 2.0.1.  
**Fix:** add `await ReadOnly()` before reading any registered output.  
Affects: `test_bfloat16_mul.py`, `test_bf16_mul_edge.py`, `test_fp32_acc.py`, `test_fp32_acc_edge.py`.

---

## 6. Phase 2 Additions (planned)

| TOPLEVEL | MODULE | New tests |
|----------|--------|-----------|
| `order_book` | `test_order_book_bbo_rescan` | Full L2 rescan after delete (Phase 2 RTL) |
| `ouch_engine` | `test_ouch_compliance` | OUCH 5.0 packet parsing against NASDAQ spec |
| `risk_check` | `test_risk_fuzz` | Fuzz price/qty across all three rule boundaries; verify 100% block rate on OOB inputs |
| `lliu_top_v2` | `test_tick_to_trade` | End-to-end histogram readout; P99 < 100 ns goal |
| `ouch_engine` | `test_tx_backpressure_kill` | Deassert `tx_axis_tready` > 64 cy; verify kill switch |

See [2p0_kintex-7_MAS.md §7](2p0_kintex-7_MAS.md) for full verification strategy.
