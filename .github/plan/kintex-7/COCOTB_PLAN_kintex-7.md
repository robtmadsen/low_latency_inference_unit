# cocotb DV Plan — Kintex-7 KC705 Integration

**Agent:** `cocotb_engineer`  
**Spec:** [Kintex-7_MAS.md](../../arch/kintex-7/Kintex-7_MAS.md)  
**Arch ref:** [COCOTB_ARCH.md](../../arch/v1/COCOTB_ARCH.md)  
**Writes to:** `tb/cocotb/` only  
**Run command:** see `run_cocotb_test_suite` skill for exact invocations

---

## Scope

Four new RTL modules require block-level test files built from scratch. Two existing
v1 modules (`bfloat16_mul`, `dot_product_engine`) have breaking interface changes
that require test updates. One new system-level test ties the full KC705 hot path
together and enforces the MAS performance contract.

```
[Step 1] Update regression for v1 arithmetic changes
         → tests/test_bfloat16_mul.py      (update — clk port added)
         → tests/test_bf16_mul_edge.py     (update — same clk/rst fix as above)
         → tests/test_dot_product_engine.py (update — cycle budget +2)

[Step 2] block-level: MoldUDP64 stripper
         → drivers/moldupp64_builder.py    (NEW)
         → checkers/moldupp64_checker.py   (NEW)
         → tests/test_moldupp64_strip.py   (NEW)
         → tests/test_moldupp64_strip_edge.py (NEW)

[Step 3] block-level: symbol_filter (LUT-CAM)
         → checkers/symbol_filter_checker.py (NEW)
         → tests/test_symbol_filter.py     (NEW)

[Step 4] block-level: eth_axis_rx_wrap (drop-on-full)
         → tests/test_eth_axis_rx_wrap.py  (NEW)

[Step 5] system-level: kc705 hot-path end-to-end
         → tests/test_kc705_e2e.py         (NEW)

[Step 6] performance: MAS latency contract assertions
         → tests/test_kc705_latency.py     (NEW)

[Step 7] coverage closure
         → coverage/functional_coverage.py (update — add new coverpoints)
         → run full suite, verify 100% line coverage
```

---

## Performance Contract (from MAS §2.4)

All latency tests must assert these hard upper bounds. Do **not** relax them.

| Metric | Bound | Domain |
|--------|-------|--------|
| FIFO output beat 0 → `dp_result_valid` | < 18 cycles | 300/250 MHz |
| `parser_fields_valid` → `feat_valid` | < 5 cycles | 300/250 MHz |
| `symbol_filter`: `stock_valid` → `watchlist_hit` | exactly 1 cycle | 300/250 MHz |
| `moldupp64_strip`: beat 2 consumed → first ITCH beat out | ≤ 4 cycles | 156.25 MHz |

The FIFO-output-to-result bound (18 cycles) replaces the v1 AXI4-S 12-cycle spec
for the KC705 hot-path DUT context. The 12-cycle spec is still valid for the
`lliu_top` block-level DUT (no `symbol_filter` inserted).

---

## Step 1 — Update v1 arithmetic regression

**Files:** `tests/test_bfloat16_mul.py`, `tests/test_dot_product_engine.py`

### 1a — `test_bfloat16_mul.py`

The v1 `bfloat16_mul` was combinational (no clock port). The RTL plan adds `clk`
and `rst` ports and registers the output. The existing test drives inputs and
reads `result` on the same delta — this will now read stale data.

Changes required:
- Add `Clock(dut.clk, 10, units="ns").start()` — use 10 ns (100 MHz) for block-level
  test; timing correctness does not depend on the specific block-level frequency.
- Apply reset (`dut.rst.value = 1`, await 2 cycles, deassert).
- After asserting `a` and `b`, await **1 rising edge** before sampling `result`.
- The `test_bf16_mul_edge.py` file uses the same drive pattern — apply identical
  fix there.

Acceptance criterion: all existing test cases pass with the 1-cycle sample offset.

### 1b — `test_dot_product_engine.py`

The FSM latency from `start` → `result_valid` increases by 2 cycles
(1 from `bfloat16_mul` output register + 1 from the additional `fp32_acc` stage).

Changes required:
- Find every `await RisingEdge(dut.clk)` loop that waits for `result_valid` —
  verify the timeout guard is ≥ `VEC_LEN + 6` cycles (was `VEC_LEN + 4`).
- Update any hard-coded cycle-count assertions (e.g. `assert cycle_count == VEC_LEN + 4`)
  to `VEC_LEN + 6`.
- Confirm the end-to-end scoreboard comparison still passes (golden model output is
  unchanged — only timing shifts).

Acceptance criterion: all existing `test_dot_product_engine.py` cases pass with
updated timing guards. Zero scoreboard mismatches.

---

## Step 2 — New block-level tests: `moldupp64_strip`

**DUT TOPLEVEL:** `moldupp64_strip`  
**Domain:** 156.25 MHz → use 6.4 ns clock in tests (`Clock(dut.clk, 6, units="ns")`)  
**Spec:** MAS §2.3

### 2a — `drivers/moldupp64_builder.py` (NEW)

A stimulus helper that constructs valid and intentionally-broken MoldUDP64 datagrams
as lists of 64-bit AXI4-Stream beats.

```python
class MoldUDP64Builder:
    def build(self, session: bytes, seq_num: int, messages: list[bytes]) -> list[Beat]
    # Returns list of (tdata, tkeep, tlast) tuples covering the 20-byte header + all messages.
    # Handles byte packing across beat boundaries automatically.

    def build_gap(self, session: bytes, seq_num: int, skip: int, messages: list[bytes]) -> list[Beat]
    # As above but seq_num is intentionally wrong (creates a gap condition).
```

The builder must handle the header-payload realignment — beat 2 is a split beat
(4 bytes header tail + 4 bytes ITCH payload head). Verify with a unit test inside
the driver file (`if __name__ == "__main__"`) before using in tests.

### 2b — `checkers/moldupp64_checker.py` (NEW)

Concurrent coroutine that monitors the output stream of `moldupp64_strip` and
asserts that:
1. No beat carries MoldUDP64 header bytes (checked by tracking expected ITCH
   message boundaries against `seq_num`/`msg_count` from DUT sideband outputs).
2. `tlast` always coincides with the last byte of an ITCH message.
3. `seq_valid` pulses for exactly 1 cycle per datagram.
4. `expected_seq_num` advances by `msg_count` after each accepted datagram.
5. `expected_seq_num` does NOT advance after a dropped datagram.

### 2c — `tests/test_moldupp64_strip.py` (NEW)

**TOPLEVEL:** `moldupp64_strip`

| Test | What it checks |
|------|----------------|
| `test_single_datagram` | One well-formed MoldUDP64 with 1 ITCH message; verify output tdata/tkeep bit-accurate, `seq_valid` pulse |
| `test_multi_message_datagram` | One datagram with 3 ITCH messages; verify all 3 appear on output stream in order |
| `test_seq_advance` | Two back-to-back datagrams; verify `expected_seq_num` advances by `msg_count` after each |
| `test_passthrough_tlast` | Verify `tlast` on correct beat at end of each ITCH message |
| `test_tready_backpressure` | Assert `m_tready = 0` mid-stream; verify DUT stalls cleanly (no beats lost, no beats duplicated) |
| `test_all_beats_consumed` | After `tlast`, DUT returns to HEADER_B0 state and accepts the next datagram |

All output beats compared against `MoldUDP64Builder` reference output via inline
assertion (not scoreboard — this is a synchronous byte-accuracy check).

### 2d — `tests/test_moldupp64_strip_edge.py` (NEW)

| Test | What it checks |
|------|----------------|
| `test_gap_seq_drop` | Datagram with wrong `seq_num` → all beats discarded, `dropped_datagrams` increments, `expected_seq_num` unchanged |
| `test_dup_seq_drop` | Repeat same `seq_num` twice → second datagram dropped |
| `test_max_seq_num` | `seq_num = 2^64 - 1` → wraps to 0 without overflow error |
| `test_single_byte_itch` | Datagram with `msg_count=1` and a 1-byte payload; verify `tkeep` correctness on output |
| `test_interleaved_good_bad` | Alternating good and bad datagrams; verify `dropped_datagrams` counts only bad, `expected_seq_num` tracks only good |
| `test_latency_budget` | Measure cycles from beat 2 consumed → first ITCH output beat; assert ≤ 4 cycles |

`test_latency_budget` is the MAS §2.3 performance assertion for this block.

---

## Step 3 — New block-level tests: `symbol_filter`

**DUT TOPLEVEL:** `symbol_filter`  
**Domain:** 300 MHz → use 3.33 ns clock (`Clock(dut.clk, 3, units="ns")`)  
**Spec:** MAS §2.4 (CAM implementation subsection)

### 3a — `checkers/symbol_filter_checker.py` (NEW)

Concurrent coroutine that monitors `stock_valid` and `watchlist_hit`:
- When `stock_valid` is asserted, record the `stock` value and the current CAM state.
- On the **next** rising edge, assert that `watchlist_hit` matches the expected result
  from a Python-side CAM model (dict keyed on entry index).
- Any `watchlist_hit = 1` when `stock_valid = 0` on the previous cycle is a protocol
  violation.

### 3b — `tests/test_symbol_filter.py` (NEW)

| Test | What it checks |
|------|----------------|
| `test_empty_cam_no_hit` | No entries loaded → `watchlist_hit` never asserts |
| `test_single_entry_hit` | Load one entry at index 0; present matching stock → `watchlist_hit = 1` after 1 cycle |
| `test_single_entry_miss` | Same entry loaded; present non-matching stock → `watchlist_hit = 0` |
| `test_all_64_entries_hit` | Load all 64 entries with unique symbols; iterate all 64 stocks → all hit |
| `test_all_64_entries_miss` | Load 64 entries; present 64 different stocks not in CAM → no hits |
| `test_entry_invalidate` | Load entry; confirm hit; set `cam_wr_en_bit = 0` → same stock now misses |
| `test_overwrite_entry` | Write new symbol to occupied index; old symbol misses, new symbol hits |
| `test_write_during_lookup` | Assert `cam_wr_valid` and `stock_valid` on the same cycle; verify no RAW hazard |
| `test_1_cycle_latency` | Measure cycles from `stock_valid` → `watchlist_hit`; assert exactly 1 |
| `test_back_to_back` | 10 consecutive `stock_valid` pulses (alternating hit/miss); verify latency = 1 every time |

`test_1_cycle_latency` is the MAS single-cycle performance assertion for this block.

---

## Step 4 — New block-level tests: `eth_axis_rx_wrap`

**DUT TOPLEVEL:** `eth_axis_rx_wrap`  
**Domain:** 156.25 MHz → use 6.4 ns clock  
**Spec:** MAS §2.2

> **Note:** `eth_axis_rx_wrap` is a thin wrapper around the Forencich `eth_axis_rx`
> module. The Forencich source tree must be on the Verilator include path. If
> Forencich IP is not available in the repo at test time, stub `eth_axis_rx` with
> a pass-through model and add a `TODO` comment flagging the dependency.

### 4a — Tests

| Test | What it checks |
|------|----------------|
| `test_normal_passthrough` | `fifo_almost_full = 0`; send 3 frames; all appear on `eth_payload_*` unchanged |
| `test_drop_on_full_single` | Assert `fifo_almost_full` before frame start; verify entire frame suppressed (`eth_payload_tvalid` never asserts), `dropped_frames` increments by 1 |
| `test_mac_never_stalls` | Assert `fifo_almost_full` mid-send; verify `mac_rx_tready` stays 1 throughout drop |
| `test_frame_drop_is_whole` | `fifo_almost_full` asserts during frame N; verify frame N is fully dropped (no partial beats on output) |
| `test_drop_then_pass` | Drop frame N; clear `fifo_almost_full`; verify frame N+1 passes through normally |
| `test_consecutive_drops` | Keep `fifo_almost_full` asserted for 5 frames; verify `dropped_frames = 5` |
| `test_counter_saturation` | Drive `dropped_frames` to `32'hFFFF_FFFF`; verify no overflow on next drop |
| `test_backpressure_downstream` | Assert `eth_payload_tready = 0` for an extended period (simulating a full downstream pipeline); verify `fifo_almost_full` eventually rises (or drive it directly), the next-frame drop policy activates, and `mac_rx_tready` stays 1 throughout. The design has **no internal buffer**: when not in drop mode and downstream is stalled, in-flight beats would be lost — this test must *not* assert "no data loss." Instead assert that once `almost_full` rises the drop policy cleanly prevents new frames from entering the stack. |

---

## Step 5 — System-level: `kc705_top` hot path

**DUT TOPLEVEL:** `kc705_top`  
**File:** `tests/test_kc705_e2e.py` (NEW)  
**Spec:** MAS §1 (block diagram), §3 (interfaces)

This test instantiates the full KC705 design. It drives raw Ethernet frames at the
`mac_rx_*` ports and reads inference results on `dp_result` / `dp_result_valid`.
All intermediate modules (mol strip, async FIFO, symbol filter, LLIU core) are exercised
as a black box.

> **Clock setup:** Two independent `Clock` coroutines — `clk_156` at 6.4 ns and
> `clk_300` at 3.33 ns — must both run concurrently. Use `cocotb.start_soon()` for
> both. All assertions on output signals must be synchronised to `clk_300`.
>
> **Simulation bypass:** The Makefile invocation for `test_kc705_e2e` must pass
> `+define+KINTEX7_SIM_MAC_BYPASS` (VERILATOR_FLAGS or SIM_ARGS). This exposes
> `mac_rx_*` and `clk_156_in` as top-level ports on `kc705_top` and removes the
> GTX/MAC-PHY instantiation that cannot be simulated in Verilator. Without this
> define the Verilator compile will fail on the GTX transceiver primitive.

### Setup sequence (fixture / conftest)

```python
1. Drive cpu_reset = 1 for 10 clk_156 cycles
2. Deassert cpu_reset
3. Load symbol_filter CAM via axil: write target stock (e.g. b"AAPL    ") to entry 0
4. Load weight_mem via axil: write test weight vector
5. System is ready for stimulus
```

### Tests

| Test | What it checks |
|------|----------------|
| `test_itch_add_order_hit` | Inject Ethernet → IP → UDP → MoldUDP64 → ITCH Add Order for watched symbol; verify `dp_result_valid` asserts |
| `test_itch_add_order_miss` | Same frame, stock not in watchlist; verify `dp_result_valid` never asserts |
| `test_multi_symbol_filter` | Load 4 symbols in CAM; inject 4 Add Orders (2 hit, 2 miss); verify only 2 results produced |
| `test_mold_header_stripped` | Verify `dp_result_valid` does NOT assert on a raw MoldUDP64-header-only frame (no ITCH payload) |
| `test_seq_gap_drop` | Inject datagram with wrong `seq_num`; verify no inference result, `dropped_datagrams` increments |
| `test_fifo_drop_on_full` | Burst frames faster than hot path can drain; verify `dropped_frames` increments and no pipeline corruption |
| `test_weight_hot_reload` | Change AXI4-Lite weight during operation; verify next inference uses new weights |
| `test_reset_recovery` | Assert `cpu_reset` mid-pipeline; verify clean pipeline flush and correct operation on next frame |
| `test_result_readout_axil` | After `dp_result_valid`, read `dp_result` via AXI4-Lite; verify matches golden model |

Each test compares `dp_result` against `golden_model.py` output with the same stock
features and weights.

---

## Step 6 — Performance tests: MAS latency contract

**DUT TOPLEVEL:** `kc705_top`  
**File:** `tests/test_kc705_latency.py` (NEW)

All performance bounds from the MAS table (§2.4) must be asserted as hard failures,
not warnings. Use `latency_profiler.py` infrastructure from v1 where available.

### Latency measurements

| Measurement | Start event | End event | Bound |
|-------------|-------------|-----------|-------|
| Hot-path latency | FIFO read-side first beat valid | `dp_result_valid` rising | < 18 cycles (clk_300) |
| Parser latency | `parser_fields_valid` rising | `feat_valid` rising | < 5 cycles (clk_300) |
| Symbol filter latency | `stock_valid` rising | `watchlist_hit` rising | exactly 1 cycle (clk_300) |
| MoldUDP64 strip latency | Beat 2 consumed (state → PAYLOAD) | First `m_tvalid` beat | ≤ 4 cycles (clk_156) |

### Tests

| Test | What it checks |
|------|----------------|
| `test_hotpath_latency_single` | Single Add Order, measure from FIFO beat 0 → `dp_result_valid`; assert < 18 |
| `test_hotpath_latency_burst` | 100 consecutive Add Orders (same symbol, watched); record max latency; assert max < 18 |
| `test_hotpath_latency_backpressure` | Inject periodic `tready = 0` stalls on AXI4-Lite readout; verify no latency regression on pipeline timing (stall is downstream of `dp_result_valid`) |
| `test_parser_latency` | Measure `parser_fields_valid` → `feat_valid` across 50 messages; assert p99 < 5 |
| `test_symbol_filter_latency` | 64 consecutive `stock_valid` pulses; verify `watchlist_hit` follows with exactly 1-cycle lag every time |
| `test_250mhz_hotpath` | Re-run `test_hotpath_latency_burst` with `clk_300` overridden to 4 ns (250 MHz); assert < 18 cycles still holds (same cycle budget, lower frequency) |

`test_250mhz_hotpath` validates the MAS 250 MHz fallback path without a separate
bitstream — cycle counts must be identical; only wall-clock ns changes.

> **Clock override implementation:** `conftest.py` starts `clk_300` at 3.33 ns.
> `test_250mhz_hotpath` must NOT rely on conftest for `clk_300`. Either:
> (a) cancel the conftest clock task and start a new `Clock(dut.clk_300, 4, "ns")`
>     coroutine at the top of the test, or
> (b) move `clk_300` setup out of conftest and into a shared fixture that each test
>     can parameterise.
> Option (a) is simpler for a single test; option (b) is better if more
> frequency-sweep tests are anticipated.

---

## Step 7 — Coverage closure

**File:** `coverage/functional_coverage.py` (update)

### New coverpoints required for KC705 modules

Add the following coverpoint groups to `functional_coverage.py`:

```python
# MoldUDP64 strip
CoverGroup("moldupp64"):
    cp_seq_state:     bins = [ACCEPTED, DROPPED_GAP, DROPPED_DUP]
    cp_msg_count:     bins = [1, 2..4, 5..15, 16..255]  # messages per datagram
    cross:            cp_seq_state × cp_msg_count

# Symbol filter
CoverGroup("symbol_filter"):
    cp_cam_result:    bins = [HIT, MISS]
    cp_cam_index:     bins = [0, 1..31, 32..63]          # which entry hit
    cp_back_to_back:  bins = [SINGLE, CONSECUTIVE_2, CONSECUTIVE_3PLUS]
    cross:            cp_cam_result × cp_cam_index

# Drop-on-full wrapper
CoverGroup("eth_axis_rx_wrap"):
    cp_drop_event:    bins = [NO_DROP, DROP_SINGLE, DROP_CONSECUTIVE_2PLUS]
    cp_dropped_frames: bins = [0, 1..10, 11..100, OVERFLOW]
    cross:            cp_drop_event × cp_dropped_frames
```

### Coverage closure checklist

Run the full suite and verify all bins hit at 100% before sign-off:

```
make TOPLEVEL=moldupp64_strip MODULE=test_moldupp64_strip,test_moldupp64_strip_edge
make TOPLEVEL=symbol_filter MODULE=test_symbol_filter
make TOPLEVEL=eth_axis_rx_wrap MODULE=test_eth_axis_rx_wrap
make TOPLEVEL=kc705_top MODULE=test_kc705_e2e,test_kc705_latency
make coverage_report
```

### Line coverage targets

| Module | Target | Method |
|--------|--------|--------|
| `moldupp64_strip` | 100% | All 5 FSM states entered; both DROP paths exercised |
| `symbol_filter` | 100% | All 64 CAM entries written; hit and miss paths |
| `eth_axis_rx_wrap` | 100% | Normal, drop-single, drop-consecutive, counter-saturation paths |
| `kc705_top` (glue logic only) | 100% | System-level tests cover all wire assignments; Forencich modules excluded |
| `bfloat16_mul` (updated) | 100% | Existing edge tests + 1-cycle sample fix covers all paths |
| `dot_product_engine` (updated) | 100% | Existing tests + updated timeout guards |

Forencich third-party modules (`eth_mac_phy_10g`, `ip_complete_64`, etc.) are
**excluded** from line coverage targets — they are vendor IP.

---

## New File Summary

| File | Type | Step |
|------|------|------|
| `drivers/moldupp64_builder.py` | Driver / stimulus builder | 2a |
| `checkers/moldupp64_checker.py` | Protocol checker | 2b |
| `checkers/symbol_filter_checker.py` | Protocol checker | 3a |
| `tests/test_moldupp64_strip.py` | Block-level test | 2c |
| `tests/test_moldupp64_strip_edge.py` | Edge-case test | 2d |
| `tests/test_symbol_filter.py` | Block-level test | 3b |
| `tests/test_eth_axis_rx_wrap.py` | Block-level test | 4 |
| `tests/test_kc705_e2e.py` | System-level test | 5 |
| `tests/test_kc705_latency.py` | Performance test | 6 |

**Modified files:**

| File | Change |
|------|--------|
| `tests/test_bfloat16_mul.py` | Add clk/rst, 1-cycle sample offset |
| `tests/test_bf16_mul_edge.py` | Same clk/rst fix |
| `tests/test_dot_product_engine.py` | Timeout guard +2 cycles, cycle-count assertions updated |
| `coverage/functional_coverage.py` | Three new CoverGroups |

---

## Completion Checklist

| Step | Item | Status |
|------|------|--------|
| 1a | `test_bfloat16_mul.py` — registered output fix | ⬜ |
| 1b | `test_dot_product_engine.py` — cycle budget +2 | ⬜ |
| 2a | `drivers/moldupp64_builder.py` | ⬜ |
| 2b | `checkers/moldupp64_checker.py` | ⬜ |
| 2c | `tests/test_moldupp64_strip.py` | ⬜ |
| 2d | `tests/test_moldupp64_strip_edge.py` | ⬜ |
| 3a | `checkers/symbol_filter_checker.py` | ⬜ |
| 3b | `tests/test_symbol_filter.py` | ⬜ |
| 4  | `tests/test_eth_axis_rx_wrap.py` | ⬜ |
| 5  | `tests/test_kc705_e2e.py` | ⬜ |
| 6  | `tests/test_kc705_latency.py` (all 6 perf assertions) | ⬜ |
| 7  | `coverage/functional_coverage.py` — 3 new CoverGroups | ⬜ |
| 7  | Full suite: zero mismatches, zero checker violations | ⬜ |
| 7  | 100% line coverage on all 4 new modules | ⬜ |
| 7  | All MAS performance bounds asserted as hard failures | ⬜ |

> All steps depend on the RTL plan (RTL_PLAN_kintex-7.md) completing first.
> Do not begin Step 2 until `moldupp64_strip.sv` compiles cleanly.
> Do not begin Step 5 until `kc705_top.sv` compiles cleanly.
