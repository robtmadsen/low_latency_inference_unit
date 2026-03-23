# Coverage Plan

Close DUT structural coverage (line, toggle, branch) to 100% using both cocotb and UVM, then compare the effort, simulation time, and lines of code each methodology required to reach the same goal.

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

## Stage 2: Close Coverage with cocotb

Write targeted cocotb tests to fill every gap identified in the baseline. Track lines of new test code and cumulative simulation time.

| # | Commit | Description |
|---|--------|-------------|
| 4 | `cov: cocotb — ITCH parser edge-case tests` | Target gaps in itch_parser.sv and itch_field_extract.sv. Test minimum-length and maximum-length messages, back-to-back messages with no idle cycles, single-beat vs multi-beat transfers, message types other than Add Order (should be dropped), and partial-message abort via tuser error flag. |
| 5 | `cov: cocotb — feature extractor + dot-product engine tests` | Target gaps in feature_extractor.sv and dot_product_engine.sv. Exercise zero-price input, maximum-price input, subnormal bfloat16 features, all-zero weight vector, alternating positive/negative weights, accumulator overflow/underflow corner cases. |
| 6 | `cov: cocotb — AXI4-Lite register map tests` | Target gaps in axi4_lite_slave.sv. Read/write every register address. Write while inference is active, read status during each FSM state, access unmapped addresses, back-to-back writes with no gap. |
| 7 | `cov: cocotb — weight memory + output buffer tests` | Target gaps in weight_mem.sv and output_buffer.sv. Load weights at boundary addresses (0, max), simultaneous read/write to same address, toggle all data bits, output buffer back-pressure holding result. |
| 8 | `cov: cocotb — lliu_top integration coverage sweep` | System-level directed tests targeting any remaining top-level coverage holes: pipeline stall/resume, back-to-back inferences with no idle, weight reload between inferences, reset mid-inference. |
| 9 | `cov: cocotb — final coverage merge + report` | Merge all coverage from steps 4–8 with the baseline. Generate final cocotb coverage report. Record total simulation time (wall-clock + sim cycles) and count new lines of test code added. |

**Checkpoint:** cocotb structural coverage is closed — 100% line, 100% toggle, 100% branch.

---

## Stage 3: Close Coverage with UVM

Write the equivalent targeted UVM tests and sequences. Track the same metrics for comparison.

| # | Commit | Description |
|---|--------|-------------|
| 10 | `cov: UVM — ITCH parser edge-case sequences` | Create `itch_edge_seq` targeting the same parser gaps as cocotb step 4. Min/max length messages, back-to-back, invalid message types, partial-abort. |
| 11 | `cov: UVM — feature extractor + dot-product sequences` | Create `arith_edge_seq` for zero price, max price, subnormal features, all-zero weights, overflow/underflow accumulator paths. |
| 12 | `cov: UVM — AXI4-Lite register map sequences` | Create `regmap_seq` exercising every register address, concurrent access during inference, unmapped addresses, back-to-back writes. |
| 13 | `cov: UVM — weight memory + output buffer sequences` | Create `mem_buf_seq` for boundary addresses, simultaneous read/write, full data-bit toggle, output back-pressure. |
| 14 | `cov: UVM — lliu_top integration coverage sweep` | System-level test combining all new sequences: pipeline stall/resume, back-to-back inferences, weight reload, reset mid-inference. |
| 15 | `cov: UVM — final coverage merge + report` | Merge all coverage from steps 10–14 with the baseline. Generate final UVM coverage report. Record total simulation time and new lines of test code. |

**Checkpoint:** UVM structural coverage is closed — 100% line, 100% toggle, 100% branch. Both frameworks have reached equivalent coverage.

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

Stage 2: Close Coverage with cocotb
  [ ] #4  cocotb — ITCH parser edge-case tests
  [ ] #5  cocotb — feature extractor + dot-product tests
  [ ] #6  cocotb — AXI4-Lite register map tests
  [ ] #7  cocotb — weight memory + output buffer tests
  [ ] #8  cocotb — lliu_top integration sweep
  [ ] #9  cocotb — final coverage merge + report

Stage 3: Close Coverage with UVM
  [ ] #10 UVM — ITCH parser edge-case sequences
  [ ] #11 UVM — feature extractor + dot-product sequences
  [ ] #12 UVM — AXI4-Lite register map sequences
  [ ] #13 UVM — weight memory + output buffer sequences
  [ ] #14 UVM — lliu_top integration sweep
  [ ] #15 UVM — final coverage merge + report

Stage 4: Cross-Methodology Comparison
  [ ] #16 Collect metrics
  [ ] #17 Final comparison report
```
