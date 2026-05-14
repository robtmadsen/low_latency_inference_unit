# `symbol_filter` — 64-Entry LUT-CAM Watchlist

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Implements a 64-entry content-addressable memory (CAM) using LUT-RAM to perform a single-cycle watchlist lookup. On each `fields_valid` event the 64-bit `stock` ticker is compared against up to 64 stored keys; a registered hit drives the `watchlist_hit` gate in `lliu_top_v2`. A matching 3-cycle delay line on upstream parser fields ensures temporal alignment with the delayed hit signal.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `SYM_FILTER_ENTRIES` | 64 | Number of watchlist slots |

## Ports

### Lookup Interface

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `fields_valid` | in | 1 | One-cycle pulse from `itch_parser_v2` |
| `stock` | in | 64 | 8-byte ticker, space-padded |
| `watchlist_hit` | out | 1 | Registered: high 3 cycles after `fields_valid` if ticker is in watchlist |
| `sym_id_out` | out | 16 | Registered symbol index of matching entry (undefined if no hit) |

### AXI4-Lite Write Port (from `lliu_top_v2` inline decoder)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `cam_wr_index` | in | 6 | Entry index (0–63) |
| `cam_wr_data` | in | 64 | 8-byte ticker key |
| `cam_wr_valid` | in | 1 | Write strobe |
| `cam_wr_en_bit` | in | 1 | Enable bit for this entry |

## Internal Structure

### Storage

- `key_mem[63:0][63:0]` — 512×64-bit LUT-RAM, one 64-bit key per entry.
- `valid_bits[63:0]` — 64-bit register, one valid flag per entry.
- Entries with `valid_bits[i] = 0` can never produce a match.

### Pipeline Stages

```
Stage 1 (combinational + register):
  stock_q ← stock  (registered on fields_valid)
  (* max_fanout = 4 *) attribute applied to stock_q to constrain fanout

Stage 2 (register):
  match_partial_r[i] ← (stock_q == key_mem[i]) & valid_bits[i]  for i in 0..63

Stage 3 (register):
  lookup_match_q ← |match_partial_r[63:0]
  sym_id_out     ← priority-encoded index of first set bit in match_partial_r
```

`watchlist_hit` is the registered output of `lookup_match_q`.

### Fanout constraint

`(* max_fanout = 4 *)` is placed on `stock_q` to prevent Vivado from creating a high-fanout net that drives 64 comparators simultaneously across a large routing region. This forces the synthesizer to duplicate the register, improving timing on the 64-wide comparison tree.

## Timing

- **Lookup latency**: 3 registered cycles from `fields_valid` to `watchlist_hit`.
- `lliu_top_v2` implements a matching 3-stage delay line (`_d1`/`_d2`/`_d3`) on `fields_valid`, `price`, `shares`, `side`, and `sym_id` to preserve alignment.
- **Write latency**: `cam_wr_valid` → entry available on next lookup — 1 cycle.
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.
- Writes during an in-flight lookup do not corrupt the in-flight comparison.
