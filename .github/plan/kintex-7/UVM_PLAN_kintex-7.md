# UVM DV Plan — Kintex-7 KC705 Integration

**Agent:** `uvm_engineer`  
**Spec:** [Kintex-7_MAS.md](../../arch/kintex-7/Kintex-7_MAS.md)  
**Arch ref:** [UVM_ARCH.md](../../arch/v1/UVM_ARCH.md)  
**Writes to:** `tb/uvm/` only  
**Golden model:** `tb/cocotb/models/golden_model.py` (read-only; shared with `cocotb_engineer`)  
**Run command:** see `run_uvm_test_suite` skill for exact invocations

---

## Scope

The v1 UVM testbench drives `lliu_top` (the ITCH parser → inference pipeline). For the
KC705 integration, three new modules require dedicated block-level coverage and two
existing SVA files require timing bound updates. One new system-level test targets the
full KC705 hot path via `kc705_top`.

The existing agent infrastructure (`axi4_stream_agent`, `axi4_lite_agent`), scoreboard,
and DPI-C bridge reuse without modification — the same two agents drive all new
block-level tests.

```
[Step 1] Update SVA timing bounds for v1 arithmetic changes
         → sva/dot_product_sva.sv        (update — latency +2 cycles)
         → sva/end_to_end_latency_sva.sv (update — hot-path DUT context)

[Step 2] New sequences: KC705 stimulus
         → sequences/moldupp64_seq.sv    (NEW)
         → sequences/cam_load_seq.sv     (NEW)
         → sequences/kc705_init_seq.sv   (NEW)

[Step 3] New SVA: KC705 modules
         → sva/moldupp64_sva.sv          (NEW)
         → sva/symbol_filter_sva.sv      (NEW)
         → sva/drop_on_full_sva.sv       (NEW)

[Step 4] New tests: block-level
         → tests/lliu_moldupp64_test.sv  (NEW)
         → tests/lliu_symfilter_test.sv  (NEW)
         → tests/lliu_dropfull_test.sv   (NEW)

[Step 5] New test: KC705 system-level
         → tests/lliu_kc705_test.sv      (NEW)

[Step 6] New test: KC705 performance contract
         → tests/lliu_kc705_perf_test.sv (NEW)
         → perf/kc705_latency_monitor.sv (NEW)

[Step 7] Coverage model extension
         → env/lliu_coverage.sv          (update — add 3 new CoverGroups)

[Step 8] Full regression + coverage closure
```

---

## Performance Contract (from MAS §2.4)

All `assert property` bounds below are **hard failures** — no `$warn`, no lookahead
relaxation. These map directly to SVA concurrent properties.

| Property | Bound | Clock |
|----------|-------|-------|
| FIFO read beat 0 → `dp_result_valid` | < 18 cycles | `clk_300` |
| `parser_fields_valid` → `feat_valid` | < 5 cycles | `clk_300` |
| `symbol_filter.stock_valid` → `watchlist_hit` | exactly 1 cycle | `clk_300` |
| `moldupp64_strip` beat 2 consumed → first `m_tvalid` | ≤ 4 cycles | `clk_156` |

---

## Step 1 — Update existing SVA timing bounds

**Files:** `sva/dot_product_sva.sv`, `sva/end_to_end_latency_sva.sv`

### 1a — `sva/dot_product_sva.sv`

The v1 `bfloat16_mul` was combinational. After the RTL plan change (registered output
+ two-stage `fp32_acc`), the `start` → `result_valid` latency increases by 2 cycles.

Find the property that asserts `result_valid` within `VEC_LEN + 4` cycles of `start`
and update the upper bound to `VEC_LEN + 6`. If a lower-bound assertion exists
(`result_valid` must not assert earlier than `VEC_LEN + N`), update it symmetrically.

```systemverilog
// Before:
p_result_timing: assert property (
    @(posedge clk) disable iff (rst)
    $rose(start) |-> ##[1:VEC_LEN+4] result_valid);

// After:
p_result_timing: assert property (
    @(posedge clk) disable iff (rst)
    $rose(start) |-> ##[1:VEC_LEN+6] result_valid);
```

### 1b — `sva/end_to_end_latency_sva.sv`

The v1 end-to-end property measures from AXI4-Stream `tlast` (last ITCH beat accepted)
to `dp_result_valid`. The v1 bound was 12 cycles (for `lliu_top` as DUT).

For the KC705 hot-path (`kc705_top` DUT), the FIFO adds ~5 cycles and `symbol_filter`
adds 1 cycle. The new bound for `kc705_top` is **18 cycles** from FIFO read-side beat 0.

Two separate properties are required:

1. **Keep the v1 property** for `lliu_top` DUT tests (still 12 cycles from `tlast`).
   Protect with a `` `ifdef LLIU_TOP_DUT `` guard so it does not fire during KC705 tests.

2. **Add a KC705 property** measuring from `axis_async_fifo` read-side `tvalid`
   (first beat after CDC) to `dp_result_valid`, bound < 18 cycles.
   Guard with `` `ifdef KC705_TOP_DUT ``.

The Makefile must pass the appropriate define flag based on `TOPLEVEL`:
```makefile
# In tb/uvm/Makefile:
ifeq ($(TOPLEVEL),kc705_top)
  VFLAGS += -DKC705_TOP_DUT
else
  VFLAGS += -DLLIU_TOP_DUT
endif
```

---

## Step 2 — New sequences

### 2a — `sequences/moldupp64_seq.sv` (NEW)

A constrained-random sequence that constructs valid and intentionally malformed
MoldUDP64 datagrams as AXI4-Stream beats and drives them through the
`axi4_stream_agent` sequencer.

```
Fields randomized:
  seq_num        [63:0]  — valid in-order, or intentional gap/dup
  msg_count      [15:0]  — 1..255

Constraints:
  c_normal:  seq_num == last_accepted + last_msg_count  (in-order)
  c_gap:     seq_num > last_accepted + last_msg_count   (drop expected)
  c_dup:     seq_num < last_accepted                    (drop expected)
  c_msg_cnt: msg_count inside {1, [2:4], [5:15], [16:255]}
```

Derives from `itch_random_seq.sv` stimulus infrastructure. The 20-byte header
byte-packing across 64-bit beats must be handled here (not in the driver — the driver
is protocol-agnostic AXI4-Stream).

### 2b — `sequences/cam_load_seq.sv` (NEW)

Drives `axi4_lite_agent` sequencer to write entries into the `symbol_filter` CAM.

```
Fields:
  cam_index  [7:0]   — entry to write (0–63)
  cam_key    [63:0]  — 8-character ASCII ticker
  cam_valid  [0:0]   — 1 = valid entry, 0 = invalidate

Operations:
  task load_entry(int index, logic [63:0] key)
  task invalidate_entry(int index)
  task load_watchlist(logic [63:0] tickers[$])  // bulk load from array
  task clear_all()                               // invalidate all 64 entries
```

Reuses the `axil_rw_seq.sv` base sequence for individual register writes. Address
encoding: `addr[7:2] = cam_index`, `addr[1] = valid_bit` (per port spec in RTL plan).

### 2c — `sequences/kc705_init_seq.sv` (NEW)

A virtual sequence that composes the full KC705 board bring-up sequence. Runs before
any traffic test:

```
1. Drive cpu_reset for 10 clk_156 cycles, deassert
2. Wait for GTX lock — see simulation note below
3. cam_load_seq: load default watchlist (configurable via test)
4. weight_load_seq: preload weight vector (reuse existing weight_load_seq.sv)
5. Assert kc705_ready flag for test to proceed
```

> **Register map prerequisite:** Step 2 requires an AXI4-Lite `gtx_lock_status`
> read-only register (bit 0 = PLL locked). This register is NOT present in the v1
> `axi4_lite_slave`. The RTL plan (Step 5b) must define its address offset in
> `lliu_pkg.sv` and add the register to `axi4_lite_slave.sv` before this sequence
> can be written. Coordinate address with `rtl_engineer` before implementation.
>
> **Simulation guard:** In Verilator simulation the GTX transceiver is not present.
> The `gtx_lock_status` register must read 1 immediately (tie-off in simulation
> mode via `KINTEX7_SIM_GTX_BYPASS` conditional). The sequence must check the UVM
> config DB for a `kc705_sim_mode` bit before polling; if set, skip the GTX lock
> poll and proceed directly to step 3. Example:
> ```systemverilog
> bit sim_mode;
> void'(uvm_config_db #(bit)::get(null, "", "kc705_sim_mode", sim_mode));
> if (!sim_mode) begin
>   // poll gtx_lock_status via axil_rw_seq, timeout 1000 cycles
> end
> ```
> All KC705-context tests must set `kc705_sim_mode = 1` in their `build_phase`.

This sequence is called from `start_of_simulation` in `lliu_kc705_test.sv` and all
KC705-context tests.

---

## Step 3 — New SVA files

### 3a — `sva/moldupp64_sva.sv` (NEW)

Bind target: `moldupp64_strip`

```systemverilog
// P1: seq_valid pulses exactly once per accepted datagram
p_seq_valid_pulse: assert property (
    @(posedge clk) disable iff (rst)
    $rose(seq_valid) |-> ##1 !seq_valid);

// P2: output stream never carries beats after dropped datagram
// (drop state: s_tvalid asserted but m_tvalid must not assert)
p_no_output_on_drop: assert property (
    @(posedge clk) disable iff (rst)
    (drop_state && s_tvalid) |-> !m_tvalid);

// P3: expected_seq_num increments by msg_count after each accepted datagram
// (checked cycle-accurately on seq_valid pulse)
p_seq_advance: assert property (
    @(posedge clk) disable iff (rst)
    $rose(seq_valid) |->
        ##1 (expected_seq_num == $past(expected_seq_num) + $past(msg_count)));

// P4: latency — beat 2 consumed to first m_tvalid
p_strip_latency: assert property (
    @(posedge clk) disable iff (rst)
    $rose(header_done) |-> ##[1:4] $rose(m_tvalid));

// P5: m_tready backpressure — no beats lost
// When m_tready deasserted and m_tvalid asserted, same tdata/tkeep must re-appear
p_no_data_loss_on_stall: assert property (
    @(posedge clk) disable iff (rst)
    (m_tvalid && !m_tready) |-> ##1 (m_tvalid && $stable(m_tdata) && $stable(m_tkeep)));
```

> `header_done` and `drop_state` are internal signals exposed for SVA binding.
> The RTL engineer must mark them `(* keep = "true" *)` or use `$root` hierarchical
> references — coordinate with `rtl_engineer` before writing these assertions.

### 3b — `sva/symbol_filter_sva.sv` (NEW)

Bind target: `symbol_filter`

```systemverilog
// P1: watchlist_hit is registered — exactly 1 cycle after stock_valid
p_hit_latency: assert property (
    @(posedge clk) disable iff (rst)
    $rose(stock_valid) |-> ##1 $changed(watchlist_hit));

// P2: watchlist_hit never asserts if stock_valid was 0 on previous cycle
p_no_spurious_hit: assert property (
    @(posedge clk) disable iff (rst)
    (!$past(stock_valid)) |-> !watchlist_hit);

// P3: back-to-back stock_valid — watchlist_hit follows with 1-cycle lag every time
p_pipeline_throughput: assert property (
    @(posedge clk) disable iff (rst)
    (stock_valid ##1 stock_valid) |->
        (watchlist_hit == expected_hit_delayed_1));
// Note: expected_hit_delayed_1 is a local variable computed from cam model in tb_top

// P4: CAM write does not corrupt registered output mid-lookup
p_write_isolation: assert property (
    @(posedge clk) disable iff (rst)
    (cam_wr_valid && stock_valid) |->
        ##1 (watchlist_hit == $past(cam_entry_match)));
```

### 3c — `sva/drop_on_full_sva.sv` (NEW)

Bind target: `eth_axis_rx_wrap`

```systemverilog
// P1: MAC never stalled — mac_rx_tready must always be 1
p_mac_tready_never_low: assert property (
    @(posedge clk) disable iff (rst)
    mac_rx_tready === 1'b1);

// P2: frame drop is atomic — if drop_current asserted, eth_payload_tvalid never asserts
p_no_partial_frame: assert property (
    @(posedge clk) disable iff (rst)
    drop_current |-> !eth_payload_tvalid);

// P3: drop decision is frame-granular — drop flag cannot change mid-frame
p_drop_stable_mid_frame: assert property (
    @(posedge clk) disable iff (rst)
    (frame_active && drop_current) |-> ##1 (drop_current || mac_rx_tlast));

// P4: dropped_frames counter monotonically non-decreasing (no rollback)
p_counter_monotonic: assert property (
    @(posedge clk) disable iff (rst)
    dropped_frames >= $past(dropped_frames));

// P5: counter increments by exactly 1 per dropped frame
p_counter_increment: assert property (
    @(posedge clk) disable iff (rst)
    ($rose(mac_rx_tlast) && drop_current) |->
        ##1 (dropped_frames == $past(dropped_frames) + 1 ||
             dropped_frames == 32'hFFFF_FFFF));  // saturate case
```

> `drop_current`, `frame_active` are internal signals. Coordinate `(* keep = "true" *)`
> annotations with `rtl_engineer`.

---

## Step 4 — New block-level tests

All three block-level tests use `TOPLEVEL` set to the individual module under test.
Both the `axi4_stream_agent` and `axi4_lite_agent` are instantiated even for block
targets where only one is needed — the unused agent runs in passive monitoring mode.

### 4a — `tests/lliu_moldupp64_test.sv` (NEW)

```
class lliu_moldupp64_test extends lliu_base_test;
  DUT TOPLEVEL: moldupp64_strip
  Sequences used: moldupp64_seq (directed + constrained-random)
```

| Scenario | Sequence config | Pass criterion |
|----------|-----------------|----------------|
| Single datagram, 1 message | in-order, msg_count=1 | scoreboard match, seq_valid pulse, SVA no violations |
| Single datagram, 16 messages | in-order, msg_count=16 | all 16 ITCH messages on output, tlast on correct beat |
| Gap drop | c_gap constraint active | dropped_datagrams++, no output on m_*, expected_seq_num unchanged |
| Duplicate drop | c_dup constraint | same as gap drop |
| 100 back-to-back datagrams (random) | c_normal, randomized msg_count | zero scoreboard mismatches, all SVA clean |
| Backpressure: m_tready toggle | in-order + backpressure_seq on output side | no data loss, P5 SVA passes |
| Latency: beat 2 → m_tvalid | single datagram | `p_strip_latency` SVA passes (≤ 4 cycles) |

Coverage contribution: exercises `moldupp64` CoverGroup (see Step 7).

### 4b — `tests/lliu_symfilter_test.sv` (NEW)

```
class lliu_symfilter_test extends lliu_base_test;
  DUT TOPLEVEL: symbol_filter
  Sequences used: cam_load_seq + itch_random_seq (stock field only)
```

| Scenario | Setup | Pass criterion |
|----------|-------|----------------|
| Empty CAM, 10 lookups | No entries loaded | `watchlist_hit` always 0, `p_no_spurious_hit` passes |
| Single entry, hit | cam_load_seq: entry 0 = target stock | `watchlist_hit` = 1, exactly 1 cycle after `stock_valid` |
| Single entry, miss | cam_load_seq: entry 0 = different stock | `watchlist_hit` = 0 |
| Full 64-entry hit sweep | load all 64 unique tickers | 64/64 hit, `p_hit_latency` passes for all |
| Invalidate and re-check | load → invalidate → same stock | no hit after invalidate |
| Overwrite entry | load key A → overwrite with key B → lookup both | key A miss, key B hit |
| Write-during-lookup | cam_wr_valid && stock_valid same cycle | `p_write_isolation` SVA passes |
| Back-to-back 20 lookups | alternating hit/miss, in-order | latency = 1 every time, `p_pipeline_throughput` passes |

### 4c — `tests/lliu_dropfull_test.sv` (NEW)

```
class lliu_dropfull_test extends lliu_base_test;
  DUT TOPLEVEL: eth_axis_rx_wrap
  Sequences used: itch_random_seq (raw frame stimulus on mac_rx_* side)
```

| Scenario | fifo_almost_full state | Pass criterion |
|----------|------------------------|----------------|
| Normal passthrough | 0 throughout | all frames on eth_payload, `dropped_frames` = 0 |
| Single drop | assert at frame N start | frame N suppressed, `dropped_frames` = 1, `p_mac_tready_never_low` passes |
| Drop then pass | drop frame N, clear flag | frame N+1 passes cleanly |
| 5 consecutive drops | flag held for 5 frames | `dropped_frames` = 5, `p_drop_stable_mid_frame` passes |
| MAC always ready | flag asserted mid-frame | `p_mac_tready_never_low` — tready stays 1, frame dropped whole |
| Counter saturation | pre-load counter to 32'hFFFFFFFE, trigger 2 drops | counter reaches 32'hFFFFFFFF, stops there; `p_counter_monotonic` holds |

---

## Step 5 — New KC705 system-level test

**File:** `tests/lliu_kc705_test.sv` (NEW)  
**DUT TOPLEVEL:** `kc705_top`

```
class lliu_kc705_test extends lliu_base_test;
  virtual sequence: kc705_init_seq (reset + CAM load + weight preload)
  then: targeted scenarios below
```

This test drives raw Ethernet frames into the `mac_rx_*` ports and observes
`dp_result` / `dp_result_valid` on the `clk_300` domain. The scoreboard compares
`dp_result` against the shared Python golden model (via DPI-C bridge, same
`golden_model.py` used by cocotb).

> **Dual-clock note:** `tb_top.sv` must be updated to generate and connect both
> `clk_156` (6.4 ns) and `clk_300` (3.33 ns) when `TOPLEVEL=kc705_top`. Use the
> same `TOPLEVEL`-conditioned Makefile define from Step 1b to select the correct
> `tb_top.sv` clock configuration. Scoreboard sampling must be synchronised to
> `clk_300`.
>
> **Simulation bypass:** The Makefile for `lliu_kc705_test` must add
> `+define+KINTEX7_SIM_GTX_BYPASS` so that `kc705_top` exposes the `mac_rx_*` and
> `clk_156_in` ports for the testbench to drive. Without this define the GTX
> transceiver path is active and Verilator will fail to compile. The `kc705_sim_mode`
> config DB key must also be set to `1` so `kc705_init_seq` skips the GTX lock poll.
>
> **Frame encapsulation:** All sequences driving `kc705_top` via `mac_rx_*` must
> now construct fully encapsulated Ethernet frames (Eth/IPv4/UDP/MoldUDP64 headers)
> because `ip_complete_64` and `udp_complete_64` are now instantiated in simulation.
> See MAS §6.3 for the required header layout and `ip_complete_64` configuration.

| Scenario | Sequence | Pass criterion |
|----------|----------|----------------|
| Add Order, watched symbol | moldupp64_seq(in-order) + cam with target loaded | `dp_result_valid`, scoreboard match |
| Add Order, unwatched symbol | same frame, stock not in CAM | `dp_result_valid` never asserts |
| Mixed 4 orders: 2 hit, 2 miss | cam_load_seq(2 entries) + 4 orders | exactly 2 `dp_result_valid` pulses, both match golden |
| Gap drop: seq_num skip | moldupp64_seq(c_gap) | no inference result; `dropped_datagrams` AXI4-Lite read increments |
| FIFO drop-on-full | burst beyond FIFO capacity | `dropped_frames` AXI4-Lite read increments, pipeline not corrupted afterward |
| Weight hot reload | write new AXI4-Lite weights mid-run | next inference uses new weights, scoreboard matches updated golden model |
| Reset recovery | assert cpu_reset mid-pipeline | clean flush, correct operation on next frame |
| Back-to-back 50 orders | in-order, all same watched symbol | 50 scoreboard matches, zero SVA violations |
| AXI4-Lite result readout | single order, read `dp_result` via axil | result matches `dp_result_valid` output; AXI4-Lite timing SVA passes |

---

## Step 6 — KC705 performance test

**Files:** `tests/lliu_kc705_perf_test.sv` (NEW), `perf/kc705_latency_monitor.sv` (NEW)

### 6a — `perf/kc705_latency_monitor.sv` (NEW)

Extends the v1 `lliu_latency_monitor.sv` pattern with two new measurement channels:

```
Channel 1 (clk_300): FIFO read-side tvalid beat 0 → dp_result_valid
  → timestamp at: axis_async_fifo.m_tvalid rising edge (first beat of new message)
  → end at:       dp_result_valid rising edge
  → bound:        < 18 cycles

Channel 2 (clk_156): moldupp64_strip header_done → m_tvalid
  → timestamp at: internal header_done signal
  → end at:       m_tvalid rising edge
  → bound:        ≤ 4 cycles

Existing channels preserved:
  parser_fields_valid → feat_valid:  < 5 cycles (clk_300)
  stock_valid → watchlist_hit:       == 1 cycle  (clk_300)
```

Reports min/max/mean/p99 per channel. All bounds are asserted at end-of-test via
`uvm_error` (not `uvm_warning`) if violated.

### 6b — `tests/lliu_kc705_perf_test.sv` (NEW)

```
class lliu_kc705_perf_test extends lliu_kc705_test;
```

Inherits the full KC705 system context. Runs performance-specific scenarios:

| Test scenario | Description | Assertion |
|---------------|-------------|-----------|
| `single_msg_hotpath` | 1 Add Order → measure FIFO out → `dp_result_valid` | < 18 cycles (hard `uvm_error`) |
| `burst_100_hotpath` | 100 back-to-back Add Orders → record max latency | max < 18 cycles |
| `parser_to_feat_latency` | 50 messages → `parser_fields_valid` → `feat_valid` | p99 < 5 cycles |
| `symbol_filter_latency` | 64 consecutive `stock_valid` pulses → `watchlist_hit` | exactly 1 every time (zero violations) |
| `strip_latency` | 20 datagrams → beat 2 consumed → first m_tvalid | max ≤ 4 cycles |
| `250mhz_fallback` | Override `clk_300` to 4.0 ns (250 MHz) via DPI-C clock gen; re-run burst_100 | cycle count unchanged (≤ 18); test verifies clock-agnostic cycle budget |

For `250mhz_fallback`: the clock period change must be applied in `tb_top.sv` via a
runtime parameter (not a static `parameter`) so the UVM test can override it through
the config DB without recompilation.

---

## Step 7 — Coverage model extension

**File:** `env/lliu_coverage.sv` (update)

Add three new `covergroup` blocks. Keep all v1 covergroups (`itch_msg_type_cg`,
`price_range_cg`, `side_cg`, `backpressure_cg`, and their crosses) unchanged.

### New CoverGroup 1: `moldupp64_cg`

```systemverilog
covergroup moldupp64_cg @(posedge clk_156);
  cp_seq_state: coverpoint seq_state {
    bins ACCEPTED   = {SEQ_ACCEPTED};
    bins DROP_GAP   = {SEQ_DROP_GAP};
    bins DROP_DUP   = {SEQ_DROP_DUP};
  }
  cp_msg_count: coverpoint msg_count {
    bins single     = {1};
    bins small      = {[2:4]};
    bins medium     = {[5:15]};
    bins large      = {[16:255]};
  }
  cx_seq_x_count: cross cp_seq_state, cp_msg_count;
endgroup
```

Sample: in `lliu_predictor.sv` write task, after `seq_valid`/`drop` signals settle.

### New CoverGroup 2: `symbol_filter_cg`

```systemverilog
covergroup symbol_filter_cg @(posedge clk_300);
  cp_result: coverpoint watchlist_hit {
    bins HIT  = {1};
    bins MISS = {0};
  }
  cp_cam_occupancy: coverpoint active_entries {
    bins empty     = {0};
    bins partial   = {[1:31]};
    bins half_full = {[32:63]};
    bins full      = {64};
  }
  cp_back_to_back: coverpoint back_to_back_count {
    bins single       = {0};
    bins two          = {1};
    bins three_plus   = {[2:$]};
  }
  cx_result_x_occ: cross cp_result, cp_cam_occupancy;
endgroup
```

`active_entries` and `back_to_back_count` are locally tracked variables in the
coverage module, not DUT ports.

### New CoverGroup 3: `drop_on_full_cg`

```systemverilog
covergroup drop_on_full_cg @(posedge clk_156);
  cp_drop_event: coverpoint drop_type {
    bins NO_DROP          = {DROP_NONE};
    bins SINGLE_DROP      = {DROP_SINGLE};
    bins CONSECUTIVE_DROP = {DROP_CONSECUTIVE};
  }
  cp_frame_count: coverpoint frames_since_last_drop {
    bins immediate  = {0};
    bins spaced_1   = {1};
    bins spaced_2p  = {[2:$]};
  }
  cx_drop_x_spacing: cross cp_drop_event, cp_frame_count;
endgroup
```

### Coverage sampling wiring

The three new covergroups sample from monitor transaction fields. Wire them through
`lliu_env.sv`: subscribe to the `axi4_stream_agent` monitor's analysis port and
call `sample()` in an `uvm_subscriber` callback, identical to how the v1 `side_cg`
and `price_range_cg` are currently wired.

### Line coverage targets

| Module | Target | Coverage mechanism |
|--------|--------|--------------------|
| `moldupp64_strip` | 100% | All 5 FSM states entered; both DROP paths; backpressure path |
| `symbol_filter` | 100% | All 64 CAM entries written; hit and miss paths; write-during-lookup |
| `eth_axis_rx_wrap` | 100% | Passthrough, single drop, consecutive drops, counter saturation |
| `kc705_top` (glue only) | 100% | System tests cover all wire assignments; Forencich modules excluded |
| `bfloat16_mul` (updated) | 100% | v1 tests + 1-cycle offset fix already covers full expression tree |
| `dot_product_engine` (updated) | 100% | v1 tests + updated timeout guards |

Forencich third-party modules (`eth_mac_phy_10g`, `ip_complete_64`, `udp_complete_64`,
`axis_async_fifo`) are **excluded** from line coverage targets — they are vendor IP.

---

## Golden Model Interface (DPI-C / shared Python)

The existing DPI-C bridge (`golden_model/dpi_bridge.c`) calls `golden_model.py` via
the Python C-API. **No changes to `dpi_bridge.c` or `golden_model.py` are made by
the `uvm_engineer`.**

For the KC705 path, the same call chain applies:
```
scoreboard observes dp_result_valid
  → calls dpi_bridge predict(stock, price, side, qty, weights)
  → Python golden_model.run_inference(...)
  → returns fp32 result
  → scoreboard compares to dp_result[31:0]
```

The only change is that the scoreboard's trigger condition moves from monitoring
`lliu_top.dp_result_valid` to `kc705_top.dp_result_valid`. This is a `tb_top.sv`
interface binding change (no scoreboard RTL change needed).

---

## New File Summary

| File | Type | Step |
|------|------|------|
| `sequences/moldupp64_seq.sv` | Sequence | 2a |
| `sequences/cam_load_seq.sv` | Sequence | 2b |
| `sequences/kc705_init_seq.sv` | Virtual sequence | 2c |
| `sva/moldupp64_sva.sv` | SVA bind file | 3a |
| `sva/symbol_filter_sva.sv` | SVA bind file | 3b |
| `sva/drop_on_full_sva.sv` | SVA bind file | 3c |
| `tests/lliu_moldupp64_test.sv` | Test | 4a |
| `tests/lliu_symfilter_test.sv` | Test | 4b |
| `tests/lliu_dropfull_test.sv` | Test | 4c |
| `tests/lliu_kc705_test.sv` | System test | 5 |
| `tests/lliu_kc705_perf_test.sv` | Performance test | 6b |
| `perf/kc705_latency_monitor.sv` | Perf monitor | 6a |

**Modified files:**

| File | Change |
|------|--------|
| `sva/dot_product_sva.sv` | Latency bound `VEC_LEN+4` → `VEC_LEN+6` |
| `sva/end_to_end_latency_sva.sv` | Add KC705 18-cycle property; guard v1 property with `ifdef` |
| `env/lliu_coverage.sv` | Add `moldupp64_cg`, `symbol_filter_cg`, `drop_on_full_cg` |
| `tb_top.sv` | Dual-clock support for KC705 TOPLEVEL; SVA bind adds for 3 new modules |

---

## Completion Checklist

| Step | Item | Status |
|------|------|--------|
| 1a | `sva/dot_product_sva.sv` — latency bound +2 cycles | ⬜ |
| 1b | `sva/end_to_end_latency_sva.sv` — KC705 18-cycle property + ifdef guards | ⬜ |
| 2a | `sequences/moldupp64_seq.sv` | ⬜ |
| 2b | `sequences/cam_load_seq.sv` | ⬜ |
| 2c | `sequences/kc705_init_seq.sv` | ⬜ |
| 3a | `sva/moldupp64_sva.sv` — 5 properties | ⬜ |
| 3b | `sva/symbol_filter_sva.sv` — 4 properties | ⬜ |
| 3c | `sva/drop_on_full_sva.sv` — 5 properties | ⬜ |
| 4a | `tests/lliu_moldupp64_test.sv` — 7 scenarios | ⬜ |
| 4b | `tests/lliu_symfilter_test.sv` — 8 scenarios | ⬜ |
| 4c | `tests/lliu_dropfull_test.sv` — 6 scenarios | ⬜ |
| 5  | `tests/lliu_kc705_test.sv` — 9 scenarios | ⬜ |
| 6a | `perf/kc705_latency_monitor.sv` — 4 measurement channels | ⬜ |
| 6b | `tests/lliu_kc705_perf_test.sv` — 6 perf scenarios | ⬜ |
| 7  | `env/lliu_coverage.sv` — 3 new CoverGroups wired | ⬜ |
| 8  | Full regression: zero `uvm_error`, zero SVA violations | ⬜ |
| 8  | 100% line coverage on all 4 new modules | ⬜ |
| 8  | All MAS perf bounds: `kc705_latency_monitor` reports pass | ⬜ |

> All steps depend on the RTL plan (RTL_PLAN_kintex-7.md) completing first.
> Do not begin Step 4 until the corresponding RTL module compiles cleanly.
> Do not begin Step 5/6 until `kc705_top.sv` compiles cleanly.
> Coordinate `(* keep = "true" *)` on internal SVA probe signals with `rtl_engineer`
> before writing Step 3 SVA files.
