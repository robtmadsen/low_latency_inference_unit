# PR 53: Known / Outstanding UVM Bugs

This note captures verified outstanding issues after the latest UVM pass on branch `feat/uvm-kc705-phase2`.

## Scope

- `moldupp64_strip` block test (`lliu_moldupp64_test`)
- `symbol_filter` block test (`lliu_symfilter_test`)
- `eth_axis_rx_wrap` block test (`lliu_dropfull_test`) status below

## Verified Failures (Cycle-Level)

### 1) `symbol_filter` latency mismatch (assertion in Scenario 2)

- Test: `lliu_symfilter_test`
- First failure point:
  - Scenario 2 starts at `@ 78255 ps`
  - Assertion fires at `@ 95000 ps`
- Assertion: `p_hit_latency` in `tb/uvm/sva/symbol_filter_sva.sv`
- Symptom:
  - `watchlist_hit` does not match expected value one cycle after `stock_valid` rises.
- Interpretation:
  - RTL appears to deliver lookup result one cycle later than the 1-cycle contract expected by SVA/test.
  - Current SVA expects exactly 1-cycle latency.

### 2) `moldupp64_strip` expected sequence stalls at 2 after Scenario 1

- Test: `lliu_moldupp64_test`
- Observed outcomes:
  - Scenario 1 pass: expected sequence advances to `2`
  - Scenario 2 fail at `@ 128205 ps`: expected `18`, got `2`
  - Scenario 5 fail at `@ 937395 ps`: expected `68`, got `2`
  - Scenario 6 fail at `@ 1067265 ps`: expected `73`, got `2`
- Secondary symptom:
  - Drop counter behavior is inconsistent with intended duplicate/gap handling after sequence gets stuck.
- Interpretation:
  - Header beat-2 accept/advance path is not consistently advancing `expected_seq_num` after initial datagram.

## Status: `eth_axis_rx_wrap` (`lliu_dropfull_test`)

- Dedicated compile+run was launched on EC2.
- At the time of this note, no final `RUN_EXIT`/scenario summary was captured in the consolidated log because the previous batch stopped at the symbol-filter assertion abort.
- Action: rerun isolated `lliu_dropfull_test` and append outcomes here once available.

## UVM-Side Fixes Included in This Commit

1. Improved failure observability in `symbol_filter_sva.sv`:
- Assertion messages now print sampled expected/observed values and relevant context (`stock`, `stock_valid`, write index) to reduce speculative RTL edits.

2. Improved failure observability in `lliu_moldupp64_test.sv`:
- `check_expected_seq` now logs `seq_valid`, `seq_num`, `msg_count`, drop counter, and output-valid context on mismatch.

These are diagnostics-only UVM changes to speed targeted RTL debugging.
