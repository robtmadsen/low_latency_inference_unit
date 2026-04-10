# RTL Architecture — LLIU v2.0 (Kintex-7)

> **Status:** Phase 1 complete (PRs #40 + #41 on `main`, April 2026)
> **Target device:** `xc7k160tffg676-2` @ 312.5 MHz `sys_clk`
> **Simulator:** Verilator 5.046
> **Spec reference:** [2p0_kintex-7_MAS.md](2p0_kintex-7_MAS.md)

---

## 1. Module Hierarchy (Phase 1 scope)

```
lliu_top
├── eth_axis_rx_wrap        (10GbE RX, AXI4-S 64-bit @ 156.25 MHz)
├── moldupp64_strip         (MoldUDP64 framing strip)
├── itch_parser_v2          (full ITCH 5.0 8-type parser)
│   └── [inline field extraction — no sub-module]
├── symbol_filter           (512-entry LUT-CAM watchlist)
├── order_book              (BRAM-backed L3 book, CRC-17 hash, 7-state FSM)
├── feature_extractor       (v1: 4-feature; v2 upgrade deferred to Phase 2)
├── dot_product_engine
│   ├── bfloat16_mul        (DSP48E1 multiplier, 2-cycle)
│   └── fp32_acc            (5-stage FP32 accumulator)
├── weight_mem              (4-entry BF16 weight RAM)
├── output_buffer           (result latch)
├── axi4_lite_slave         (register map + CAM + histogram AXI4-Lite interface)
├── ptp_core                (64-bit free-running counter, 1-bit sync pulse)
├── timestamp_tap           (per-event 74-bit capture — 2 instances in Phase 1)
└── latency_histogram       (32-bin distributed-RAM histogram)
```

> **Phase 2 additions:** `feature_extractor_v2`, 8× `lliu_core`, `strategy_arbiter`,
> `risk_check`, `ouch_engine`. See [2p0_kintex-7_MAS.md §5](2p0_kintex-7_MAS.md).

---

## 2. New / Modified Modules — Phase 1

### 2.1 `lliu_pkg.sv`

Shared parameter package. All modules import it with:
```systemverilog
import lliu_pkg::*;
```

**v2.0 additions** (on top of v1 parameters):

| Parameter | Value | Description |
|-----------|-------|-------------|
| `ITCH_MSG_ADD_ORDER_MPID` | `8'h46` (`'F'`) | Add Order w/ MPID type byte |
| `ITCH_MSG_ORDER_CANCEL` | `8'h58` (`'X'`) | Order Cancel |
| `ITCH_MSG_ORDER_DELETE` | `8'h44` (`'D'`) | Order Delete |
| `ITCH_MSG_ORDER_REPLACE` | `8'h55` (`'U'`) | Order Replace |
| `ITCH_MSG_ORDER_EXEC` | `8'h45` (`'E'`) | Order Executed |
| `ITCH_MSG_ORDER_EXEC_PX` | `8'h43` (`'C'`) | Order Executed w/ Price |
| `ITCH_MSG_TRADE` | `8'h50` (`'P'`) | Trade (non-cross) |
| `ITCH_MAX_MSG_LEN` | `43` | Max body length (type P) |
| `OB_NUM_SYMBOLS` | `500` | Order book symbol count |
| `OB_LEVELS` | `16` | Price levels per side per symbol |
| `OB_REF_TABLE_BITS` | `17` | CRC-17 hash → 131,072-entry ref table |
| `PTP_SYNC_PERIOD` | `1024` | Cycles between `ptp_sync_pulse` pulses |
| `PTP_SUBCNT_WIDTH` | `10` | Bits in `local_sub_cnt` |
| `SYM_FILTER_ENTRIES` | `512` | CAM watchlist size |
| `SYM_FILTER_IDX_W` | `9` | CAM index width |
| `AXIL_REG_CAM_INDEX_HI` | `8'h38` | Upper bits of 512-entry CAM index |
| `AXIL_REG_HIST_ADDR` | `8'h3C` | Histogram bin address |
| `AXIL_REG_HIST_DATA` | `8'h40` | Histogram bin read data |
| `AXIL_REG_HIST_CLEAR` | `8'h44` | Histogram clear strobe |
| `AXIL_REG_COLLISION_COUNT` | `8'h48` | Hash-collision counter read |
| `AXIL_REG_HIST_OVERFLOW` | `8'h4C` | Histogram overflow bin read |

---

### 2.2 `itch_parser_v2.sv`

AXI4-Stream ITCH 5.0 parser supporting the full order-book-relevant message set.
All field extraction is inline (no `itch_field_extract` sub-module).

**Supported message types**

| Type | ID | Body length (bytes) |
|------|----|---------------------|
| Add Order | `'A'` 0x41 | 36 |
| Add Order w/ MPID | `'F'` 0x46 | 40 |
| Order Cancel | `'X'` 0x58 | 23 |
| Order Delete | `'D'` 0x44 | 19 |
| Order Replace | `'U'` 0x55 | 35 |
| Order Executed | `'E'` 0x45 | 30 |
| Order Executed w/ Price | `'C'` 0x43 | 35 |
| Trade (non-cross) | `'P'` 0x50 | 43 |
| Any other type | — | silently drained; `fields_valid` stays 0 |

**AXI4-Stream framing:** 2-byte big-endian length prefix, then body. Beat width: 64 bits.
First beat captured in `S_IDLE`; `tdata[63:56]` = length_hi, `tdata[55:48]` = length_lo,
`tdata[47:40]` = message type (body byte 0), bytes 1–5 fill `msg_buf[0..5]`.

**FSM:** `S_IDLE → S_ACCUMULATE → S_EMIT`
- Transition `S_ACCUMULATE → S_EMIT` uses pre-increment check: `byte_cnt + 8 >= msg_len`
- `S_EMIT` registers all fields, asserts `fields_valid` for **one cycle**, returns to `S_IDLE`

**Output bus (stable when `fields_valid` pulses)**

| Signal | Width | Description |
|--------|-------|-------------|
| `msg_type` | 8 | ITCH message type byte |
| `order_ref` | 64 | Order reference number (bytes 11–18 of body) |
| `new_order_ref` | 64 | Replace new ref (type U, bytes 19–26) |
| `price` | 32 | Price in ITCH 4-decimal format |
| `shares` | 32 | Shares count (field offset varies by type) |
| `side` | 1 | 1 = bid (`'B'`), 0 = ask |
| `stock` | 64 | 8-byte ASCII ticker |
| `fields_valid` | 1 | 1-cycle pulse |

**RTL file:** `rtl/itch_parser_v2.sv`
**Dependencies:** `lliu_pkg.sv`

---

### 2.3 `symbol_filter.sv` (v2 expansion)

Expanded from 64 entries (v1) to 512 entries (v2). Distributed-RAM / FF-based CAM.

| Signal | Width | Description |
|--------|-------|-------------|
| `stock` | 64 | 8-byte ASCII ticker from `itch_parser_v2` |
| `stock_valid` | 1 | Input valid pulse |
| `watchlist_hit` | 1 | Registered match output, 1 cycle after `stock_valid` |
| `cam_wr_index` | 10 | Target CAM entry (0–511) |
| `cam_wr_data` | 64 | Key to write |
| `cam_wr_valid` | 1 | Write-enable strobe |
| `cam_wr_en_bit` | 1 | 1 = valid entry; 0 = invalidate |

**Resource estimate:** 512 × 64-bit key FFs = 32,768 FFs; ~3,500 LUTs (see MAS §2).
**RTL file:** `rtl/symbol_filter.sv`

---

### 2.4 `order_book.sv`

BRAM-backed L3 order book for 500 NASDAQ symbols. 7-state FSM.

**Storage layout**

| Memory | Size | Mapping | BRAM18 tiles |
|--------|------|---------|-------------|
| `book_mem` | 500 × 2 sides × 16 levels × 56 bits | `{price[31:0], shares[23:0]}` | ~28 |
| `ref_mem` | 131,072 entries × 128 bits | `{valid, order_ref[63:0], price[31:0], shares[23:0], side}` | ~128 |

**Hash function:** CRC-17/CAN (polynomial `0x1002D`) fold of 64-bit `order_ref` → 17-bit bucket index.
Tag comparison on every modify-type lookup; mismatch increments `collision_count`, silently drops the message.

**Phase 1 BBO simplification** (full rescan deferred to Phase 2):
- Add / Add-MPID: update BBO if new order is strictly better (bid: higher price; ask: lower price)
- Delete / Cancel / Execute: reset BBO to 0 if the deleted/reduced order was at the current BBO price
- Replace (U): treated as Delete + Add using old/new refs

**FSM states**

| State | Description |
|-------|-------------|
| `S_IDLE` | Wait for `fields_valid` pulse |
| `S_SCAN_BOOK` | Iterate price levels, find insertion point (Add/Add-MPID) |
| `S_READ_REF1` | Submit hash address to `ref_mem` (modify ops) |
| `S_READ_REF2` | Wait for BRAM read output (1-cycle BRAM latency) |
| `S_PROCESS` | Compare tag; detect collision or extract price/side/shares |
| `S_UPDATE` | Write updated entry to `book_mem`; update BBO registers |
| `S_DONE` | Assert `bbo_valid` for 1 cycle; return to `S_IDLE` |

**BBO query interface** (registered, 1-cycle FF latency):

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `bbo_query_sym` | in | 9 | Symbol index 0–499 |
| `bbo_bid_price` | out | 32 | Best bid price |
| `bbo_ask_price` | out | 32 | Best ask price |
| `bbo_bid_size` | out | 24 | Best bid shares |
| `bbo_ask_size` | out | 24 | Best ask shares |
| `bbo_valid` | out | 1 | 1-cycle BBO update pulse |
| `bbo_sym_id` | out | 9 | Symbol index of the updated BBO |
| `collision_count` | out | 32 | Cumulative hash-collision counter |
| `collision_flag` | out | 1 | 1-cycle pulse on collision |
| `book_ready` | out | 1 | FSM idle (DUT ready for next message) |

**RTL file:** `rtl/order_book.sv`
**Dependencies:** `lliu_pkg.sv`
**Verilator flag:** `-Wno-MULTIDRIVEN` (required; BRAM arrays share read/write path)

---

### 2.5 `ptp_core.sv`

Phase 1 implementation: free-running 64-bit nanosecond counter with 1-bit sync pulse.
Full PTP servo (grandmaster/slave) is deferred to a later phase.

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `ptp_sync_pulse` | out | 1 | 1-cycle pulse every 1,024 clock cycles |
| `ptp_epoch` | out | 64 | Counter value latched at previous sync boundary |
| `ptp_counter` | out | 64 | Free-running cycle counter (increments every clock) |

**Sync timing:** `ptp_sync_pulse` fires when internal `sync_cnt == 1022` (registered);
`ptp_epoch` latches `ptp_counter_r` when `sync_cnt == 1023` (one cycle after pulse).
Period = 1,024 cycles = 3.277 µs @ 312.5 MHz.

**RTL file:** `rtl/ptp_core.sv`
**Dependencies:** `lliu_pkg.sv`

---

### 2.6 `timestamp_tap.sv`

Per-event pipeline timestamp capture. One instance per tap point.

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `ptp_sync_pulse` | in | 1 | From `ptp_core` |
| `ptp_epoch` | in | 64 | From `ptp_core` |
| `tap_event` | in | 1 | Condition to capture (e.g., `fields_valid`) |
| `timestamp_out` | out | 74 | `{epoch_latch[63:0], local_sub_cnt[9:0]}` |
| `timestamp_valid` | out | 1 | 1-cycle pulse when capture occurs |

**Timestamp reconstruction:** `timestamp_ns = epoch_latch + local_sub_cnt × 3.2`
`local_sub_cnt` resets to 0 on `ptp_sync_pulse`; increments every clock otherwise.

**Phase 1 tap instances:** `t_rx_last` and `t_fields_valid`.
Full tap array (6 points) added in Phase 2.

**RTL file:** `rtl/timestamp_tap.sv`
**Dependencies:** `lliu_pkg.sv`

---

### 2.7 `latency_histogram.sv`

32-bin distributed-RAM histogram. Measures `t_end[9:0] − t_start_r[9:0]` (10-bit
unsigned subtraction). Latency ≥ 32 bins → `overflow_bin`.

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `t_start` | in | 74 | Start timestamp from `timestamp_tap` |
| `t_start_valid` | in | 1 | Start event pulse |
| `t_end` | in | 74 | End timestamp from `timestamp_tap` |
| `t_end_valid` | in | 1 | End event pulse |
| `axil_bin_addr` | in | 5 | Bin to read (0–31) |
| `axil_bin_data` | out | 32 | Bin count (combinatorial) |
| `axil_clear` | in | 1 | Synchronous clear all bins |
| `overflow_bin` | out | 32 | Overflow count (combinatorial) |

**RTL file:** `rtl/latency_histogram.sv`
**Dependencies:** `lliu_pkg.sv`

---

## 3. Retained v1 Modules (unchanged in Phase 1)

| Module | File | Role |
|--------|------|------|
| `lliu_top` | `rtl/lliu_top.sv` | System top-level (v1 integration point) |
| `feature_extractor` | `rtl/feature_extractor.sv` | 4-feature extractor (Phase 2 replaces with v2) |
| `dot_product_engine` | `rtl/dot_product_engine.sv` | 4-element BF16 dot product |
| `bfloat16_mul` | `rtl/bfloat16_mul.sv` | BF16 multiplier, DSP48E1, 2-cycle |
| `fp32_acc` | `rtl/fp32_acc.sv` | 5-stage FP32 accumulator |
| `weight_mem` | `rtl/weight_mem.sv` | 4-entry BF16 weight RAM |
| `output_buffer` | `rtl/output_buffer.sv` | Result latch |
| `axi4_lite_slave` | `rtl/axi4_lite_slave.sv` | AXI4-Lite register map (extended for v2 regs) |
| `itch_field_extract` | `rtl/itch_field_extract.sv` | Field extraction sub-module (v1 only) |
| `itch_parser` | `rtl/itch_parser.sv` | v1 Add-Order-only parser (superseded by v2) |
| `eth_axis_rx_wrap` | `rtl/eth_axis_rx_wrap.sv` | 10GbE Ethernet RX wrapper |
| `moldupp64_strip` | `rtl/moldupp64_strip.sv` | MoldUDP64 framing strip |

---

## 4. Timing Constraints

- `sys_clk`: 312.5 MHz (period = 3.2 ns), source: MMCM from GTP refclk
- `eth_clk`: 156.25 MHz, recovered from GTP
- All `sys_clk` paths targeted by `syn/constraints_lliu_top.xdc`
- v1 timing closed at 312.5 MHz (WNS +0.001 ns after PR #38)

---

## 5. Phase 2 RTL Additions (planned)

| Module | Description |
|--------|-------------|
| `feature_extractor_v2` | 32-feature extractor incorporating BBO inputs from `order_book` |
| `lliu_core` (×8) | Parameterized v1 core with `FEATURE_VEC_LEN=32`, `HIDDEN_LAYER=32` |
| `strategy_arbiter` | 8-way score comparator + threshold gate |
| `risk_check` | Price band, fat-finger, position-limit BRAM, kill switch |
| `ouch_engine` | NASDAQ OUCH 5.0 Enter Order template + hot-patch + AXI4-S serialize |
| `timestamp_tap` (×4 more) | `t_features_valid`, `t_result_valid[k]`, `t_risk_pass`, `t_ouch_last` |

See [2p0_kintex-7_MAS.md §4, §5](2p0_kintex-7_MAS.md) for full specs.
