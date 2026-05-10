# Phase 1 Summary — UVM testbench for `itch_field_extract`

## Environment

- DUT: `rtl/itch_field_extract.sv` (depends on `rtl/lliu_pkg.sv`)
- Simulator: Verilator 5.046 with `--timing` (UVM coroutines)
- UVM: Accellera 2020.3.1 source from `$UVM_HOME` compiled with `+define+UVM_NO_DPI`
- Top-level testbench: `tb/tb_top.sv`
- UVM environment: `tb/itch_tb_pkg.sv` (driver, monitor, agent, scoreboard, env, sequences, tests)
- Build/run flow: `tb/Makefile` (`make` to build, `make test` to run all tests + coverage)

## Architecture

- **Driver**: blocking-assignment-at-negedge BFM. Each item is applied to the
  interface signals at `negedge clk` so the next `posedge` sees a clean,
  race-free input.
- **Monitor**: samples both stimulus and registered outputs at every
  `posedge clk + 1` time step (i.e., after the NBA region settles) and
  publishes a single transaction per cycle on its analysis port.
- **Scoreboard**: predicts every output (`message_type`, `order_ref`, `side`,
  `price`, `stock`, `fields_valid`) from the sampled inputs and compares
  against the DUT's actual outputs on every transaction. Reset behaviour
  (all outputs forced to 0) is included in the prediction.
- **Sequences**: `itch_drive_one_seq` (single configurable transaction),
  `itch_idle_seq`, and `itch_reset_seq`. Tests compose these to cover all
  required scenarios.

## Tests run

| Test                     | Scenario covered                                                       | Status |
|--------------------------|------------------------------------------------------------------------|--------|
| `test_buy`               | Single valid Add Order with `'B'` (buy) side                           | PASS   |
| `test_sell`              | Single valid Add Order with `'S'` (sell) side                          | PASS   |
| `test_non_add_order`     | Two non-Add-Order types (`'D'`, `'E'`); `fields_valid` must stay 0     | PASS   |
| `test_reset`             | Valid → assert `rst` for 5 cycles → valid; outputs clear under reset   | PASS   |
| `test_back_to_back`      | Five back-to-back Add Orders with no idle cycles, alternating sides    | PASS   |
| `test_msg_valid_low`     | Valid-shape data on bus but `msg_valid=0`; `fields_valid` must stay 0  | PASS   |

Total: **6/6 tests pass, 0 scoreboard errors across all runs.**

## Coverage

Line coverage of `rtl/itch_field_extract.sv`:

- Lines found: 15
- Lines hit:   15
- **Line coverage: 100.00%**

All branches of the `always_ff` block (reset path and clocked-update path)
are exercised. The full per-line annotation is in `reports/cov_annot/`,
and `reports/coverage.txt` contains the parsed summary.

## Bugs found

None. See `reports/bugs_found.md` for details (including a note on a
Verilator/`--coverage` toggle-instrumentation interaction discovered during
bring-up that is not an RTL bug).

## Exit criteria

- [x] `make -C tb/ test` exits 0 (no test failures)
- [x] `reports/coverage.txt` contains the string "100%"
- [x] `reports/bugs_found.md` exists
- [x] `reports/phase1_summary.md` exists
