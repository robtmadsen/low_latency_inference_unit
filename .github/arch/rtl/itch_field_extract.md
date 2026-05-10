# Module Spec: `itch_field_extract`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

Registered field slicer for ITCH 5.0 Add Order messages. Receives a packed 288-bit (`36 × 8`) message data bus from `itch_parser`, decodes each field combinationally, and registers all outputs to close the timing path between the `msg_buf` (wide fanout combinational mux in `itch_parser`) and `feature_extractor`. Adds exactly **one pipeline stage** (1 cycle). Only asserts `fields_valid` for Add Order messages (type `'A'` = `0x41`).

## Parameters

None. Uses `ITCH_ADD_ORDER_LEN` (36) from `lliu_pkg` via localparameter `B`.

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset (`sys_rst`) |
| `msg_data` | in | `B*8` = 288 | Packed message bytes; byte N at `msg_data[(B-1-N)*8 +: 8]` |
| `msg_valid` | in | 1 | One-cycle strobe from `itch_parser` EMIT state |
| `message_type` | out | 8 | Registered `msg_data[0]` — ITCH message type |
| `order_ref` | out | 64 | Registered order reference number (bytes 11–18) |
| `side` | out | 1 | Registered buy/sell (`1` = buy `'B'`, `0` = sell/other) |
| `price` | out | 32 | Registered price (bytes 32–35, big-endian) |
| `stock` | out | 64 | Registered 8-byte ASCII ticker (bytes 24–31) |
| `fields_valid` | out | 1 | One-cycle strobe: registered, Add Order type only |

## ITCH 5.0 Add Order Field Layout

```
Byte offset  Width   Field
──────────── ─────── ──────────────────────────────
0            1       message_type        ('A' = 0x41)
1–2          2       stock_locate        (not extracted)
3–4          2       tracking_number     (not extracted)
5–10         6       timestamp           (not extracted)
11–18        8       order_reference_number (big-endian)
19           1       buy_sell_indicator  ('B' = buy, 'S' = sell)
20–23        4       shares              (not extracted)
24–31        8       stock               (8-byte ASCII, zero-padded right)
32–35        4       price               (big-endian, 4 decimal places fixed-point)
```

## Combinational Decode

All decoding is combinational from `msg_data`; results are registered on the next clock edge when `msg_valid` is high.

| Output | Source bytes | Expression |
|--------|-------------|------------|
| `message_type_comb` | 0 | `msg_data[(B-1)*8 +: 8]` |
| `order_ref_comb` | 11–18 | 8 bytes big-endian concat from `(B-1-11)` down to `(B-1-18)` |
| `side_comb` | 19 | `msg_data[(B-1-19)*8 +: 8] == 8'h42` (`'B'`) |
| `price_comb` | 32–35 | 4 bytes big-endian concat from `(B-1-32)` down to `(B-1-35)` |
| `stock_comb` | 24–31 | 8 bytes big-endian concat from `(B-1-24)` down to `(B-1-31)` |
| `fields_valid_comb` | — | `msg_valid && (message_type_comb == 8'h41)` |

## Pipeline Stage

```
         msg_valid (from itch_parser EMIT state)
              │
    ┌─────────▼──────────────────┐
    │  Combinational decode       │
    │  (fields_valid_comb, etc.)  │
    └─────────┬──────────────────┘
              │ posedge clk
    ┌─────────▼──────────────────┐
    │  Output registers           │  ← fields_valid, order_ref, side, price, stock
    └────────────────────────────┘
         fields_valid (1 cycle after msg_valid)
```

**Latency: 1 cycle** from `msg_valid` to `fields_valid`.

## Reset Behavior

All output registers reset to zero / `1'b0`. In particular, `fields_valid` resets to `1'b0`, ensuring no spurious inference trigger at power-on.

## Design Note

The registered output stage exists specifically to close the timing path. The combinational decode from `msg_data` is a wide mux tree with 36 source bytes (288-bit bus); without the register stage, this wide combinational path would violate timing from `msg_buf` to `feat_vec` at 300 MHz. The 1-cycle latency is counted in the system latency budget (see [SYSTEM.md](SYSTEM.md)).
