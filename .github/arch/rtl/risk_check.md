# `risk_check` — Pre-Trade Risk Enforcement

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Enforces three pre-trade risk controls before any order enters the OUCH engine: (1) fat-finger share-quantity check, (2) price-band check using a DSP48E1 multiplier with output pipeline register (PREG=1), and (3) per-symbol position limit using a BRAM-backed signed accumulator. A hardware kill switch and TX overflow flag serve as hard gates.

## Ports

### Trigger Input

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `trigger` | in | 1 | One-cycle pulse from `strategy_arbiter` (`best_valid`) |
| `proposed_shares` | in | 32 | Share quantity from held register in `lliu_top_v2` |
| `proposed_price` | in | 32 | Order price from held register |
| `proposed_side` | in | 8 | 'B' or 'S' from held register |
| `proposed_sym_id` | in | 16 | Symbol index |

### Risk Limits (AXI4-Lite configured)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `max_qty` | in | 32 | Maximum single-order share quantity |
| `price_band_pct` | in | 16 | Price band in basis points (e.g. 200 = 2%) |
| `ref_price` | in | 32 | Reference price for band check |
| `max_position` | in | 24 | Maximum signed position magnitude per symbol |
| `kill_sw` | in | 1 | Hard kill switch; when asserted all orders are blocked |
| `tx_overflow` | in | 1 | OUCH TX overflow flag; blocks orders when asserted |

### Outputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `risk_pass` | out | 1 | One-cycle pulse: order cleared all checks |
| `risk_block` | out | 1 | One-cycle pulse: order blocked |
| `block_reason` | out | 2 | Encoding: 00=none, 01=price-band, 10=fat-finger, 11=position |

## Pipeline Stages

Risk check is a 2-stage registered pipeline (2-cycle latency from `trigger` to `risk_pass`):

| Stage | Cycle | Operations |
|-------|-------|-----------|
| **S1** | 0→1 | Latch inputs; read BRAM position (address = `proposed_sym_id`); compute fat-finger: `fat_finger_fail = proposed_shares > max_qty`; issue DSP48E1 multiply: `band_product = proposed_price × price_band_pct` |
| **S2** | 1→2 | DSP PREG captures `band_product` (Vivado maps PREG=1 pattern); evaluate band: `band_fail = proposed_price > (ref_price + band_product/10000)`; evaluate position: `pos_fail = (position[sym_id] + delta) > max_position`; combine: `pass = ~fat_finger_fail & ~band_fail & ~pos_fail & ~kill_sw & ~tx_overflow`; assert `risk_pass` or `risk_block` |

### BRAM position store

- `RAMB18E1`, 512×24-bit, signed two's complement.
- Addressed by `proposed_sym_id[8:0]` (bottom 9 bits; supports up to 512 symbols, only 64 used).
- Read latency 1 cycle (matches S1→S2).
- Writeback: 1 cycle after `risk_pass`, position `[sym_id]` is incremented (+`shares` for Buy, −`shares` for Sell). Writeback does not block future reads; back-to-back events are serialized by `pipeline_hold`.

### DSP timing note

The `price × price_band_pct` multiply is coded directly in `always_ff` as `band_product <= proposed_price * price_band_pct`. Vivado infers a DSP48E1 with PREG=1 automatically, consuming the product register inside the DSP slice. This was required to meet timing at 312.5 MHz; a relay path through fabric would introduce −1.805 ns WNS.

## `block_reason` Encoding

| Code | Meaning |
|------|---------|
| `2'b00` | No block (only appears with `risk_pass`) |
| `2'b01` | Price-band violation |
| `2'b10` | Fat-finger (shares > max_qty) |
| `2'b11` | Position limit exceeded |

Kill switch and TX overflow blocks set `block_reason = 2'b01` (price-band slot reused; AXI4-Lite status register disambiguates).

## Timing

- **Latency**: 2 cycles from `trigger` to `risk_pass`/`risk_block`.
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.
- `risk_pass` is the `t_end` timestamp source for `u_tap_risk_pass` in `lliu_top_v2`.
- The kill switch (`AXI4-Lite 0x40C[0]`) is write-1-to-set; cleared only by hardware reset.
