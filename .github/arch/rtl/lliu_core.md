# `lliu_core` — Single Inference Core

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md) ×8

## Purpose

Executes one dot-product-based inference pass over a 32-element bfloat16 feature vector using a stored weight vector (bfloat16 inputs × bfloat16 weights → fp32 accumulate). Eight instances operate in lockstep under the same feature vector; each holds its own distinct weight set, producing independent scores for the `strategy_arbiter`.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `VEC_LEN` | 32 | Feature vector length (must match `dot_product_engine` DEPTH) |
| `HIDDEN` | 32 | Number of weights (must equal VEC_LEN for single-layer model) |

## Ports

### Feature Vector Input

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `features_valid` | in | 1 | One-cycle pulse: begin new inference |
| `features` | in | `32×16` | Bfloat16 feature vector |

### Weight Write Port (AXI4-Lite, from `lliu_top_v2`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `wgt_wr_en` | in | 1 | Write enable |
| `wgt_wr_addr` | in | 6 | Weight address (0–31) |
| `wgt_wr_data` | in | 16 | Bfloat16 weight value |

### Result Outputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `result_valid` | out | 1 | One-cycle pulse when inference is done |
| `result` | out | 32 | Raw fp32 dot-product result |
| `result_out` | out | 32 | Stable registered result (held until next inference) |
| `result_ready` | out | 1 | Stable high after `result_valid`; cleared on next `features_valid` |

## Submodule Instances

| Instance | Module | Role |
|----------|--------|------|
| `u_wmem` | `weight_mem` | 32-entry bfloat16 LUTRAM weight store |
| `u_dp` | `dot_product_engine` | Sequential bfloat16 multiply / fp32 accumulate |
| `u_obuf` | `output_buffer` | Result register and ready flag |

## FSM

Four states:

| State | Description |
|-------|-------------|
| `SEQ_IDLE` | Waiting for `features_valid` |
| `SEQ_PRELOAD` | 1-cycle weight-read warm-up (pipeline fill) |
| `SEQ_FEED` | Streams `VEC_LEN` feature/weight pairs to `dot_product_engine` over 32 cycles |
| `SEQ_WAIT` | Waits for `dot_product_engine` accumulator to flush (6 cycles) |

### Transitions

```
SEQ_IDLE → SEQ_PRELOAD  : features_valid
SEQ_PRELOAD → SEQ_FEED  : always (1 cycle)
SEQ_FEED → SEQ_WAIT     : feed_cnt == VEC_LEN-1
SEQ_WAIT → SEQ_IDLE     : acc_done (from dot_product_engine)
```

## Latency Breakdown

| Phase | Cycles | Description |
|-------|--------|-------------|
| Preload | 1 | First weight read issues |
| Feed | 32 | VEC_LEN feature/weight pairs |
| Flush | 6 | `dot_product_engine` pipeline drain |
| Output register | 1 | `output_buffer` captures result |
| **Total** | **~40** | From `features_valid` to `result_valid` |

Combined with the 4-cycle `feature_extractor_v2` latency, total latency from parser `fields_valid` to `result_valid` is ~44 cycles.

## Design Notes

- All 8 instances share the same `features` bus and `features_valid` signal. Each instance uses independent `u_wmem` and `u_dp` resources.
- Weight writes (`wgt_wr_*`) are decoded per-core in `lliu_top_v2` from the AXI4-Lite address space (`addr[9:7]` selects core index `0..7`).
- `result_out` is stable-held to allow `strategy_arbiter` combinational comparison after `result_valid` pulses. It is cleared (set to 0) only on the next `features_valid`.
- `result_ready` is the stable version of the done flag consumed by `strategy_arbiter`.
