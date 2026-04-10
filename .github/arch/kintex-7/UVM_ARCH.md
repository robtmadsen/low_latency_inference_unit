# UVM Testbench Architecture — LLIU v2.0 (Kintex-7)

> **Status:** Phase 1 complete (PR #41 on `main`, April 2026)
> **Simulator:** Verilator 5.046 (must run on EC2 instance `lliu-par`)
> **UVM standard:** IEEE 1800.2-2020 (`uvm-core` from Accellera)
> **Spec reference:** [2p0_kintex-7_MAS.md](2p0_kintex-7_MAS.md)
> **Testbench root:** `tb/uvm/`

---

## 1. Prerequisites

All UVM compiles and test runs execute on the EC2 instance `lliu-par`.
See `.github/skills/run_uvm_test_suite/SKILL.md` for bootstrap and SSH instructions.

```bash
ssh lliu-par
cd ~/low_latency_inference_unit
export UVM_HOME=~/uvm-reference/src
```

---

## 2. Directory Structure

```
tb/uvm/
├── tb_top.sv                     ← DUT + interfaces + UVM launch + SVA binds
├── axi4_stream_if.sv             ← AXI4-Stream virtual interface
├── axi4_lite_if.sv               ← AXI4-Lite virtual interface
├── kc705_ctrl_if.sv              ← KC705 ctrl signals interface (v1 compat)
├── order_book_if.sv              ← order_book DUT interface (Phase 1)
├── agents/
│   ├── axi4_stream_agent/        ← AXI4-S driver, monitor, seq_item, agent, pkg
│   ├── axi4_lite_agent/          ← AXI4-Lite driver, monitor, seq_item, agent, pkg
│   └── order_book_agent/         ← Phase 1: direct order-book drive agent
│       ├── order_book_agent.sv
│       ├── order_book_agent_pkg.sv
│       ├── order_book_driver.sv
│       ├── order_book_monitor.sv
│       └── order_book_seq_item.sv
├── env/                          ← lliu_env, predictor, scoreboard, coverage (v1)
├── sequences/
│   ├── lliu_seq_pkg.sv           ← package imports (updated to include Phase 1)
│   ├── order_book_stress_seq.sv  ← Phase 1: constrained-random ITCH fuzz
│   └── [v1 sequences]
├── tests/
│   ├── lliu_test_pkg.sv          ← test class registry
│   ├── lliu_order_book_test.sv   ← Phase 1: standalone order book stress
│   └── [v1 tests]
├── sva/                          ← 6 SVA bind modules (v1)
├── perf/                         ← lliu_latency_monitor.sv (v1)
└── golden_model/
    └── golden_model.py → ../../cocotb/models/golden_model.py  (symlink, DPI-C)
```

---

## 3. Test Inventory

### 3.1 v1 Tests (TOPLEVEL = `lliu_top`, retained)

| Test class | Description |
|------------|-------------|
| `lliu_base_test` | Base class; used as sanity + no-crash check |
| `lliu_smoke_test` | Single inference, weight load, result compare |
| `lliu_replay_test` | ITCH replay from `data/tvagg_sample.bin` |
| `lliu_random_test` | 500 random Add Orders, constrained-random weights |
| `lliu_stress_test` | Back-to-back messages, max IFG=0 |
| `lliu_error_test` | Truncated / malformed ITCH with recovery checks |
| `lliu_coverage_test` | Constrained-random sweep targeting functional coverage bins |

Run command (on EC2):
```bash
export UVM_HOME=~/uvm-reference/src
python3 scripts/run_uvm_regression.py
```

---

### 3.2 Phase 1 v2.0 Test (TOPLEVEL = `order_book`)

#### `lliu_order_book_test`

> **TOPLEVEL:** `order_book` (selected via `+define+TOPLEVEL_ORDER_BOOK` or by setting
> `TOPLEVEL=order_book` in the UVM Makefile; see `tb_top.sv` `ifdef` blocks)

| Element | Detail |
|---------|--------|
| **Test class** | `lliu_order_book_test` |
| **Agent** | `order_book_agent` (active mode) — standalone, no `lliu_env` wrapper |
| **Sequence** | `order_book_stress_seq` (1,000 ops per regression run) |
| **Pass criteria** | No `UVM_ERROR` / `UVM_FATAL`; simulation completes without timeout; `collision_count` readable |

`lliu_order_book_test` is registered in `EXTRA_TOPLEVEL_TESTS` in `scripts/run_uvm_regression.py`
and runs as a separate TOPLEVEL compilation after the main `lliu_top` suite.

---

## 4. Phase 1 New Components

### 4.1 `order_book_if.sv`

SystemVerilog interface wrapping all `order_book` module ports.

| Port group | Signals |
|------------|---------|
| ITCH input bus | `msg_type[7:0]`, `order_ref[63:0]`, `new_order_ref[63:0]`, `price[31:0]`, `shares[31:0]`, `side`, `sym_id[8:0]`, `fields_valid` |
| BBO query | `bbo_query_sym[8:0]`, `bbo_bid_price[31:0]`, `bbo_ask_price[31:0]`, `bbo_bid_size[23:0]`, `bbo_ask_size[23:0]` |
| BBO update | `bbo_valid`, `bbo_sym_id[8:0]` |
| Telemetry | `collision_count[31:0]`, `collision_flag`, `book_ready` |
| Clock / reset | `clk`, `rst` |

Virtual interface key: `"ob_vif"` — set in `tb_top.sv`:
```systemverilog
uvm_config_db#(virtual order_book_if)::set(null, "uvm_test_top*", "ob_vif", ob_if);
```

---

### 4.2 `order_book_agent`

Standard UVM agent with active/passive mode support.

| Component | Role |
|-----------|------|
| `order_book_seq_item` | Transaction: `msg_type`, `order_ref`, `new_order_ref`, `price`, `shares[23:0]`, `side`, `sym_id[8:0]` |
| `order_book_driver` | Drives `fields_valid` pulse + all input fields each transaction; waits for `book_ready` between ops |
| `order_book_monitor` | Samples `bbo_valid`, `bbo_sym_id`, `bbo_bid_price`, `bbo_ask_price`, `collision_flag`; broadcasts via analysis port |
| `order_book_agent` | Active: driver + sequencer + monitor; passive: monitor only |

---

### 4.3 `order_book_stress_seq`

Constrained-random fuzz sequence. Runs `num_ops` (default 1,000) operations.

**Mix ratios (approximate):**

| Op type | Approx % | Notes |
|---------|----------|-------|
| Add Order (`'A'`) | 50% (or 100% when queue empty) | Also covers boundary prices near 0, mid-range, near-max |
| Delete (`'D'`) | 20% | Targets `active_refs` queue |
| Cancel (`'X'`) | 15% | Partial cancel |
| Replace (`'U'`) | 10% | Atomic cancel + re-add |
| Execute (`'E'`) | 5% | Trade execution |

**Boundary stimulus:**
- `price`: 1, ~500,000, ~999,999 (near-0, mid, near-max)
- `shares`: 1, 9,001, 2²⁴−1 (min, large, max)
- `sym_id`: 0, 1, 498, 499 and random interior

Active order refs are tracked in a `longint unsigned` queue so modify ops always target existing orders. New refs start at `0x1000_0000` and increment monotonically.

---

## 5. `lliu_seq_pkg.sv` Update

`order_book_stress_seq` is included in `lliu_seq_pkg.sv`:
```systemverilog
`include "sequences/order_book_stress_seq.sv"
```

---

## 6. `tb_top.sv` Phase 1 Changes

- Added `order_book_if ob_if(clk, rst)` instantiation inside `ifdef TOPLEVEL_ORDER_BOOK` guard
- `order_book` DUT instantiated with all ports connected to `ob_if`
- `uvm_config_db` set for `"ob_vif"` virtual interface
- Compile guard keeps original `lliu_top` DUT and v1 interfaces unchanged when
  `TOPLEVEL_ORDER_BOOK` is not defined

---

## 7. Regression Flow

```bash
# On EC2 — run full suite (v1 + Phase 1)
export UVM_HOME=~/uvm-reference/src
python3 scripts/run_uvm_regression.py

# Output: reports/uvm_results.xml
```

`run_uvm_regression.py` structure:
1. Runs `ALL_TESTS` (v1, 7 tests) with `TOPLEVEL=lliu_top`
2. Runs `EXTRA_TOPLEVEL_TESTS` → `("order_book", ["lliu_order_book_test"])`
3. Merges pass/fail into `reports/uvm_results.xml` with `<summary>` element

**Total tests registered: 8** (7 v1 + 1 Phase 1)

---

## 8. Phase 2 Additions (planned)

| Component | Description |
|-----------|-------------|
| `risk_fuzz_seq` | Randomize price/qty across price-band, fat-finger, position-limit boundaries; verify 100% block rate on OOB inputs (MAS §4.6, §7) |
| `ouch_checker` | Parse generated OUCH 5.0 packets; verify field values and byte layout against NASDAQ OUCH 5.0 spec |
| `tx_backpressure_seq` | Deassert `tx_axis_tready` > 64 consecutive cycles; verify kill switch asserts and self-clears (MAS §4.7) |
| `risk_check_agent` | Interface + driver for `risk_check` module (separate TOPLEVEL or integrated into `lliu_top_v2`) |

See [2p0_kintex-7_MAS.md §7](2p0_kintex-7_MAS.md) for full verification strategy.
