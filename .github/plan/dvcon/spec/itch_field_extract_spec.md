# itch_field_extract — DUT Specification

Module: itch_field_extract  
Language: SystemVerilog  
Depends on: lliu_pkg (imported via `import lliu_pkg::*`)

## Purpose

Registered field slicer for NASDAQ ITCH 5.0 Add Order messages.
Extracts fields from a packed 36-byte message buffer and registers
all outputs, adding exactly one pipeline stage of latency.
Only asserts `fields_valid` when the message type is Add Order (0x41 = 'A').

## Interface

### Inputs

| Signal | Width | Description |
|--------|-------|-------------|
| `clk` | 1 | Clock |
| `rst` | 1 | Synchronous active-high reset |
| `msg_data` | 288 | Packed 36-byte message buffer. Byte N = `msg_data[(35-N)*8 +: 8]` |
| `msg_valid` | 1 | Asserted when `msg_data` holds a complete message |

### Outputs (all registered — valid one cycle after msg_valid)

| Signal | Width | Description |
|--------|-------|-------------|
| `message_type` | 8 | Byte 0 of message |
| `order_ref` | 64 | Bytes 11–18, big-endian |
| `side` | 1 | 1 = buy ('B'=0x42), 0 = sell |
| `price` | 32 | Bytes 32–35, big-endian |
| `stock` | 64 | Bytes 24–31, 8-byte ASCII ticker |
| `fields_valid` | 1 | 1 iff `msg_valid` AND `message_type == 0x41` |

## ITCH 5.0 Add Order Message Layout (36 bytes, all big-endian)

| Byte(s) | Field |
|---------|-------|
| 0 | message_type (0x41 = Add Order) |
| 1–2 | stock_locate |
| 3–4 | tracking_number |
| 5–10 | timestamp (nanoseconds since midnight) |
| 11–18 | order_reference_number (uint64) |
| 19 | buy_sell_indicator ('B' = 0x42 buy, 'S' = 0x53 sell) |
| 20–23 | shares (uint32) |
| 24–31 | stock (8-byte ASCII, right-padded with spaces 0x20) |
| 32–35 | price (uint32, fixed-point: divide by 10000 for dollars) |

## Timing

- Outputs are registered: valid exactly 1 clock after `msg_valid` is asserted
- Reset is synchronous active-high; all outputs go to 0 on `rst`

## Filter Behaviour

- If `msg_valid=1` and `message_type != 0x41`: `fields_valid=0` one cycle later;
  all other outputs reflect the non-Add-Order message bytes (don't-care)
- If `msg_valid=0`: `fields_valid=0` one cycle later

## Coverage Requirements

The testbench must satisfy all of the following:

- 100% line coverage of `itch_field_extract.sv`
- Buy side exercised (`buy_sell_indicator = 'B' = 0x42`)
- Sell side exercised (`buy_sell_indicator != 0x42`)
- Non-Add-Order message type exercised (`fields_valid` stays 0)
- Synchronous reset exercised (all outputs clear to 0)
- Back-to-back valid messages (`msg_valid` high across consecutive cycles)
- `msg_valid=0` while `msg_data` changes (`fields_valid` stays 0)
