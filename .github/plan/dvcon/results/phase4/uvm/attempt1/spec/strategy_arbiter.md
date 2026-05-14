# `strategy_arbiter` — 3-Level Tournament Tree

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Selects the highest-scoring active inference core from up to 8 `lliu_core` instances using a fully-combinational 3-level tournament tree. Applies a configurable score threshold (`score_thresh`) to gate out below-threshold cores before the tournament, preventing low-confidence orders from reaching `risk_check`.

## Ports

### Core Result Inputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `result_ready` | in | 8 | Bit-vector: core `i` result is stable when bit `i` is high |
| `core_scores` | in | `8×32` | IEEE 754 fp32 scores from 8 cores |
| `core_sides` | in | `8×8` | Buy/Sell ASCII from 8 cores |

### Configuration

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `score_thresh` | in | 32 | Minimum fp32 score to enter tournament; written via AXI4-Lite 0x044 |

### Outputs (registered, 1-cycle latency)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `best_score` | out | 32 | Winning core's fp32 score |
| `best_core_id` | out | 3 | Winning core index (0–7) |
| `best_valid` | out | 1 | High if at least one core beat the threshold |
| `best_side` | out | 8 | Winning core's side ('B' or 'S') |

## Tournament Architecture

### Pre-gating

For each core `i`:
```
masked_score[i] = (result_ready[i] & (core_scores[i] > score_thresh)) ? core_scores[i] : 32'h0
```
A zero score (positive IEEE 754 zero) never wins unless all competitors are also zero and no valid core exists.

### Comparison method

IEEE 754 positive floating-point numbers maintain total order when interpreted as unsigned 32-bit integers (sign bit = 0, larger magnitude = larger unsigned value). The tournament tree therefore uses unsigned 32-bit `>` comparisons, avoiding any FP comparator logic.

### Tree levels

```
Level 0 (4 comparators):  pairs (0,1), (2,3), (4,5), (6,7) → 4 winners
Level 1 (2 comparators):  pairs (w01, w23), (w45, w67)     → 2 winners
Level 2 (1 comparator):   final pair                         → champion
```

Each comparator preserves the winning core's `core_id`, `score`, and `side`.

### Output register

All outputs are flopped once after the combinational tree:
```
best_score   ← champion.score
best_core_id ← champion.id
best_side    ← core_sides[champion.id]
best_valid   ← champion.score != 0
```
The 1-cycle registered output is the only pipeline stage; the module contributes 1 cycle to the latency budget.

## Timing

- Combinational delay: 3 cascaded 32-bit unsigned comparators (≈ 1.5 ns at 312.5 MHz).
- Registered output: 1-cycle latency to `best_valid`.
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.

## Design Notes

- The arbiter does not arbitrate across multiple simultaneous new results; `pipeline_hold` in `lliu_top_v2` guarantees all 8 cores complete the same inference round before the next features arrive.
- `best_valid` feeds `risk_check.trigger`; if no core beats the threshold, the pipeline silently discards the event.
