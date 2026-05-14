# `itch_parser_v2` — Multi-Type ITCH 5.0 Parser

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Parses a subset of NASDAQ ITCH 5.0 message types from a 64-bit AXI4-Stream byte flow into a flat set of structured output signals. Handles eight message types covering add, cancel, delete, replace, execute, and trade events. Buffers incoming bytes into a 64-byte staging register and emits parsed fields as a one-cycle `fields_valid` pulse once the full message payload has been captured.

## Ports

### AXI4-Stream Slave

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `s_axis_tdata` | in | 64 | ITCH byte stream, big-endian |
| `s_axis_tvalid` | in | 1 | Beat valid |
| `s_axis_tready` | out | 1 | Asserted unless `pipeline_hold` |
| `s_axis_tlast` | in | 1 | Last beat of AXI4-S packet |

### Control

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `pipeline_hold` | in | 1 | Backpressure: pauses ingress when an inference is in-flight |

### Parsed Field Outputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `fields_valid` | out | 1 | One-cycle pulse; all fields below are stable for one clock |
| `msg_type` | out | 8 | ASCII message type character |
| `order_ref` | out | 64 | Primary order reference number |
| `new_order_ref` | out | 64 | Replacement order ref (Replace message only) |
| `price` | out | 32 | Price in ITCH 1/10000 units |
| `shares` | out | 32 | Share quantity |
| `side` | out | 8 | Buy ('B') or Sell ('S') |
| `stock` | out | 64 | 8-byte stock ticker, space-padded |
| `sym_id` | out | 16 | Symbol index from `symbol_filter` (passed through for alignment) |

## FSM

Three states:

| State | Description |
|-------|-------------|
| `IDLE` | Waiting for a valid `s_axis_tvalid` beat |
| `ACCUMULATE` | Accumulating beats into `msg_buf[63:0]` (64-byte staging buffer, byte-indexed) |
| `EMIT` | Drives `fields_valid` for one cycle; extracts and registers fields from `msg_buf`; returns to `IDLE` |

### Transitions

```
IDLE:
  s_axis_tvalid & ~pipeline_hold  →  capture first beat into msg_buf[7:0..55:48]
                                      → ACCUMULATE (or EMIT if tlast on first beat)

ACCUMULATE:
  ~pipeline_hold & s_axis_tvalid & ~tlast  →  append beat, advance byte_cnt
  ~pipeline_hold & s_axis_tvalid &  tlast  →  append final beat → EMIT

EMIT (1 cycle):
  assert fields_valid; decode msg_buf → IDLE
```

`s_axis_tready` is de-asserted whenever `pipeline_hold` is high, regardless of FSM state.

## Supported Message Types

| ASCII | Hex | Name | Fields extracted |
|-------|-----|------|-----------------|
| `A` | 0x41 | Add Order (no MPID) | order_ref, shares, side, stock, price |
| `F` | 0x46 | Add Order with MPID | order_ref, shares, side, stock, price |
| `X` | 0x58 | Order Cancel | order_ref, shares |
| `D` | 0x44 | Order Delete | order_ref |
| `U` | 0x55 | Order Replace | order_ref, new_order_ref, shares, price |
| `E` | 0x45 | Order Execute | order_ref, shares |
| `C` | 0x43 | Order Execute with Price | order_ref, shares, price |
| `P` | 0x50 | Trade (Non-Cross) | order_ref, shares, side, stock, price |

Unknown message types: `fields_valid` is never asserted; FSM drains the packet and returns to `IDLE`.

## Field Byte Offsets in `msg_buf`

All ITCH 5.0 messages share a 2-byte header (length, type). Field offsets below are relative to the start of the message body (byte 0 = message type).

| Field | Add (A/F) | Cancel (X) | Delete (D) | Replace (U) | Execute (E/C) | Trade (P) |
|-------|-----------|-----------|------------|-------------|---------------|-----------|
| msg_type | 0 | 0 | 0 | 0 | 0 | 0 |
| order_ref | 11–18 | 11–18 | 11–18 | 11–18 | 11–18 | 11–18 |
| new_order_ref | — | — | — | 19–26 | — | — |
| shares | 19–22 | 19–22 | — | 27–30 | 19–22 | 19–22 |
| side | 23 | — | — | — | — | 23 |
| stock | 24–31 | — | — | — | — | 24–31 |
| price | 32–35 | — | — | 31–34 | 23–26 | 32–35 |

## Timing

- Registered EMIT output: `fields_valid` and all field outputs are flopped before leaving the module.
- Backpressure latency: entering `pipeline_hold` mid-packet stalls byte capture; the message is not corrupted because `msg_buf` retains its state.
- Per-message latency: 1 cycle per 8-byte beat + 1 EMIT cycle. Longest supported message (Replace, 35 bytes) takes 5 ACCUMULATE cycles + 1 EMIT = 6 cycles from first beat to `fields_valid`.
