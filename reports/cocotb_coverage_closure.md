# Coverage Closure Report — 100% Line Coverage (cocotb)

**Date:** 2026-03-23  
**Simulator:** Verilator 5.046  
**Framework:** cocotb (Python)  
**Scope:** Source-level line coverage (every RTL source line hit ≥1 time)

> **[View interactive HTML coverage report](https://htmlpreview.github.io/?https://github.com/robtmadsen/low_latency_inference_unit/blob/main/reports/cocotb_coverage_html/index.html)**

---

## Result Summary

| Metric | Value |
|--------|-------|
| **Source-level line coverage** | **100.0%** (502/502 lines) |
| RTL modules | 11 files, 1 342 LOC |
| Exclusions | 8 pragmas across 5 files (see below) |

---

## Test Effort

### Test suites

| # | Suite (TOPLEVEL : MODULE) | Tests | Status |
|---|---------------------------|------:|--------|
| 1 | `bfloat16_mul : test_bfloat16_mul` | 2 | PASS |
| 2 | `fp32_acc : test_fp32_acc` | 2 | PASS |
| 3 | `dot_product_engine : test_dot_product_engine` | 3 | PASS |
| 4 | `itch_parser : test_parser` | 4 | PASS |
| 5 | `feature_extractor : test_feature_extractor` | 4 | PASS |
| 6 | `lliu_top : test_smoke` | 2 | PASS |
| 7 | `lliu_top : test_constrained_random` | 2 | PASS |
| 8 | `lliu_top : test_backpressure` | 3 | PASS |
| 9 | `lliu_top : test_latency` | 4 | PASS |
| 10 | `lliu_top : test_error_injection` | 3 | PASS |
| 11 | `lliu_top : test_replay` | 2 | PASS |
| 12 | `itch_parser : test_parser_edge` ★ | 13 | PASS |
| 13 | `feature_extractor : test_feat_edge` ★ | 8 | PASS |
| 14 | `bfloat16_mul : test_bf16_mul_edge` ★ | 12 | PASS |
| 15 | `fp32_acc : test_fp32_acc_edge` ★ | 21 | PASS |
| 16 | `axi4_lite_slave : test_axil_regmap` ★ | 11 | PASS |
| 17 | `lliu_top : test_wgtmem_outbuf` ★ | 7 | PASS |
| 18 | `lliu_top : test_integration_sweep` ★ | 10 | PASS |
| | **Total** | **113** | **all PASS** |

★ = new suite added for coverage closure

### Lines of code

| Category | Files | LOC |
|----------|------:|----:|
| Pre-existing test files (11) | 11 | 2 293 |
| **New coverage-closure test files (7)** | **7** | **2 154** |
| Total test code | 18 | 4 447 |

New test files:
- `test_parser_edge.py` — 429 LOC (13 tests)
- `test_feat_edge.py` — 178 LOC (8 tests)
- `test_bf16_mul_edge.py` — 180 LOC (12 tests)
- `test_fp32_acc_edge.py` — 333 LOC (21 tests)
- `test_axil_regmap.py` — 377 LOC (11 tests)
- `test_wgtmem_outbuf.py` — 276 LOC (7 tests)
- `test_integration_sweep.py` — 381 LOC (10 tests)

### Wall-clock time

| Phase | Time |
|-------|-----:|
| Full `coverage-run` (18 suites, compile + simulate) | **170 s** |
| `coverage-merge` + `coverage-report` | < 1 s |
| **Total** | **~171 s** |

Measured on Apple M-series (MacBook Air), single-threaded Verilator builds.

---

## Per-Module Final Line Coverage

| Module | Coverable Lines | Covered | Coverage |
|--------|----------------:|--------:|---------:|
| axi4_lite_slave.sv | 90 | 90 | 100.0% |
| bfloat16_mul.sv | 37 | 37 | 100.0% |
| dot_product_engine.sv | 44 | 44 | 100.0% |
| feature_extractor.sv | 64 | 64 | 100.0% |
| fp32_acc.sv | 103 | 103 | 100.0% |
| itch_field_extract.sv | 6 | 6 | 100.0% |
| itch_parser.sv | 55 | 55 | 100.0% |
| lliu_top.sv | 73 | 73 | 100.0% |
| output_buffer.sv | 14 | 14 | 100.0% |
| weight_mem.sv | 16 | 16 | 100.0% |
| **Total** | **502** | **502** | **100.0%** |

> `lliu_pkg.sv` defines only parameters and types — no executable lines.

---

## Exclusions (`verilator coverage_off` / `coverage_on`)

8 pragma pairs across 5 RTL files exclude lines that are provably unreachable
or represent tied-constant outputs. No functional logic was excluded.

| File | Lines | What is excluded | Justification |
|------|-------|------------------|---------------|
| `axi4_lite_slave.sv` | 33–35 | `s_axil_bresp` output signal | Tied to `2'b00` (OKAY); never toggled |
| `axi4_lite_slave.sv` | 46–48 | `s_axil_rresp` output signal | Tied to `2'b00` (OKAY); never toggled |
| `dot_product_engine.sv` | 101–105 | FSM `default` branch | Unreachable — all valid states enumerated |
| `feature_extractor.sv` | 52–54 | `int_to_bf16` zero return | Dead code: caller guards `val == 0` before call |
| `itch_parser.sv` | 149–151 | FSM `default` branch | Unreachable — all valid states enumerated |
| `lliu_top.sv` | 39–41 | `s_axil_bresp` pass-through | Driven by `axi4_lite_slave` tied constant |
| `lliu_top.sv` | 50–52 | `s_axil_rresp` pass-through | Driven by `axi4_lite_slave` tied constant |
| `lliu_top.sv` | 189–191 | Sequencer FSM `default` branch | Unreachable — all valid states enumerated |

---

## Reproducing

```bash
cd tb/cocotb
make coverage-clean
make coverage-run       # ~170 s
make coverage-report    # generates coverage_data/annotate/
# Verify: grep -c '%00' coverage_data/annotate/*.sv   (expect all zeros)
```
