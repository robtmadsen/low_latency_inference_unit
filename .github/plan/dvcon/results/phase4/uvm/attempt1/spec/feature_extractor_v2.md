# `feature_extractor_v2` — 32-Feature Bfloat16 Pipeline

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Converts raw parsed ITCH fields and live BBO data from `order_book` into a 32-element bfloat16 feature vector for the inference cores. Implements a 4-stage registered pipeline with a total latency of 4 cycles from `feat_ext_fv` to `features_valid`.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `VEC_LEN` | `FEAT_VEC_LEN_V2` (32) | Number of output features |

## Ports

### Inputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `feat_ext_fv` | in | 1 | Gated valid: `fields_valid_d3 & watchlist_hit` |
| `price` | in | 32 | Trigger order price (aligned with `feat_ext_fv`) |
| `shares` | in | 32 | Trigger order shares |
| `side` | in | 8 | 'B' or 'S' |
| `sym_id` | in | 16 | Symbol index |
| `bbo_bid_price` | in | 32 | Best bid price from `order_book` |
| `bbo_bid_size` | in | 32 | Best bid size from `order_book` |
| `bbo_ask_price` | in | 32 | Best ask price from `order_book` |
| `bbo_ask_size` | in | 32 | Best ask size from `order_book` |
| `bbo_bid_levels` | in | `4×32` | L2 bid prices (4 levels) |
| `bbo_ask_levels` | in | `4×32` | L2 ask prices (4 levels) |
| `bbo_bid_sizes` | in | `4×32` | L2 bid sizes (4 levels) |
| `bbo_ask_sizes` | in | `4×32` | L2 ask sizes (4 levels) |
| `ptp_counter` | in | 64 | Free-running PTP timestamp counter |

### Outputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `features_valid` | out | 1 | One-cycle pulse when `features` is stable |
| `features` | out | `32×16` | 32-element bfloat16 feature vector |
| `features_sym_id` | out | 16 | Passes through `sym_id` aligned with features |

## Feature Vector Definition

Features are indexed [0..31]. All values are bfloat16 encoded via the `mag_to_bf16()` task (round-to-nearest, no denormals).

| Index | Name | Computation |
|-------|------|-------------|
| 0 | `price_delta` | `price − last_price[sym_id]` (signed, saturation) |
| 1 | `side_enc` | 0.0 = Buy, 1.0 = Sell |
| 2 | `order_flow` | Running `order_flow_cnt[sym_id]` signed count |
| 3 | `norm_price` | `price / 32768` (unsigned) |
| 4 | `bbo_bid_price` | Best bid price |
| 5 | `bbo_ask_price` | Best ask price |
| 6 | `bbo_bid_size` | Best bid size |
| 7 | `bbo_ask_size` | Best ask size |
| 8 | `spread` | `bbo_ask_price − bbo_bid_price` |
| 9 | `mid_price` | `(bbo_bid_price + bbo_ask_price) >> 1` |
| 10 | `order_vs_bid` | `price − bbo_bid_price` |
| 11 | `order_vs_ask` | `price − bbo_ask_price` |
| 12–15 | `l2_bid_price[0..3]` | L2 bid prices, levels 0–3 |
| 16–19 | `l2_ask_price[0..3]` | L2 ask prices, levels 0–3 |
| 20–23 | `l2_bid_size[0..3]` | L2 bid sizes, levels 0–3 |
| 24–27 | `l2_ask_size[0..3]` | L2 ask sizes, levels 0–3 |
| 28 | `rolling_buy_vol` | Per-symbol rolling buy volume accumulator |
| 29 | `rolling_sell_vol` | Per-symbol rolling sell volume accumulator |
| 30 | `vwap_approx` | Approximate VWAP: `rolling_buy_vol / (rolling_buy_vol + rolling_sell_vol)` |
| 31 | `msg_arrival_period` | `ptp_counter − last_arrival_ts[sym_id]` (inter-arrival time) |

### Per-symbol state (LUTRAM)

- `last_price[64]` — 32-bit, last trigger price per symbol.
- `order_flow_cnt[64]` — 32-bit signed, +1 on Buy, −1 on Sell, reset on configurable threshold.
- `rolling_buy_vol[64]`, `rolling_sell_vol[64]` — 32-bit saturating accumulators.
- `last_arrival_ts[64]` — 64-bit, last PTP counter snapshot.

All LUTRAM arrays are 64 entries deep (one per tracked symbol).

## Pipeline Stages

| Stage | Cycle | Operations |
|-------|-------|-----------|
| S1 | 0→1 | Register raw inputs; fetch LUTRAM `last_price`, `order_flow_cnt`, volumes, `last_arrival_ts` |
| S2 | 1→2 | Compute integer arithmetic: deltas, spread, mid, order_vs_bid/ask, inter-arrival |
| S3 | 2→3 | Apply `mag_to_bf16()` to all 32 features; update LUTRAM per-symbol state |
| S4 | 3→4 | Register feature vector output; assert `features_valid` |

## Timing

- Pipeline latency: **4 cycles** from `feat_ext_fv` to `features_valid`.
- One active context at a time (enforced by `pipeline_hold` in `lliu_top_v2`).
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.
- `mag_to_bf16()` is a purely combinational function: takes a 32-bit magnitude and produces a 16-bit bfloat16. It does not handle sign (sign is embedded in feature semantics as needed).
