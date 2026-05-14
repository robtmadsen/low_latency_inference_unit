# Module Spec: `dot_product_engine`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

Pipelined MAC engine that computes the dot product of a `VEC_LEN`-element bfloat16 feature vector against a bfloat16 weight vector, accumulating in float32. Uses `NUM_ACCS_USED = min(VEC_LEN, 5)` parallel `fp32_acc` instances in a round-robin scheme to eliminate RAW hazards from the 5-stage `fp32_acc` pipeline. A sixth `fp32_acc` instance (`u_merge`) sums the partial accumulator totals during the DRAIN phase.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `VEC_LEN` | `FEATURE_VEC_LEN` (4) | Number of feature/weight elements per inference |

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset (`sys_rst`) |
| `feature_in` | in | `bfloat16_t` | Feature element (one per cycle during STREAM) |
| `feature_valid` | in | 1 | Strobe: `feature_in` and `weight_in` are valid this cycle |
| `weight_in` | in | `bfloat16_t` | Weight element, aligned with `feature_in` |
| `start` | in | 1 | One-cycle pulse to begin a new inference; clears accumulators |
| `result` | out | `float32_t` | Computed dot-product result |
| `result_valid` | out | 1 | Combinational high when FSM is in `S_DONE` (one cycle) |

## FSM

```
         start
           │
    ┌──────▼──────┐
    │   S_IDLE    │  merge_clear pulsed; waiting for start
    └──────┬──────┘
           │ start
    ┌──────▼──────┐
    │  S_STREAM   │  Accept feature_valid/weight_in pairs
    │             │  Stream into bfloat16_mul instances
    │             │  VEC_LEN element cycles + 6 mac-drain cycles
    └──────┬──────┘
           │ (stream_cnt == VEC_LEN + 6 - 1)
    ┌──────▼──────┐
    │   S_DRAIN   │  Merge partial acc totals into u_merge
    │             │  (NUM_ACCS_USED - 1) * 4 + 4 cycles
    └──────┬──────┘
           │ (drain_cnt == DRAIN_EXIT_VAL)
    ┌──────▼──────┐
    │   S_DONE    │  result_valid = 1 (combinational, 1 cycle)
    └──────┬──────┘
           │ (next cycle)
           └──► S_IDLE
```

## Timing Parameters (VEC_LEN = 4)

| Parameter | Value | Formula |
|-----------|-------|---------|
| `NUM_ACCS_USED` | 4 | `min(VEC_LEN, 5)` |
| `MERGE_STEP` | 4 | Fixed |
| `DRAIN_LAST_EN` | 12 | `(NUM_ACCS_USED - 1) * MERGE_STEP` |
| `DRAIN_EXIT_VAL` | 16 | `DRAIN_LAST_EN + MERGE_STEP` |
| STREAM cycles | 10 | `VEC_LEN + 6` (6 cycles for bfloat16_mul + fp32_acc drain) |
| DRAIN cycles | 16 | `DRAIN_EXIT_VAL` |
| **Total from `start` to `result_valid`** | **26** | STREAM + DRAIN |

For `VEC_LEN = 32` (5 accumulators): STREAM = 38, DRAIN = 20 → **58 cycles total**.

## Pipeline Architecture

```
feature_in ──► bfloat16_mul (2-cycle latency) ──► fp32_acc[i % NUM_ACCS]
weight_in  ──►                                     (round-robin, i = element index)
```

- `bfloat16_mul`: 2-cycle pipeline (Stage 1: DSP48E1 multiply; Stage 2: normalize)
- `fp32_acc`: 5-stage pipeline with back-to-back forwarding mux
- Consecutive products for the same accumulator are `VEC_LEN / NUM_ACCS` ≥ 1 cycles apart. For `VEC_LEN = 4, NUM = 4`, each accumulator receives exactly 1 element — no RAW hazard.

## Round-Robin Assignment

Element index `i` → accumulator `i % NUM_ACCS_USED`.

During STREAM, `bfloat16_mul` products arrive 2 cycles after `feature_valid`. The `acc_sel` index (delayed by 2) selects which `fp32_acc` to enable.

## DRAIN Phase

After all elements have been streamed and the `bfloat16_mul` + `fp32_acc` pipeline has drained (6 extra cycles in STREAM state), the partial sums in `fp32_acc[0..NUM-1]` are merged into `u_merge` one at a time, 4 cycles apart (matching `fp32_acc` pipeline depth with the forwarding mux):

```
drain_cnt =  0: merge_en, u_merge ← u_merge + acc[0].acc_out
drain_cnt =  4: merge_en, u_merge ← u_merge + acc[1].acc_out
drain_cnt =  8: merge_en, u_merge ← u_merge + acc[2].acc_out
drain_cnt = 12: merge_en, u_merge ← u_merge + acc[3].acc_out   (NUM=4)
drain_cnt = 16: transition to S_DONE
```

`u_merge` is cleared in `S_IDLE` (via `merge_clear`), ensuring each inference starts from zero.

## Accumulator Clear

`start` pulse clears all `NUM_ACCS_USED` accumulators (`acc_clear` asserted for 1 cycle). `u_merge` is cleared by `merge_clear` which is combinationally asserted during `S_IDLE`.

## Result

`result` = `u_merge.acc_out` (the final merged float32 dot-product). `result_valid` is **combinational** (`state == S_DONE`) and is high for exactly **one clock cycle**. On the next posedge the FSM returns to `S_IDLE`.

## Design Notes

- The 5-accumulator round-robin design replaced an earlier single-accumulator design that required a 7-cycle stall between consecutive elements.
- `feature_valid` is required to be asserted every cycle during the feed phase (no gaps). The inference sequencer in `lliu_top` guarantees this.
- `result_valid` being combinational (not registered) means `output_buffer` must sample it on the same clock edge. `output_buffer` uses `result_valid` as a register enable.
