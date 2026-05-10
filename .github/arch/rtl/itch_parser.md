# Module Spec: `itch_parser`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

Accepts a NASDAQ ITCH 5.0 byte stream over a 64-bit AXI4-Stream interface. Strips the 2-byte big-endian length prefix from each message, accumulates the message body across multiple AXI4-S beats into a byte buffer, then asserts `msg_valid` for one cycle when the complete message body has been received. Instantiates `itch_field_extract` internally to decode Add Order fields from the buffer.

## Parameters

None. Uses `ITCH_ADD_ORDER_LEN` (36) from `lliu_pkg` to size the message buffer pack logic.

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset (`sys_rst`) |
| `s_axis_tdata` | in | 64 | ITCH byte stream; tdata[63:56] = first byte of beat |
| `s_axis_tvalid` | in | 1 | AXI4-S valid |
| `s_axis_tready` | out | 1 | AXI4-S ready; de-asserted in EMIT state or when `pipeline_hold` high |
| `s_axis_tlast` | in | 1 | Last beat of AXI4-S frame (accepted but not semantically required by FSM) |
| `pipeline_hold` | in | 1 | From `lliu_top`: de-assert ready while inference pipeline is busy |
| `msg_valid` | out | 1 | One-cycle strobe: complete message body stored in `msg_buf` |
| `message_type` | out | 8 | Registered message type byte (`msg_buf[0]`) from `itch_field_extract` |
| `order_ref` | out | 64 | Registered order reference number from `itch_field_extract` |
| `side` | out | 1 | Registered buy/sell indicator from `itch_field_extract` |
| `price` | out | 32 | Registered price field from `itch_field_extract` |
| `stock` | out | 64 | Registered 8-byte ASCII ticker from `itch_field_extract` |
| `fields_valid` | out | 1 | One-cycle strobe: Add Order fields valid (from `itch_field_extract`) |

## FSM

Three states:

```
           s_axis_tvalid && s_axis_tready
                     │
         ┌───────────▼──────────────┐
         │         S_IDLE           │
         │ Extract length prefix     │
         │ Store first 6 msg bytes   │
         └────┬────────────────┬────┘
              │ msg_len > 6    │ msg_len ≤ 6
              ▼                ▼
    ┌──────────────────┐  ┌──────────────┐
    │  S_ACCUMULATE    │  │   S_EMIT     │
    │ Store 8B/beat    │  │ msg_valid=1  │
    │ until byte_cnt   │  │ (1 cycle)    │
    │ >= msg_len       │  └──────┬───────┘
    └────────┬─────────┘         │
             │ (byte_cnt>=len)   │
             └──────►  S_EMIT ◄──┘
                          │
                          └──► S_IDLE (next cycle)
```

### State behavior

| State | `s_axis_tready` | `msg_valid` | Action |
|-------|----------------|-------------|--------|
| `S_IDLE` | `!pipeline_hold` | 0 | Accept beat; extract `msg_len` from `tdata[63:48]`; store bytes 0–5 into `msg_buf[0..5]` |
| `S_ACCUMULATE` | `!pipeline_hold` | 0 | Accept beat; store 8 bytes into `msg_buf[byte_cnt .. byte_cnt+7]`; when `byte_cnt + 8 >= msg_len`, transition to `S_EMIT` |
| `S_EMIT` | 0 | 1 | Assert `msg_valid` for one cycle; return to `S_IDLE` |

## Message Buffer Layout

- `msg_buf[0:127]` — 128-byte buffer (7-bit `byte_cnt` index). Only bytes `0..ITCH_ADD_ORDER_LEN-1` (0..35) are used for field extraction.
- Byte 0 in the buffer is the first byte of the message body (the message type byte), immediately after the 2-byte length prefix.
- The buffer is packed into `msg_data` for `itch_field_extract`:
  ```
  msg_data[(B-1-N)*8 +: 8] = msg_buf[N]   for N in 0..B-1, B=36
  ```

## ITCH 5.0 Message Framing

```
AXI4-S beat layout (big-endian):
  tdata[63:56] — byte 0 of this beat (earliest byte in stream)
  tdata[7:0]   — byte 7 of this beat

Beat 0 (first beat of a new ITCH message):
  tdata[63:48] — 2-byte big-endian length prefix  (msg_len)
  tdata[47:0]  — first 6 bytes of message body    (msg_buf[0..5])

Beat 1..N (S_ACCUMULATE):
  tdata[63:0]  — 8 bytes of message body          (msg_buf[byte_cnt..byte_cnt+7])
```

For an Add Order message (body = 36 bytes), the message spans 5 beats:
- Beat 0: prefix + 6B → `byte_cnt` = 6
- Beat 1: 8B → `byte_cnt` = 14
- Beat 2: 8B → `byte_cnt` = 22
- Beat 3: 8B → `byte_cnt` = 30
- Beat 4: 8B (last 6 meaningful) → `byte_cnt` >= 36 → transition to `S_EMIT`

## Timing

- `msg_valid` (and thus the start of `itch_field_extract` combinational decode) appears **1 cycle after the last beat is stored** (the clock edge that transitions into `S_EMIT`).
- `fields_valid` appears **2 cycles after the last beat** (`msg_valid` is the `itch_field_extract` input; its registered outputs — including `fields_valid` — appear 1 cycle later).

## Submodule

`itch_field_extract` is instantiated inside `itch_parser`. Its output ports (`message_type`, `order_ref`, `side`, `price`, `stock`, `fields_valid`) are passed through as top-level outputs of `itch_parser`.
