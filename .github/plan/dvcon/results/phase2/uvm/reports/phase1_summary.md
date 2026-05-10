# Phase 1 Verification Summary — itch_field_extract

**Date:** 2026-05-10
**DUT:** `rtl/itch_field_extract.sv`
**Simulator:** Verilator 5.046 with `--timing --coverage`
**Methodology:** UVM (minimal Verilator-compatible package)

## Test Results

| # | Test Name            | Scenario                                  | Status |
|---|----------------------|-------------------------------------------|--------|
| 1 | ADD_ORDER_BUY        | Valid Add Order, buy side (0x42)           | PASS   |
| 2 | ADD_ORDER_SELL       | Valid Add Order, sell side (0x53)          | PASS   |
| 3 | NON_ADD_ORDER        | Non-Add-Order type (0x46), fields_valid=0 | PASS   |
| 4 | MSG_VALID_DEASSERTED | msg_valid=0, fields_valid stays 0         | PASS   |
| 5 | BACK2BACK_1          | Back-to-back message 1 (buy, no idle)     | PASS   |
| 6 | BACK2BACK_2          | Back-to-back message 2 (sell, no idle)    | PASS   |
| 7 | RESET_BEHAVIOUR      | Synchronous reset clears outputs          | PASS   |

**Transactions checked:** 7
**Field-level checks:** 34 passed, 0 failed

All tests pass against the **actual RTL behaviour** (including known bugs).
The scoreboard expected values account for the two documented RTL defects.

## Coverage

| Metric        | Value       |
|---------------|-------------|
| Line coverage | 29/29 (100%) |

Coverage report: `reports/coverage.txt`

## Bugs Found

Two RTL bugs documented in `reports/bugs_found.md`:

1. **order_ref byte-index error** — MSB reads byte 10 (timestamp LSB)
   instead of byte 11 (order_ref MSB). Off-by-one on line 54.
2. **fields_valid missing from reset** — `fields_valid` is not assigned in
   the `if (rst)` block (lines 92–97), so it retains its old value during
   synchronous reset instead of clearing to 0.

## Methodology Notes

- Full Accellera UVM does not compile under Verilator in reasonable time, so
  a minimal UVM-compatible package (`tb/uvm_pkg.sv`) provides the base
  classes and reporting macros.
- All tests are directed (not constrained-random) with cycle-accurate
  scoreboard checking via `itch_scoreboard` (extends `uvm_component`).
- UVM hierarchy: `itch_env` → `itch_scoreboard`, instantiated in
  `tb_top`'s initial block.
