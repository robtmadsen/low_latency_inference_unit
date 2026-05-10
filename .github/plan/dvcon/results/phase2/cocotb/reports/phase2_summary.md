# Phase 2 Verification Summary — itch_field_extract (cocotb)

**Date:** 2026-05-10
**DUT:** `rtl/itch_field_extract.sv`
**Simulator:** Verilator 5.046 with cocotb 2.0.1
**Methodology:** cocotb directed tests + Python reference model + scoreboard
**VM:** `vm-cocotb` (Azure Standard_D2s_v5, Ubuntu 22.04)
**Experiment duration:** 1597 s (26.6 min)
**Model:** claude-opus-4-6 (41 turns)
**Cost:** $5.03

## Objective

Autonomous AI agent (claude-opus-4-6) tasked with writing a cocotb testbench
from scratch for `itch_field_extract.sv`, achieving 100% coverage and
documenting all RTL bugs found without human guidance.

## Test Results

| # | Test Name                     | Scenario                                        | Status |
|---|-------------------------------|-------------------------------------------------|--------|
| 1 | test_add_order_buy            | Valid Add Order, buy side (0x42)                | PASS   |
| 2 | test_add_order_sell           | Valid Add Order, sell side (0x53)               | PASS   |
| 3 | test_non_add_order            | Non-Add-Order type (0x46), fields_valid=0       | PASS   |
| 4 | test_sync_reset               | Synchronous reset clears outputs                | PASS   |
| 5 | test_back_to_back             | 3 consecutive Add Orders, no idle cycles        | PASS   |
| 6 | test_msg_valid_deasserted     | msg_valid=0, fields_valid stays 0               | PASS   |
| 7 | test_multiple_non_add_order_types | 6 non-Add-Order types (0x44/55/58/45/43/50) | PASS   |

**Total: 7 tests, 7 passed, 0 failed**

## Coverage

| Metric              | Value        |
|---------------------|--------------|
| Line + branch       | 100% (3/3)   |

Coverage report: `reports/coverage.txt`
Annotated source: `reports/coverage_annotate/itch_field_extract.sv`

## Bugs Found

Two RTL bugs documented in `reports/bugs_found.md`:

### Bug 1 — order_ref byte-index off-by-one (line 54)

The MSB of `order_ref` reads byte 10 (timestamp LSB) instead of byte 11
(order_ref MSB). The concatenation skips byte 11 entirely.

- **Detected by:** test_add_order_buy (confirmed in 10+ additional transactions)
- **Fix:** Change `(B-1-10)` to `(B-1-11)` on line 54

### Bug 2 — fields_valid missing from reset block (lines 92–97)

`fields_valid` is not assigned inside the `if (rst)` block. During
synchronous reset it retains its previous value instead of clearing to 0.

- **Detected by:** test_sync_reset
- **Fix:** Add `fields_valid <= 1'b0;` inside the `if (rst)` block

## Methodology Notes

- Independent Python spec-based reference model (`SpecRefModel`) implements
  ITCH 5.0 field extraction per the specification.
- Dual-track scoreboard: spec model mismatches are logged as bugs; RTL model
  mismatches cause test failure. Tests pass despite RTL bugs by validating
  against actual RTL behavior while separately documenting spec deviations.
- Coverage instrumented via Verilator `--coverage`; branch and toggle metrics
  also captured.

## Telemetry

| File | Description |
|------|-------------|
| `telemetry/run.log` | Outer shell log — attempt timestamps, SUCCESS marker |
| `telemetry/outer.log` | Wrapper stdout/stderr |
| `telemetry/session_cocotb_20260510T145315.json` | Session JSON (duration, cost, usage) |
| `telemetry/summary_cocotb.json` | Final summary snapshot |
| `telemetry/token_curve_cocotb.jsonl` | Per-turn token consumption curve |
