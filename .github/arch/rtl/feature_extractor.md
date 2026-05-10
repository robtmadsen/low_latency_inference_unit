# Module Spec: `feature_extractor`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

Transforms the registered ITCH Add Order fields (`price`, `side`, `order_ref`) into a `VEC_LEN`-element bfloat16 feature vector suitable for the dot-product engine. Maintains running state (`last_price`, `order_flow`) across messages. Adds exactly **3 pipeline stages** between `fields_valid` and `features_valid`.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `VEC_LEN` | `FEATURE_VEC_LEN` (4) | Number of bfloat16 features produced per message |

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset (`sys_rst`) |
| `price` | in | 32 | Raw ITCH price (4 implied decimal places) |
| `order_ref` | in | 64 | Order reference (reserved; not used in current feature set) |
| `side` | in | 1 | Buy (1) / sell (0) |
| `fields_valid` | in | 1 | One-cycle strobe from `itch_field_extract` |
| `features` | out | `bfloat16_t[VEC_LEN]` | Computed feature vector |
| `features_valid` | out | 1 | One-cycle strobe; all elements valid simultaneously |

## Feature Vector Definition (VEC_LEN = 4)

| Index | Feature | Description |
|-------|---------|-------------|
| 0 | price delta | `current_price − last_price`; signed; zero on first message |
| 1 | side encoding | `+1.0` (buy) or `−1.0` (sell) |
| 2 | order flow | Running `buy_count − sell_count` imbalance; signed integer cast to bfloat16 |
| 3 | normalized price | Raw `price[30:0]` as bfloat16 (sign bit forced 0) |

## Pipeline Stages

### Stage 1 — Integer arithmetic (fires on `fields_valid`)

Registered outputs: `price_delta_r`, `side_enc_int_r`, `flow_val_r`, `price_norm_r`, `valid_d1`.

Also updates running state (`last_price`, `order_flow`) in the same always_ff block.

| Computed value | Expression |
|----------------|-----------|
| `price_delta_r` | `signed(price) − signed(last_price)` |
| `side_enc_int_r` | `+1` if `side=1`, `−1` if `side=0` |
| `flow_val_r` | `sign_extended(order_flow) + (side ? +1 : −1)` |
| `price_norm_r` | `{1'b0, price[30:0]}` |

### Stage 2a — Magnitude and sign extraction (fires on `valid_d1`)

Breaks the CARRY4 absolute-value chain across a register boundary.

For each feature:
- `sgn_r2` — sign bit of the signed integer
- `mag_r2` — two's-complement absolute value (`~x + 1` if negative)
- `zero_r2` — high if value is exactly zero

Registered outputs: `mag0..3_r2`, `sgn0..3_r2`, `zero0..3_r2`, `valid_d2`.

### Stage 2b — bfloat16 normalization (fires on `valid_d2`)

Calls the combinational function `mag_to_bf16(is_zero, sign_bit, mag)` for each feature:

1. If `is_zero`: return `16'h0000`.
2. Count leading zeros in `mag[31:0]` to find exponent.
3. Compute: `exp = 127 + 31 − lz`, `mantissa = (mag << (lz + 1)) >> 25` (top 7 bits after normalization shift).
4. Assemble: `{sign_bit, exp[7:0], mantissa[6:0]}`.

Registered outputs: `features[0..3]`, `features_valid`.

## Pipeline Diagram

```
fields_valid
    │
    │  Stage 1 (posedge clk)
    │  Integer arithmetic
    │  State update: last_price, order_flow
    ▼
  valid_d1 + {price_delta_r, side_enc_int_r, flow_val_r, price_norm_r}
    │
    │  Stage 2a (posedge clk)
    │  Abs value: mag, sign, zero for each feature
    ▼
  valid_d2 + {mag0..3_r2, sgn0..3_r2, zero0..3_r2}
    │
    │  Stage 2b (posedge clk)
    │  bfloat16 encode: leading-zero + shift
    ▼
  features_valid + features[0..3]   (3 cycles after fields_valid)
```

**Latency: 3 cycles** from `fields_valid` to `features_valid`.

## Running State

| Register | Width | Reset | Description |
|----------|-------|-------|-------------|
| `last_price` | 32 | 0 | Price from the previous Add Order message |
| `order_flow` | 16 (signed) | 0 | Cumulative `buy_count − sell_count` |

Both registers are updated in Stage 1 (same always_ff that computes `price_delta_r`). This means `last_price` and `order_flow` are updated **in the same cycle as `fields_valid`**, so the delta and flow values computed in Stage 1 correctly reflect the difference between the current and previous messages.

## Reset Behavior

All pipeline registers (`valid_d1`, `valid_d2`, `features_valid`, `features[*]`) reset to zero. `last_price` and `order_flow` reset to 0; the first message after reset will produce `price_delta = price` (full price, not a delta).

## Design Notes

- `order_ref` is accepted as a port (for interface compatibility) but is marked `UNUSED` in the current implementation. A future feature set may include order-ref–based lookups.
- The three-stage split exists to isolate three distinct FPGA critical paths: CARRY4 subtraction (Stage 1), CARRY4 absolute value (Stage 2a), and priority-encode lookup table (Stage 2b).
- `features_valid` is a one-cycle strobe; it is `0` in all cycles when `valid_d2` is not asserted.
