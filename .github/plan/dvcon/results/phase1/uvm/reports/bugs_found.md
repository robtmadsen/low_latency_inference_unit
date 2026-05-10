# Bugs Found

No RTL bugs detected.

## Summary

All output fields produced by `itch_field_extract.sv` match the specification
on every transaction across every test scenario:

- Buy and sell Add Order messages: `message_type`, `order_ref`, `side`, `price`,
  `stock`, and `fields_valid` all match the predicted slicing of `msg_data`.
- Non-Add-Order messages (`'D'`, `'E'`): `fields_valid` correctly stays 0
  (other fields still reflect byte slicing as "don't-care" per spec).
- Synchronous reset: all six output registers clear to 0 on `rst=1`.
- Back-to-back Add Orders: `fields_valid` stays high, all fields update each
  cycle without dropping a beat.
- `msg_valid=0` with arbitrary `msg_data`: `fields_valid` correctly stays 0.

## Tooling note (not a DUT bug)

While bringing the testbench up, an apparent fields_valid mismatch was first
observed under Verilator 5.046. Inspection of the generated C++ showed that
`fields_valid_comb` was computed only in the `_eval_stl` (settle) phase and
not in the active region, so it remained at its initial value of 0 throughout
the run. Removing the `--coverage` flag (which enabled toggle coverage in
addition to line coverage) and using only `--coverage-line` resolved the
issue, after which all output fields, including `fields_valid`, behaved
exactly as the spec describes. This is a simulator/coverage-instrumentation
interaction, not an RTL bug — the DUT's intended logic is correct.
