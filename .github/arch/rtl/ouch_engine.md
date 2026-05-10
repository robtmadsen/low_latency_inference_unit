# `ouch_engine` — OUCH 5.0 Packet Assembler

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Assembles and transmits a 48-byte OUCH 5.0 Enter Order message over an AXI4-Stream master interface. The body is built from four BRAM-based templates indexed by symbol and beat, with three hot-patched fields (order token, shares, price) overwritten inline during transmission.

## Ports

### Trigger Input

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `send` | in | 1 | One-cycle pulse from `risk_check.risk_pass` |
| `sym_id` | in | 7 | Symbol index — selects BRAM template row |
| `shares` | in | 32 | Share quantity to embed in message |
| `price` | in | 32 | Price to embed in message |
| `side` | in | 8 | 'B' or 'S' (not embedded; side is fixed per template) |

### AXI4-Stream Master

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `m_axis_tdata` | out | 64 | OUCH 5.0 byte stream, big-endian |
| `m_axis_tkeep` | out | 8 | Byte enables |
| `m_axis_tvalid` | out | 1 | Beat valid |
| `m_axis_tlast` | out | 1 | Final beat |
| `m_axis_tready` | in | 1 | Backpressure from TX MAC |

### Monitoring

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `tx_overflow` | out | 1 | Asserted when backpressure watchdog trips; self-clearing |

## BRAM Template Organization

Four BRAM instances cover the 6 beats of an OUCH Enter Order (48 bytes / 8 = 6 × 8-byte beats):

| BRAM | Beats covered | `ram_style` |
|------|--------------|------------|
| `tmpl_b2` | Beat 2 | `"block"` |
| `tmpl_b3` | Beat 3 | `"block"` |
| `tmpl_b4` | Beat 4 | `"block"` |
| `tmpl_b5` | Beat 5 | `"block"` |

Each BRAM is 128×32 bits. Beat 0 and beat 1 are static (message type and session/order fields) and are generated combinationally from the token counter.

Template indexing: `addr = {sym_id[6:0], beat[1:0]}` → 9-bit address.

## FSM

Four states:

| State | Description |
|-------|-------------|
| `IDLE` | Waiting for `send` |
| `FETCH` | Issue BRAM read addresses for beats 2–5 |
| `LOAD` | Wait 1 cycle for BRAM output; begin beat 0 transmission |
| `SEND` | Stream all 6 beats; stall on `~m_axis_tready`; hot-patch beats containing shares/price |

### FSM transitions

```
IDLE → FETCH  : send
FETCH → LOAD  : always (1 cycle)
LOAD → SEND   : m_axis_tready (or unconditional with beat_cnt=0)
SEND → IDLE   : m_axis_tlast & m_axis_tready
```

## OUCH Enter Order Layout (48 bytes)

| Beat | Bytes | Content |
|------|-------|---------|
| 0 | 0–7 | MSG_TYPE ('O' = 0x4F), timestamp[47:0] |
| 1 | 8–15 | order_token[63:0] (auto-incremented) |
| 2 | 16–23 | Template: account, side, TIF, … |
| 3 | 24–31 | Template: symbol (from BRAM) |
| 4 | 32–39 | shares[31:0] (hot-patched) + template |
| 5 | 40–47 | price[31:0] (hot-patched) + template |

`order_token` auto-increments by 1 on each `send`; wraps at 64-bit maximum.

### Hot-patch

During the `SEND` state, beats 4 and 5 are taken from BRAM but the 32-bit `shares` and `price` fields are ORed in over the template placeholder bytes. The template bytes at those positions must be pre-programmed to 0x00 by the host.

## TX Overflow Watchdog

A 7-bit stall counter increments every clock the `SEND` state is active with `~m_axis_tready`. At 64 consecutive stalled cycles `tx_overflow` is asserted. After `m_axis_tready` is restored and 256 consecutive free cycles elapse, `tx_overflow` self-clears. `tx_overflow` is forwarded to `risk_check` and to `lliu_top_v2.tx_overflow_out`.

## Timing

- Beat 0 transmission begins at `LOAD` state (2 cycles after `send`).
- Full 6-beat packet completes in 6 + stall cycles from `send`.
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.
