# LLIU v2.0 — Architecture Specification
# `xc7k160tffg676-2` Kintex-7 Full-Chip Trading System

> **Status:** Planning  
> **Predecessor:** [v1 SPEC](../v1/SPEC.md) — 1,172 LUTs (1.16%), timing closed at 300 MHz, PR #38  
> **Target utilization:** 75–85% LUTs, 80–90% BRAMs, 90%+ DSP48E1s  

---

## 1. Executive Summary

v1.0 established a verified, timing-closed ITCH 5.0 inference core. v2.0 expands it into a
full trading system: stateful order book reconstruction, pre-trade risk enforcement, order
entry output, PTP timestamping and latency histograms, and a fleet of parallel inference
engines. The system is sized to consume the majority of the XC7K160T fabric and can connect
to a host CPU via PCIe Gen2 for logging and configuration.

### Key additions over v1

| Capability | v1 | v2 |
|------------|----|----|
| Market data parsing | ITCH Add Order only | Full ITCH 5.0 message set |
| Order book state | None (stateless) | L3 full-depth, top 500 symbols |
| Inference engines | 1 × LLIU | 8 × LLIU (independent weight banks) |
| Output | `dp_result_valid` flag | NASDAQ OUCH 5.0 packet out |
| Risk controls | None | Price bands, position limits, fat-finger |
| Timestamping | None | 64-bit PTP v2, per-message pipeline taps |
| Latency visibility | Cycle-count DV only | On-chip histograms (5 ns bins, P50/P99) |
| Host interface | None | PCIe Gen2 ×4, DMA snapshot engine |

---

## 2. Chip-Level Resource Budget

Device: `xc7k160tffg676-2` (Kintex-7, -2 speed grade)

| Resource | Available | v1 Used | v2 Budget | v2 Util% |
|----------|-----------|---------|-----------|----------|
| Slice LUTs | 101,400 | 1,172 | ~78,000 | ~77% |
| Slice Registers | 202,800 | 932 | ~40,000 | ~20% |
| DSP48E1 | 600 | 1 | ~550 | ~92% |
| Block RAM Tile | 325 | 0 | ~280 | ~86% |
| GTP Transceivers | 8 | 0 | 8 | 100% |
| BUFG | 32 | 1 | ~12 | ~38% |

### LUT allocation by subsystem

| Subsystem | Est. LUTs | Notes |
|-----------|-----------|-------|
| v1 core (retained, 8× replicated) | ~9,400 | 8 × 1,172 |
| `order_book` control & arbitration | ~8,000 | Address decode, update FSMs, collision avoidance |
| OUCH packet engine | ~3,000 | Template buffer + hot-patch mux |
| Pre-trade risk module | ~4,000 | Price band comparators, position accumulators |
| PTP core (IEEE 1588 v2) | ~4,000 | Timestamper, servo, syntonization |
| Latency histogram array | ~2,500 | 8 × 32-bin × 32-bit counters |
| PCIe DMA engine (hard IP wrapper + CDC) | ~18,000 | Xilinx PCIe IP + DMA descriptor logic |
| Multi-strategy arbiter | ~1,500 | 8-way priority + round-robin |
| Expanded symbol filter (512 entries) | ~3,500 | LUT-CAM, was 64 entries |
| Glue / CDC / miscellaneous | ~3,000 | Sync FIFOs, resets, status registers |
| **Total** | **~57,000** | **~56%** — see §2.1 |

> **§2.1 — Gap to 75–85%:** The LUT estimate sits at ~56% with the subsystems above. To reach
> the 75–85% target, the primary lever is ML model depth inside each LLIU core. Increasing
> the feature vector length from 4 to 32 and the hidden layer to 32 neurons expands
> `dot_product_engine` + `fp32_acc` resource usage by ~8× per core, adding ~15–20K LUTs.
> This is the recommended path and is described in §4.1.

> **§2.2 — DSP Column Congestion & Pblock Strategy:** The XC7K160T has DSP48E1 columns at
> fixed X-coordinates. At 92% DSP utilization (550/600), routing paths that snake from a
> DSP output into an adjacent BRAM column create extreme local congestion. Without placement
> constraints, Vivado scatters DSP blocks organically across the die and the router cannot
> close 3.2 ns timing.
>
> **Mitigation required from Run 1 of v2 P&R:** Assign explicit `PBLOCK` constraints that
> co-locate each `lliu_core` instance — its DSP48E1 MAC array, associated LUTs, and FFs —
> within a single clock region. `order_book` BRAMs should be placed in an adjacent column
> stripe so the BBO→feature path crosses at most one clock region boundary. The `ptp_core`
> 1-bit sync pulse is the only cross-die signal permitted to exit a Pblock without a
> registered hold buffer. **Do not rely on post-route `phys_opt_design` as the sole timing
> closure tool — the v1 margin (+0.001 ns at 300 MHz) does not carry over to a 3.2 ns budget
> at 312.5 MHz.**

---

## 3. System Architecture

### 3.1 Top-Level Block Diagram

```
10GbE RX (GTP)
      │
   eth_axis_rx_wrap
      │    AXI4-S 64-bit @ 156.25 MHz
   moldupp64_strip
      │    AXI4-S 64-bit @ 156.25 MHz
      │
   ┌──┴──────────────────────────────────────────────────────────┐
   │                        lliu_top_v2                          │
   │                                                             │
   │  itch_parser_v2 ─────► order_book ─┐                       │
   │      │ (fields_valid,               │                       │
   │      │  all msg types)              ▼                       │
   │      │                      symbol_filter                   │
   │      │                             │ watchlist_hit          │
   │      │                             ▼                        │
   │      └─────────────────► feature_extractor_v2              │
   │                                    │ features[0..N]         │
   │                                    ▼                        │
   │                          strategy_arbiter ◄── 8× lliu_core │
   │                                    │ winner_core            │
   │                                    ▼                        │
   │                          risk_check ──── BLOCKED            │
   │                                    │ risk_pass              │
   │                                    ▼                        │
   │                          ouch_engine ──────────────────────►│ 10GbE TX (GTP)
   │                                                             │
   │  ptp_core ──► timestamp_tap ──► latency_histogram           │
   │                                                             │
   │  pcie_dma_engine ◄──────────────── snapshot_mux             │
   │                                                             │
   └─────────────────────────────────────────────────────────────┘
          │ AXI4-Lite (PCIe BAR0)
       Host CPU (config, weight load, histogram readout)
```

### 3.2 Clock Domains

| Domain | Frequency | Source | Used By |
|--------|-----------|--------|---------|
| `sys_clk` | 312.5 MHz (156.25 × 2) | MMCM from GTP refclk | All inference and book logic |
| `eth_clk` | 156.25 MHz | GTP recovered clock | Ethernet MAC RX/TX |
| `pcie_clk` | 250 MHz (≥62.5 MHz for TL) | PCIe hard IP | DMA engine |
| `ptp_ref` | 125 MHz (or 25 MHz) | External TCXO / SMA | PTP servo |

All domain crossings use synchronous Gray-coded FIFOs or two-flop synchronizers. No
combinational paths cross domains.

---

## 4. Module Specifications

### 4.1 `lliu_core` (replicated ×8)

Each `lliu_core` is the v1 LLIU — `feature_extractor` → `dot_product_engine` →
`output_buffer` — parameterized for larger models.

| Parameter | v1 value | v2 default | Max |
|-----------|----------|------------|-----|
| `FEATURE_VEC_LEN` | 4 | 32 | 128 |
| `HIDDEN_LAYER` | 0 (linear) | 32 | 256 |
| Weight data width | bfloat16 | bfloat16 | — |
| Accumulator width | float32 | float32 | — |

With `FEATURE_VEC_LEN=32` and `HIDDEN_LAYER=32`, each core uses approximately:
- 18 DSP48E1 (32-wide `bfloat16_mul` × 1 cycle drain pipeline)
- ~4,400 LUTs
- ~1,200 FFs
- 0 BRAMs (weight ROM synthesized to distributed RAM for DEPTH ≤ 256)

8 cores × 18 DSPs = 144 DSP48E1 for inference alone (24% of 600 available).

**Interface (per core)**

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `features[FEATURE_VEC_LEN]` | in | 16×N | bfloat16 feature vector |
| `features_valid` | in | 1 | Pulse: feature vector ready |
| `weight_wen` | in | 1 | AXI4-Lite weight write enable |
| `weight_waddr` | in | 8 | Weight address |
| `weight_wdata` | in | 16 | bfloat16 weight data |
| `result` | out | 32 | float32 inference score |
| `result_valid` | out | 1 | Pulse: result ready |
| `clk`, `rst` | in | 1 | 312.5 MHz, synchronous active-high |

### 4.2 `itch_parser_v2`

Extends v1 `itch_parser` to handle the full ITCH 5.0 message set needed for order book
reconstruction.

**Supported message types**

| ITCH Type | ID | Purpose |
|----------|-----|---------|
| Add Order | `'A'` | New resting order (v1 only type) |
| Add Order w/ MPID | `'F'` | Same as A with market participant |
| Order Cancel | `'X'` | Partial cancel — reduce shares |
| Order Delete | `'D'` | Full cancel — remove from book |
| Order Replace | `'U'` | Atomic cancel + re-add at new price/qty |
| Order Executed | `'E'` | Trade execution (without price) |
| Order Executed w/ Price | `'C'` | Trade execution at a specific price |
| Trade (non-cross) | `'P'` | Sweep trade not tied to a resting order |

**Parser output bus (fields_valid pulse)**

| Signal | Width | Description |
|--------|-------|-------------|
| `msg_type` | 8 | ITCH message type byte |
| `order_ref` | 64 | Order reference number |
| `new_order_ref` | 64 | Replace: new reference (type U only) |
| `price` | 32 | Price (4 decimal places, ITCH format) |
| `shares` | 32 | Shares count |
| `side` | 1 | 1=Buy, 0=Sell |
| `stock` | 64 | 8-byte ASCII ticker |
| `fields_valid` | 1 | Pulse: all fields stable |

### 4.3 `order_book`

L3 full-depth order book for the top 500 NASDAQ symbols. Stores resting orders as price
levels with aggregated share counts.

**Data model**

- 500 symbols × 2 sides × 16 price levels = 16,000 entries
- Each entry: `{price[31:0], shares[23:0]}` = 56 bits
- Total storage: 16,000 × 56 bits ≈ 110 KB → 14 RAMB18E1 tiles (or 7 RAMB36E1 tiles)
- Order reference map (for delete/cancel/replace): separate hash table
  - 128K entries × `{order_ref[63:0], price[31:0], shares[23:0], side[0]}` = 120 bits
  - ≈ 1.87 MB → 105 RAMB18E1 tiles

> **BRAM budget note:** The order ref hash table dominates chip BRAM. 105 + 14 = 119 tiles
> out of 325 available (37%). This leaves 206 tiles for PCIe DMA ring buffers (~30 tiles),
> weight storage for 8 cores (@1 tile each = 8 tiles), and headroom. Total BRAM: ~160 tiles
> (49%). To reach 80–86% BRAM utilization, increase the reference map to 512K entries or
> widen the price level array to 32 levels per side.
>
> **BRAM cascade pipeline:** The hash table entry is 120 bits wide. Vivado builds this width
> from cascaded RAMB18E1 tiles, which adds a "cascade delay" on the read output data path.
> Manually pipeline the BRAM read output with an additional `always_ff` stage (2-cycle total
> read latency) to give Vivado placement freedom and ensure 312.5 MHz timing closure. **This
> 2-cycle latency is already accounted for in the `risk_check` lookup budget (§4.6).**

**Memory collision avoidance**

The order book uses a dual-port BRAM with an explicit read-before-write arbitration FSM.
Simultaneous add and delete to the same price level are serialized: delete wins; add is
re-queued in a 4-entry shadow FIFO and committed on the next idle cycle.

**Hash collision handling**

The order reference hash table uses a 17-bit CRC-fold of the 64-bit `order_ref` field,
yielding 128K (2¹⁷) hash buckets. In HFT, "Collision = Latency": a secondary probe costs
one full BRAM read cycle and breaks the BBO update throughput guarantee.

Strategy: every bucket stores the full 64-bit `order_ref` as a tag alongside the payload.
On delete/cancel/replace lookup the hardware compares the retrieved tag against the incoming
`order_ref`. On mismatch:
- `collision_flag` is asserted for one cycle
- The incoming message is silently dropped (the resting order remains in the book to expire
  at its natural time-in-force)
- An AXI4-Lite `COLLISION_COUNT` register is incremented
- If `COLLISION_COUNT` crosses a software-configurable threshold, `risk_check` auto-asserts
  the kill switch until the host explicitly resets the counter

> **Phase 1 DV must include "Hash Collision Stress":** construct two `order_ref` values that
> fold to the same CRC17 bucket and verify that `COLLISION_COUNT` increments, the `BBO`
> output remains accurate for the non-colliding side of the book, and the kill switch asserts
> when the threshold is reached (see §7).

**Interfaces**

| Signal | Direction | Width | Description |
|--------|-----------|-------|-------------|
| `msg_type` | in | 8 | From itch_parser_v2 |
| `order_ref` | in | 64 | |
| `new_order_ref` | in | 64 | For type U replace |
| `price` | in | 32 | |
| `shares` | in | 32 | |
| `side` | in | 1 | |
| `stock` | in | 64 | |
| `fields_valid` | in | 1 | |
| `bbo_bid_price[S]` | out | 32 | Best bid price for symbol S |
| `bbo_ask_price[S]` | out | 32 | Best ask price for symbol S |
| `bbo_bid_size[S]` | out | 24 | Best bid shares |
| `bbo_ask_size[S]` | out | 24 | Best ask shares |
| `bbo_valid[S]` | out | 1 | BBO update pulse |

The BBO outputs are registered and registered again before being used by `risk_check` and
`feature_extractor_v2` — no combinational path from BRAM output to downstream logic.

### 4.4 `feature_extractor_v2`

Extends v1 `feature_extractor` from 4 features to N (default 32), incorporating BBO data
from `order_book`.

**Feature vector (32 features, bfloat16)**

| Index | Feature | Source |
|-------|---------|--------|
| 0 | Price delta (last vs current) | itch_parser_v2 |
| 1 | Side encoding (+1/−1) | itch_parser_v2 |
| 2 | Order flow imbalance | itch_parser_v2 (running counter) |
| 3 | Normalized price | itch_parser_v2 |
| 4 | BBO bid price | order_book |
| 5 | BBO ask price | order_book |
| 6 | BBO bid size | order_book |
| 7 | BBO ask size | order_book |
| 8 | Bid-ask spread | order_book (ask−bid) |
| 9 | Mid price | order_book (bid+ask)/2 |
| 10 | Order size vs BBO size (bid) | itch_parser_v2 + order_book |
| 11 | Order size vs BBO size (ask) | itch_parser_v2 + order_book |
| 12–15 | L2 bid levels 1–4 (price) | order_book |
| 16–19 | L2 ask levels 1–4 (price) | order_book |
| 20–23 | L2 bid levels 1–4 (size) | order_book |
| 24–27 | L2 ask levels 1–4 (size) | order_book |
| 28 | Rolling buy volume (window=8) | Running accumulator |
| 29 | Rolling sell volume (window=8) | Running accumulator |
| 30 | VWAP (volume-weighted avg price) | Running accumulator |
| 31 | Message arrival rate (msgs/window) | Timestamp counter |

**Pipeline:** 4 stages (integer arithmetic, magnitude, normalize-high, normalize-low). Latency: 4 cycles.

### 4.5 `strategy_arbiter`

Collects `result_valid` + `result` from 8 `lliu_core` instances and selects which, if any,
triggers an order entry attempt.

- Each core produces a float32 score. A score above a configurable threshold `score_thresh`
  is a "signal."
- If multiple cores signal in the same cycle, the core with the highest score wins
  (registered comparator tree, 1-cycle latency).
- If no core signals, arbiter passes idle to `risk_check`.
- The winning core index and score are forwarded to `risk_check`.

**Resource estimate:** ~20 LUTs × 8 comparators + priority encoder + registers ≈ 200 LUTs.

### 4.6 `risk_check`

Pre-trade risk enforcement module. Sits between `strategy_arbiter` and `ouch_engine`. Any
failing check suppresses the order with a registered `risk_blocked` pulse and increments a
per-rule violation counter readable via AXI4-Lite.

**Rules**

| Rule | Mechanism | Latency |
|------|-----------|---------|
| Price band | Registered comparator: `|proposed_price − bbo_mid| > BAND_BPS × bbo_mid` | 1 cy |
| Fat finger |`proposed_shares > MAX_QTY[stock]` (BRAM lookup) | 2 cy |
| Position limit | BRAM accumulator net shares per symbol; reject if `net_shares + proposed_shares > LIMIT` | 2 cy |
| Kill switch | AXI4-Lite write-one-to-set register; gates all orders when asserted | 0 cy (combinational) |

The three checks run in parallel; the combined result is ANDed and registered. Total latency:
2 cycles from `strategy_arbiter` output to `risk_pass` or `risk_blocked`.

**Position accumulator BRAM:** 500 symbols × 24-bit net shares = ~12 KB → 2 RAMB18E1 tiles.

### 4.7 `ouch_engine`

Generates NASDAQ OUCH 5.0 `Enter Order` packets using a template buffer strategy. 90% of
each packet is pre-computed and stored in a 128-entry BRAM; only price and quantity are
"hot-patched" from `risk_check` output before the packet is serialized and handed to the
10GbE TX MAC.

**Template buffer:** 128 × 64 bytes = 8 KB → 1 RAMB36E1.

**Packet format (OUCH Enter Order, 48 bytes)**

| Field | Bytes | Pre-computed? |
|-------|-------|---------------|
| Packet type `'O'` | 1 | Yes |
| Token (order ID) | 14 | Yes (auto-increment) |
| Buy/Sell indicator | 1 | Yes (per core strategy) |
| Shares | 4 | **Hot-patched** |
| Stock | 8 | Yes (per watchlist entry) |
| Price | 4 | **Hot-patched** |
| Time in force | 4 | Yes (`IOC` = `0x00000000`) |
| Firm | 4 | Yes |
| Display | 1 | Yes |
| Capacity | 1 | Yes |
| ISO intermarket sweep | 1 | Yes |
| Min quantity | 4 | Yes |
| Cross type | 1 | Yes |

**Pipeline:** 3 stages (template read, hot-patch, AXI4-S serialize). Latency: 3 cycles.

**Direct-to-wire discipline:** `ouch_engine` must be the last stage before the GT
transceivers. No FIFO, LUT, or register may exist between the hot-patch output and the
10GbE TX MAC AXI4-S input. Every added stage compounds directly onto tick-to-trade latency.

**Backpressure soft-kill:** If the 10GbE TX MAC asserts backpressure (`tx_axis_tready`
deasserted for more than 64 consecutive cycles), `ouch_engine` propagates a `tx_overflow`
pulse to `risk_check`, which auto-asserts the kill switch. This prevents stale, delayed
orders from reaching the exchange when the TX path is congested. The kill switch
self-clears once `tx_axis_tready` remains asserted for ≥ 256 consecutive cycles (backlog
drained). This behavior mirrors the hash-collision auto-kill described in §4.3.

### 4.8 `ptp_core`

IEEE 1588-2019 (PTP v2) grandmaster/slave implementation targeting sub-100 ns synchronization
accuracy with a GPS-disciplined clock source or a dedicated TCXO on the board.

**Sub-modules**

| Module | Description |
|--------|-------------|
| `ptp_rx` | Parses Sync, Follow_Up, Delay_Req, Delay_Resp frames from Ethernet stream |
| `ptp_tx` | Inserts hardware timestamps into outgoing PTP frames |
| `ptp_servo` | PI servo loop, adjusts 64-bit free-running counter frequency |
| `ptp_counter` | 64-bit nanosecond counter, slave to servo |

**PTP distribution — fanout mitigation:** At 312.5 MHz on an ~80% utilized device, routing
a raw 64-bit counter bus to all 14 sink points (6 pipeline taps + 8 per-core
`t_result_valid`) creates ~896 high-speed sink-to-source routing segments competing for
mid-fabric resources — a textbook high-fanout failure at 3.2 ns. Instead, `ptp_core`
outputs a single 1-bit **`ptp_sync_pulse`** every 1,024 clock cycles (≈ 3.28 µs).
Simultaneously it writes the current 64-bit epoch value into a registered broadcast bus,
but this broadcast fires only once per 3.28 µs so net switching activity is negligible
and Vivado's fanout-replication heuristics handle it without congestion. Each
`timestamp_tap` consumes the 1-bit pulse and the infrequent epoch broadcast as described
in §4.9. This reduces the continuous cross-die high-speed routing requirement from 64 wires
to **1 wire at 1/1,024 activity factor**.

### 4.9 `timestamp_tap` and `latency_histogram`

Each `timestamp_tap` instance comprises two registers:
1. A 10-bit **`local_sub_cnt`** that increments every clock cycle and resets to zero on
   `ptp_sync_pulse`.
2. A 64-bit **`epoch_latch`** that captures the `ptp_core` epoch broadcast on each
   `ptp_sync_pulse`.

When the tap event fires, the module records `{epoch_latch, local_sub_cnt}` into a 74-bit
snapshot register consumed by `latency_histogram`. Reconstructed timestamp (nanoseconds):

`timestamp_ns = epoch_latch + local_sub_cnt × 3.2`

For latency deltas that span a sync-pulse boundary the histogram accumulator uses the full
74-bit reconstructed values; there is no wrap ambiguity. Maximum sub-counter error within
a single window: 1,023 × 3.2 ns ≈ 3.3 µs — negligible against histogram bin width (5 ns
per bin × 32 bins = 160 ns range). This architecture requires **no continuous cross-die
routing** for the timestamp bus; only the 1-bit `ptp_sync_pulse` and the 64-bit epoch
(switching at 1/1,024 rate) propagate outside `ptp_core`. Tap points:

| Tap name | Event condition |
|----------|-----------------|
| `t_rx_last` | `s_axis_tvalid && s_axis_tready && s_axis_tlast` in `lliu_top` |
| `t_fields_valid` | `fields_valid` in `itch_parser_v2` |
| `t_features_valid` | `features_valid` in `feature_extractor_v2` |
| `t_result_valid[k]` | `result_valid` of core k |
| `t_risk_pass` | `risk_pass` in `risk_check` |
| `t_ouch_last` | Last byte of OUCH packet serialized |

**`latency_histogram`** computes `t_risk_pass − t_rx_last` (tick-to-trade delta) and
increments one of 32 bins. Bin width: 5 ns. Range: 0–160 ns. Overflow bin for > 160 ns.

Each histogram is a 32-entry × 32-bit counter array (1K bits), synthesized to distributed
RAM. 8 equal cores → 8 independent histograms. AXI4-Lite read clears each bin. Software
can accumulate P50/P99 statistics.

**Resource estimate:** 8 histograms × (comparator tree + counter mux) ≈ 2,400 LUTs.

### 4.10 `pcie_dma_engine`

PCIe Gen2 ×4 DMA engine for snapshot delivery to the host CPU.

- Uses the Xilinx `pcie_7x_0` hard IP core (in the PCIe hard block within the XC7K160T).
- AXI4-MM master DMA descriptor engine: ring buffer of 256 descriptors.
- Every 10 ms a snapshot of the order book BBO array (500 × 2 sides × 8 bytes = 8 KB) is
  DMA'd to a pinned host buffer.

> **PCIe lane note:** The XC7K160T `ffg676` package provides 4 GTP transceivers in bank 116
> (MGTXRXN/P 0–3), which maps to PCIe ×4. PCIe ×8 would require 8 GTPs; only ×4 are
> available on this package. Confirm against the `xc7k160tffg676-2` I/O planner before
> committing constraints.

**AXI4-Lite registers (BAR0)**

| Offset | Register | Description |
|--------|----------|-------------|
| 0x000 | `CTRL` | Bit 0: DMA enable; Bit 1: histogram clear; Bit 2: kill switch |
| 0x004 | `STATUS` | Bit 0: DMA busy; Bit 1: risk_blocked latched |
| 0x100–0x17C | `HIST_k[0..31]` | Histogram bins for core k (k = 0..7, stride 0x80) |
| 0x200–0x2FF | `WEIGHT_k[addr]` | Weight write port for core k |
| 0x400 | `BAND_BPS` | Price band in basis points |
| 0x404 | `MAX_QTY` | Fat-finger max quantity |
| 0x408 | `SCORE_THRESH` | Strategy fire threshold (float32) |

---

## 5. Execution Phases

### Phase ordering rationale

PTP (Phase 3 in the rough draft) is moved to Phase 1 here. You cannot validate order-entry
latency, prove jitter, or correlate timestamps across pipeline stages without the measurement
infrastructure in place first. Build measurement → then output path → then scaling.

### Phase 1: Order Book + PTP Foundation (Measurement Infrastructure)

**Goal:** Stateful L3 order book for 500 symbols + 64-bit PTP timestamps at all tap points.
No trading output yet.

**Deliverables**

- `itch_parser_v2` supporting all 8 ITCH message types above
- `order_book` module: BRAM-backed L3 book, dual-port collision avoidance, BBO outputs
- `ptp_core`: receive-side timestamp injection; 64-bit free-running nanosecond counter
- `timestamp_tap` at `t_rx_last` and `t_fields_valid`
- `latency_histogram` (even if only 1 tap delta is meaningful initially)
- Expanded `symbol_filter`: 512-entry LUT-CAM (from current 64 entries)
- AXI4-Lite readable histogram bins

**Key verification goals**
- Order book: insert 10K add orders, 5K deletes, 2K replaces — verify BBO at each step
- Dual-port collision: simultaneous add+delete on same price level → correct serialization
- **Hash collision stress:** construct two `order_ref` values with identical CRC17 fold;
  verify `COLLISION_COUNT` increments, `BBO` remains accurate for the non-colliding side,
  kill switch asserts at the configured threshold (see §4.3)
- PTP counter: monotonically increasing, wraps correctly at 64-bit boundary
- **PTP sync accuracy:** verify `local_sub_cnt` resets on `ptp_sync_pulse`; verify
  reconstructed timestamp matches golden counter; confirm no wrap ambiguity at the
  1,024-cycle sync boundary

**Estimated timeline:** 4–6 weeks

### Phase 2: OUCH Engine + Risk Controls (Output Path)

**Goal:** Generate compliant OUCH 5.0 `Enter Order` packets from inference signals, with all
three risk checks enforced.

**Deliverables**

- `feature_extractor_v2` with 32 features
- 8× `lliu_core` with `FEATURE_VEC_LEN=32`, `HIDDEN_LAYER=32`
- `strategy_arbiter`
- `risk_check`: price band, fat-finger, position accumulator, kill switch
- `ouch_engine`: template buffer, hot-patch, AXI4-S serialize to 10GbE TX MAC
- Full `timestamp_tap` array (all 6 tap points)
- Per-core latency histograms

**Key verification goals**
- OUCH compliance: generated packets parse cleanly against the NASDAQ OUCH 5.0 spec
- Risk: fuzz price/quantity across all three rule boundaries; verify block rate = 100%
  for out-of-band inputs
- Tick-to-trade P99 < 100 ns (verified via histogram readout in simulation)

**Estimated timeline:** 6–8 weeks

### Phase 3: PCIe DMA + Host Integration (System Layer)

**Goal:** Connect the FPGA to a Linux host via PCIe; deliver periodic order book snapshots.

**Deliverables**

- `pcie_dma_engine` wrapping Xilinx PCIe Gen2 ×4 hard IP
- RIFFA-style or custom descriptor-ring DMA: 8 KB BBO snapshot every 10 ms
- Linux kernel driver stub (optional — a Vivado ILA capture is an acceptable substitute
  for demonstrating DMA in simulation)

**Estimated timeline:** 4–6 weeks

---

## 6. Timing Targets (312.5 MHz `sys_clk`, period = 3.2 ns)

| Path | Budget | v1 achievement |
|------|--------|---------------|
| `s_axis_tlast` → `dp_result_valid` (per core, with 32 features) | < 50 cycles | 18 cy ✅ |
| `fields_valid` → `bbo_valid` (order book update) | < 4 cycles | N/A (new) |
| `bbo_valid` → `features_valid` (feature extractor) | < 6 cycles | N/A (new) |
| `result_valid` → `risk_pass` | < 3 cycles | N/A (new) |
| `risk_pass` → OUCH last byte | < 8 cycles | N/A (new) |
| **Full tick-to-trade: `s_axis_tlast` → OUCH last byte** | **< 100 cycles (320 ns)** | N/A (new) |

### 6.1 CDC Formal Verification

After each P&R run, Vivado's **Report CDC** (`report_cdc -verbose`) must pass with zero
unresolved crossings before the run is considered clean. Crossings to verify:

| From domain | To domain | Expected synchronizer |
|-------------|-----------|----------------------|
| `eth_clk` (156.25 MHz) | `sys_clk` (312.5 MHz) | Gray-coded FIFO (AXI4-S path, `moldupp64_strip` output) |
| `sys_clk` (312.5 MHz) | `eth_clk` (156.25 MHz) | Gray-coded FIFO (OUCH TX packet, `ouch_engine` → MAC) |
| `pcie_clk` (250 MHz) | `sys_clk` (312.5 MHz) | Two-flop synchronizer (AXI4-Lite register writes) |
| `sys_clk` (312.5 MHz) | `pcie_clk` (250 MHz) | Two-flop synchronizer (status/histogram reads) |
| `ptp_ref` (125 MHz) | `sys_clk` (312.5 MHz) | Two-flop synchronizer (`ptp_servo` correction word) |

Any `report_cdc` warning classified as **CRITICAL** or **HIGH** is a hard stop — the run is
not accepted as a timing-closure candidate until the crossing is resolved with a proper
synchronizer or constrained with a verified `set_false_path`. This check runs in CI
alongside the timing summary extraction step.

---

## 7. Verification Strategy

v2 retains independent dual-methodology verification (cocotb + UVM). The order book and risk
module are the primary new DV targets — they have complex state-machine interactions that
benefit from constrained-random stimulus.

### New verification components needed

| Component | TB | Priority |
|-----------|-----|---------|
| `order_book` scoreboard (reference model in Python) | cocotb | High |
| OUCH packet checker (parse and validate generated packets) | cocotb | High |
| Risk fuzz driver (randomize price/qty across rule boundaries) | UVM | High |
| PTP counter checker (monotonicity, frequency accuracy) | cocotb | Medium |
| PCIe DMA sequence (write descriptor, poll completion) | UVM | Low |
| Hash collision stress (CRC17 fold, BBO accuracy, kill-switch threshold) | cocotb | High |
| PTP sub-counter sync (reset on pulse, no wrap ambiguity, drift < 1 bin over 10⁶ cycles) | cocotb | Medium |
| OUCH TX backpressure soft-kill (deassert `tx_axis_tready` > 64 cy, verify kill switch) | UVM | Medium |

### Golden model update

`tb/cocotb/models/golden_model.py` must be extended with:
- Full ITCH message type handling (decode all 8 types)
- L3 order book reference implementation in Python (including CRC17 hash function and
  collision detection mirror)
- OUCH packet generator (for scoreboard comparison)
- PTP reconstructed timestamp model (`epoch_latch + local_sub_cnt × 3.2 ns`)
- OUCH backpressure / soft-kill model (TX FIFO depth tracking, kill-switch threshold logic)

---

## 8. Open Questions / Decisions Required

| # | Question | Default assumption |
|---|----------|--------------------|
| 1 | Target board for PCIe? (KC705, custom, or simulation only) | Simulation only for v2 |
| 2 | Number of LLIU cores: 8 or 16? | 8 (reach ~77% LUT; 16 would need wider model) |
| 3 | OUCH session management (TCP vs MOLDUDP64)? | MOLDUDP64 output (simpler, matches RX path) |
| 4 | PTP grandmaster source: external TCXO on SMA, or simulated? | Simulated in DV; real in syn |
| 5 | PCIe kernel driver: implement or ILA capture only? | ILA capture only for v2 |
| 6 | Kill switch register: write-once or AXI4-Lite clearable? | AXI4-Lite clearable; also auto-asserted by TX backpressure overflow (self-clears after 256 idle cycles) and hash collision rate threshold (host-reset required) |
