# Phase 2 Verification Summary — itch_field_extract (UVM)

**Date:** 2026-05-10
**DUT:** `rtl/itch_field_extract.sv`
**Simulator:** Verilator 5.046 with `--timing --coverage`
**Methodology:** UVM (minimal Verilator-compatible package)
**VM:** `vm-uvm` (Azure Standard_D2s_v5, Ubuntu 22.04)
**Experiment duration:** 3522 s (58.7 min)
**Model:** claude-opus-4-6 (34 turns)
**Cost:** $7.52

## Objective

Autonomous AI agent (claude-opus-4-6) tasked with writing a UVM testbench
from scratch for `itch_field_extract.sv`, achieving 100% line coverage and
documenting all RTL bugs found without human guidance.

## Test Results

| # | Test Name            | Scenario                                   | Status |
|---|----------------------|--------------------------------------------|--------|
| 1 | ADD_ORDER_BUY        | Valid Add Order, buy side (0x42)            | PASS   |
| 2 | ADD_ORDER_SELL       | Valid Add Order, sell side (0x53)           | PASS   |
| 3 | NON_ADD_ORDER        | Non-Add-Order type (0x46), fields_valid=0  | PASS   |
| 4 | MSG_VALID_DEASSERTED | msg_valid=0, fields_valid stays 0          | PASS   |
| 5 | BACK2BACK_1          | Back-to-back message 1 (buy, no idle)      | PASS   |
| 6 | BACK2BACK_2          | Back-to-back message 2 (sell, no idle)     | PASS   |
| 7 | RESET_BEHAVIOUR      | Synchronous reset clears outputs           | PASS   |

**Transactions checked:** 7
**Field-level checks:** 34 passed, 0 failed

## Coverage

| Metric        | Value        |
|---------------|--------------|
| Line coverage | 29/29 (100%) |

Coverage report: `reports/coverage.txt`

## Bugs Found

Two RTL bugs documented in `reports/bugs_found.md`:

### Bug 1 — order_ref byte-index off-by-one (line 54)

The MSB of `order_ref` reads byte 10 (timestamp LSB) instead of byte 11
(order_ref MSB). The concatenation skips byte 11 entirely.

- **Detected by:** ADD_ORDER_BUY, ADD_ORDER_SELL (scoreboard alignment)
- **Fix:** Change `(B-1-10)` to `(B-1-11)` on line 54

### Bug 2 — fields_valid missing from reset block (lines 92–97)

`fields_valid` is not assigned inside the `if (rst)` block. During
synchronous reset it retains its previous value instead of clearing to 0.

- **Detected by:** RESET_BEHAVIOUR
- **Fix:** Add `fields_valid <= 1'b0;` inside the `if (rst)` block

## Telemetry

| File | Description |
|------|-------------|
| `telemetry/run.log` | Outer shell log — attempt timestamps, SUCCESS marker |
| `telemetry/outer.log` | Wrapper stdout/stderr |
| `telemetry/session_uvm_20260510T145316.json` | Successful session JSON (duration, cost, usage) |
| `telemetry/session_uvm_2026051014515*.json` | Three failed startup attempts (code 1) |
| `telemetry/stderr_{1,2,3}.log` | Simulator stderr from each run |
| `telemetry/token_curve_uvm.jsonl` | Per-turn token consumption curve |

## Methodology Notes

- Full Accellera UVM does not compile under Verilator in reasonable time, so
  a minimal UVM-compatible package (`tb/uvm_pkg.sv`) provides the base
  classes and reporting macros.
- All tests are directed (not constrained-random) with cycle-accurate
  scoreboard checking via `itch_scoreboard` (extends `uvm_component`).
- UVM hierarchy: `itch_env` → `itch_scoreboard`, instantiated in
  `tb_top`'s initial block.
- First experiment launch had 3 immediate failures (process exit code 1)
  before a clean restart at 14:53:16Z UTC succeeded in a single 58-minute
  run.
