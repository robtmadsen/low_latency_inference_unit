# `order_book` — BBO + L2 Order Book

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Maintains a two-sided order book for up to 64 symbols. Processes ITCH 5.0 add, cancel, delete, replace, and execute messages to keep per-symbol best-bid-offer (BBO) and 4-level L2 summaries current. Uses a CRC-17/CAN hash over the 64-bit order reference number to index LUTRAM price and BRAM reference storage.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `OB_NUM_SYMBOLS` | 64 | Number of tracked symbols |
| `OB_LEVELS` | 4 | L2 depth per side |
| `OB_REF_TABLE_BITS` | 13 | Hash width → 8 192-entry reference table |

## Ports

### Parsed Field Inputs (from `itch_parser_v2`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `fields_valid` | in | 1 | One-cycle pulse with valid fields |
| `msg_type` | in | 8 | ITCH message type |
| `order_ref` | in | 64 | Primary order reference number |
| `new_order_ref` | in | 64 | Replacement order ref (Replace only) |
| `price` | in | 32 | Price in ITCH units |
| `shares` | in | 32 | Share quantity |
| `side` | in | 8 | 'B' or 'S' |
| `sym_id` | in | 16 | Symbol index (0–63) |

### BBO Outputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `bbo_valid` | out | 1 | One-cycle pulse after each BBO update |
| `bbo_sym_id` | out | 16 | Symbol whose BBO changed |
| `bbo_bid_price` | out | 32 | Best bid price |
| `bbo_bid_size` | out | 32 | Aggregated size at best bid |
| `bbo_ask_price` | out | 32 | Best ask price |
| `bbo_ask_size` | out | 32 | Aggregated size at best ask |
| `bbo_bid_levels` | out | `4×64` | L2 bid prices (4 levels × 32-bit) |
| `bbo_ask_levels` | out | `4×64` | L2 ask prices (4 levels × 32-bit) |

### Monitoring

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `collision_count` | out | 32 | Saturating count of CRC-17 hash collisions |

## Hash Function — CRC-17/CAN

```
polynomial : 0x1002D (17-bit)
init       : 17'h1FFFF
reflect    : false (MSB-first)
input      : order_ref[63:0], processed bit-by-bit
```

The 13 LSBs of the CRC-17 remainder index `ref_mem` (BRAM, 8 192 entries). On a collision the incoming reference number is compared against the stored reference; mismatches increment `collision_count` (saturates at 32'hFFFF_FFFF) and the new entry overwrites the colliding slot.

## Memory Resources

| Memory | Type | Organization | Content |
|--------|------|-------------|---------|
| `book_mem` | LUTRAM | `64 × (4+4) × 32 × 2` bits | L2 price + size levels per symbol/side |
| `ref_mem` | BRAM (RAMB18E1) | `8192 × (64+32+16+1)` bits | order_ref, price, shares, sym_id, valid |

`book_mem` holds the 4-level L2 array. BBO is always `book_mem[sym][0]` (highest priority bid / lowest priority ask after sorted insertion).

## FSM

Seven states:

| State | Description |
|-------|-------------|
| `IDLE` | Waiting for `fields_valid` |
| `READ_REF1` | Issue BRAM read address for `order_ref` hash |
| `READ_REF2` | Wait for BRAM read latency (2 cycles) |
| `PROCESS` | Decode message type; compute new level array |
| `SCAN_BOOK` | Walk existing 4-level array to find insertion/deletion point |
| `UPDATE` | Write new level array to `book_mem`; update BBO registers |
| `DONE` | Assert `bbo_valid` for 1 cycle; write `ref_mem` if needed; return to `IDLE` |

### State transitions

```
IDLE → READ_REF1   : fields_valid & msg_type ∈ {A,F,X,D,U,E,C,P}
READ_REF1 → READ_REF2
READ_REF2 → PROCESS  (after 2-cycle BRAM latency)
PROCESS → SCAN_BOOK
SCAN_BOOK → UPDATE   (after iterating OB_LEVELS entries)
UPDATE → DONE
DONE → IDLE
```

## BBO Update Logic

1. Add (A/F): sorted insert into the bid or ask array by price priority (bid: descending; ask: ascending). Size aggregated at the best level.
2. Cancel (X): look up `order_ref` in `ref_mem`; reduce size at matching price level; remove level if size reaches zero.
3. Delete (D): same as cancel but removes the full remaining size.
4. Replace (U): delete `order_ref`, then insert `new_order_ref` at the new price/size.
5. Execute (E/C): reduce size; remove level if exhausted.
6. Trade (P): no book modification (trade prints do not update resting liquidity).

`bbo_valid` is pulsed once per `fields_valid` event that results in a BBO change.

## Timing

- BRAM read latency: 2 cycles (READ_REF1 + READ_REF2).
- Total per-message latency: 6–8 cycles depending on scan depth.
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.
- The `order_book` module does not assert backpressure; upstream `itch_parser_v2` is held by `pipeline_hold` during inference, which provides sufficient dead time for the book to complete each update.
