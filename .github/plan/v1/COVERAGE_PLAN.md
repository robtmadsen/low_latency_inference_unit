# Coverage Plan

Close DUT line coverage to 100% using both cocotb and UVM, then compare the effort, simulation time, and lines of code each methodology required to reach the same goal. Toggle and branch coverage are deferred to a future stage.

> **Predecessor:** [MASTER_PLAN.md](MASTER_PLAN.md) (all 30 steps complete)
>
> **Architecture:** [SPEC.md](../arch/SPEC.md) · [RTL_ARCH.md](../arch/RTL_ARCH.md) · [COCOTB_ARCH.md](../arch/COCOTB_ARCH.md) · [UVM_ARCH.md](../arch/UVM_ARCH.md)

---

## Stage 1: Baseline Coverage Collection (No New Tests)

Run the existing test suites under coverage instrumentation to establish a starting point. No new stimulus — this stage only measures what the current tests already cover.

| # | Commit | Description |
|---|--------|-------------|
| 1 | `cov: enable Verilator --coverage for cocotb flow` | Add `--coverage` (line + toggle + branch) to the cocotb Makefile. Run the full existing test suite. Merge coverage data into a single `coverage.dat`. Generate an HTML report with `verilator_coverage --annotate`. |
| 2 | `cov: enable Verilator --coverage for UVM flow` | Add `--coverage` to the UVM Makefile. Run all existing UVM tests (smoke, replay, random, stress, error, latency). Merge results. Generate an HTML report. |
| 3 | `cov: baseline coverage report + gap analysis` | Write a script (`scripts/coverage_report.py`) that parses both Verilator coverage databases and produces a unified Markdown report. Identify uncovered lines, untoggled signals, and missed branches per RTL module. Commit the baseline report as `reports/coverage_baseline.md`. |

**Checkpoint:** Baseline numbers established for line, toggle, and branch coverage — per module and overall — for both cocotb and UVM. Coverage gaps are documented.

---

## Stage 2: Close Line Coverage with cocotb

Write targeted cocotb tests to fill every gap identified in the baseline. Track lines of new test code and cumulative simulation time.

| # | Commit | Description |
|---|--------|-------------|
| 4 | `cov: cocotb — ITCH parser edge-case tests` | Target gaps in itch_parser.sv and itch_field_extract.sv. Test minimum-length and maximum-length messages, back-to-back messages with no idle cycles, single-beat vs multi-beat transfers, message types other than Add Order (should be dropped), and partial-message abort via tuser error flag. |
| 5 | `cov: cocotb — feature extractor + dot-product engine tests` | Target gaps in feature_extractor.sv and dot_product_engine.sv. Exercise zero-price input, maximum-price input, subnormal bfloat16 features, all-zero weight vector, alternating positive/negative weights, accumulator overflow/underflow corner cases. |
| 6 | `cov: cocotb — AXI4-Lite register map tests` | Target gaps in axi4_lite_slave.sv. Read/write every register address. Write while inference is active, read status during each FSM state, access unmapped addresses, back-to-back writes with no gap. |
| 7 | `cov: cocotb — weight memory + output buffer tests` | Target gaps in weight_mem.sv and output_buffer.sv. Load weights at boundary addresses (0, max), simultaneous read/write to same address, toggle all data bits, output buffer back-pressure holding result. |
| 8 | `cov: cocotb — lliu_top integration coverage sweep` | System-level directed tests targeting any remaining top-level coverage holes: pipeline stall/resume, back-to-back inferences with no idle, weight reload between inferences, reset mid-inference. |
| 9 | `cov: cocotb — final coverage merge + report` | Merge all coverage from steps 4–8 with the baseline. Generate final cocotb coverage report. Record total simulation time (wall-clock + sim cycles) and count new lines of test code added. |

**Checkpoint:** cocotb line coverage is closed — 100% line coverage (502/502 reachable lines). See `reports/cocotb_coverage_closure.md`.

---

## Stage 3: Close Line Coverage with UVM

Use a hybrid constrained-random + directed approach in a single `lliu_coverage_test` to close all remaining line coverage gaps. The constrained-random loop randomizes weight values (sign, mantissa, exponent) to exercise arithmetic datapath corners, while directed sequences target protocol edges that random stimulus cannot reach.

| # | Commit | Description |
|---|--------|-------------|
| 10–14 | `cov: UVM — hybrid CR + directed coverage test` | Single `lliu_coverage_test` with Phase 1 (128-iteration constrained-random weight loop, 5 constraint categories, 4 ITCH orders per iteration) and Phase 2 (directed `itch_edge_seq` + `regmap_edge_seq` for parser truncation, non-Add-Order, back-to-back, CTRL register, unmapped addresses). Added 5 new coverage pragmas for declaration artifacts, unreachable underflow, exact cancellation, and deep renormalization chain. |
| 15 | `cov: UVM — final coverage merge + report` | Merge all 6 UVM tests. Generate final UVM coverage report. 446/446 coverable lines covered (100%). See `reports/uvm_coverage_closure.md`. |

**Checkpoint:** UVM line coverage is closed — 100% line coverage (449/449 reachable lines). See `reports/uvm_coverage_closure.md`.

---

## Stage 4: Cross-Methodology Comparison

With both frameworks at coverage closure, compare the cost of getting there.

| # | Commit | Description |
|---|--------|-------------|
| 16 | `cov: comparison — collect metrics` | For each framework, record: (a) new test LOC added (steps 4–9 vs 10–15), (b) total wall-clock simulation time for the full regression, (c) total simulation cycles, (d) number of test cases / sequences. |
| 17 | `cov: comparison — final report` | Generate `reports/coverage_comparison.md` with side-by-side tables and analysis. Sections: executive summary, line/toggle/branch coverage by module, LOC comparison, simulation time comparison, qualitative observations (ease of debug, iteration speed, expressiveness). Update README.md with findings. |

**Checkpoint:** Full cross-methodology coverage comparison is documented. Project coverage closure is complete.

---

## Progress Tracker

```
Stage 1: Baseline Coverage Collection
  [x] #1  Enable Verilator --coverage for cocotb
  [x] #2  Enable Verilator --coverage for UVM
  [x] #3  Baseline report + gap analysis

Stage 2: Close Line Coverage with cocotb
  [x] #4  cocotb — ITCH parser edge-case tests
  [x] #5  cocotb — feature extractor + dot-product tests
  [x] #6  cocotb — AXI4-Lite register map tests
  [x] #7  cocotb — weight memory + output buffer tests
  [x] #8  cocotb — lliu_top integration sweep
  [x] #9  cocotb — final coverage merge + report

Stage 3: Close Line Coverage with UVM
  [x] #10–14  UVM — hybrid constrained-random + directed coverage test
              (single lliu_coverage_test replaces steps 10–14;
               CR loop for arithmetic paths, directed seqs for protocol edges)
  [x] #15 UVM — final coverage merge + report

Stage 4: Cross-Methodology Comparison
  [ ] #16 Collect metrics
  [ ] #17 Final comparison report
```
