# LLIU System Architecture — v2.0 (Synthesized)

> **Synthesized target**: Kintex-7 xc7k160tffg676-2 · Vivado ML Standard · 312.5 MHz  
> **v2 per-module specs**: [kc705_top](kc705_top.md) · [lliu_top_v2](lliu_top_v2.md) · [itch_parser_v2](itch_parser_v2.md) · [order_book](order_book.md) · [symbol_filter](symbol_filter.md) · [feature_extractor_v2](feature_extractor_v2.md) · [lliu_core](lliu_core.md) · [strategy_arbiter](strategy_arbiter.md) · [risk_check](risk_check.md) · [ouch_engine](ouch_engine.md) · [ptp_core](ptp_core.md) · [timestamp_tap](timestamp_tap.md) · [latency_histogram](latency_histogram.md) · [snapshot_mux](snapshot_mux.md) · [pcie_dma_engine](pcie_dma_engine.md) · [eth_axis_rx_wrap](eth_axis_rx_wrap.md) · [moldupp64_strip](moldupp64_strip.md)  
> **v1 per-module specs (legacy)**: [lliu_top](lliu_top.md) · [itch_parser](itch_parser.md) · [itch_field_extract](itch_field_extract.md) · [feature_extractor](feature_extractor.md) · [dot_product_engine](dot_product_engine.md) · [bfloat16_mul](bfloat16_mul.md) · [fp32_acc](fp32_acc.md) · [weight_mem](weight_mem.md) · [axi4_lite_slave](axi4_lite_slave.md) · [output_buffer](output_buffer.md)

## 1. Purpose

The Low-Latency Inference Unit (LLIU) v2.0 is a full end-to-end HFT inference engine targeting the Kintex-7 xc7k160tffg676-2 FPGA on the KC705 evaluation board. It ingests a live NASDAQ ITCH 5.0 byte stream delivered over 10GbE, maintains a real-time order book for up to 64 symbols, filters activity to a configurable watchlist, extracts a 32-element bfloat16 feature vector per order event, runs eight independent inference cores in parallel, arbitrates the best scoring core, applies pre-trade risk checks, and emits an OUCH 5.0 Enter Order packet over 10GbE — all in a deterministic, fully pipelined, single-clock datapath at 312.5 MHz.

## 2. Module Hierarchy

```
kc705_top                             (KC705 board-level integration)
├── eth_axis_rx_wrap                  (156.25 MHz — drop-on-full MAC RX wrapper)
├── [udp_complete_64]                 (Forencich IP: Ethernet/IP/UDP decap)
├── moldupp64_strip                   (156.25 MHz — MoldUDP64 header stripper + seq-num validator)
├── [axis_async_fifo]                 (Forencich IP: CDC 156.25 MHz → 312.5 MHz)
├── pcie_dma_engine                   (PCIe Gen2 ×4 DMA engine for BBO snapshot)
└── lliu_top_v2                       (312.5 MHz — inference core)
    ├── ptp_core                      (free-running 64-bit counter; sync pulse every 1024 cycles)
    ├── itch_parser_v2                (AXI4-S multi-type ITCH 5.0 parser, 3-state FSM)
    ├── timestamp_tap [rx_last]       (74-bit {epoch,sub_cnt} on AXI4-S last beat)
    ├── timestamp_tap [fields_valid]  (74-bit capture on parser fields_valid)
    ├── order_book                    (CRC-17 hash table, BBO + L2 for 64 symbols, 7-state FSM)
    ├── symbol_filter                 (64-entry LUT-CAM, 3-cycle registered latency)
    ├── [3-cycle field-alignment delay] (aligns parser fields with watchlist_hit)
    ├── feature_extractor_v2          (32-feature, 4-stage pipeline, bfloat16 output)
    ├── timestamp_tap [feat_ext]      (74-bit capture on features_valid)
    ├── lliu_core × 8                 (weight_mem + dot_product_engine + output_buffer, ~41 cy)
    ├── timestamp_tap [result]        (74-bit capture on core_result_valid[0])
    ├── strategy_arbiter              (3-level combinational tournament tree, 1 cy registered)
    ├── [hold registers]              (price, sym_id, side, ref_price latched at feat_ext_fv)
    ├── risk_check                    (band + fat-finger + position BRAM, 2-cycle pipeline)
    ├── timestamp_tap [risk_pass]     (74-bit capture on risk_pass)
    ├── ouch_engine                   (BRAM template × 4, IDLE→FETCH→LOAD→SEND FSM)
    ├── timestamp_tap [ouch_last]     (74-bit capture on m_axis last beat)
    ├── latency_histogram             (32-bin cycle-count, t_start=rx_last, t_end=risk_pass)
    ├── snapshot_mux                  (BBO shadow BRAM, snap stream to pcie_dma_engine)
    └── [AXI4-Lite inline decode]     (12-bit address, no sub-module; drives all sub-module CSRs)
```

Within each `lliu_core` instance (× 8, all identical):
```
lliu_core
├── weight_mem           (32 × bfloat16 LUTRAM, per-core AXI4-Lite write port)
├── dot_product_engine   (bfloat16 MAC pipeline)
│   ├── bfloat16_mul     (2-cycle DSP48E1 multiply, produces float32 product)
│   └── fp32_acc         (5-stage fp32 accumulator)
└── output_buffer        (stable float32 readout latch)
```

## 3. Clock Domains

| Domain | Clock signal | Frequency | Source | Consumers |
|--------|-------------|-----------|--------|-----------|
| `sys_clk` | `clk` (inside `lliu_top_v2`) | 312.5 MHz | MMCM from 200 MHz board oscillator | all `lliu_top_v2` submodules, `pcie_dma_engine` sys_clk port |
| `net_clk` | `clk_156` (inside `kc705_top`) | 156.25 MHz | GTX recovered from SFP+ MGT reference | `eth_axis_rx_wrap`, `udp_complete_64`, `moldupp64_strip`, async FIFO write side |

### 3.1 CDC Crossing

One clock-domain crossing exists in the board-level path:

- **Write side** (156.25 MHz): `moldupp64_strip` → `axis_async_fifo`
- **Read side** (312.5 MHz): `axis_async_fifo` → `itch_parser_v2` (`s_axis_*`)

The Forencich `axis_async_fifo` (instantiated inside `kc705_top`, not in `rtl/`) handles all synchronisation. No other CDCs exist in the datapath.

A second CDC (two-flop pulse stretch + sync) exists between `pcie_dma_engine` and `snapshot_mux` for the `snap_req` / `snap_done` handshake.

### 3.2 Single-Domain Core

All modules inside `lliu_top_v2` operate exclusively in the `sys_clk` (312.5 MHz) domain. There are no internal CDCs.

## 4. Reset Strategy

| Signal | Definition | Consumers |
|--------|-----------|-----------|
| `rst` | Active-high synchronous reset (sys_clk domain) | all `lliu_top_v2` submodules |

All registers reset to defined zero / idle states. BRAM contents (`weight_mem`, `ouch_engine` template BRAMs, `snapshot_mux` shadow BRAMs) are **not** cleared on reset; the host must initialise them via AXI4-Lite before issuing inference commands.

## 5. Pipeline Structure and Latency

### 5.1 Stage-by-Stage Breakdown (VEC_LEN = 32, NUM_CORES = 8)

```
10GbE RX — eth_axis_rx_wrap → moldupp64_strip → axis_async_fifo (CDC)
[156.25 MHz]                                             ↓
                                               s_axis into lliu_top_v2
                                             [312.5 MHz domain begins]
        │
        │  itch_parser_v2 FSM: IDLE → ACCUMULATE → EMIT
        ▼ +1 cycle  (EMIT state asserts fields_valid for one cycle)
   fields_valid / parser_fields_valid
        │
        │  order_book: receives fields_valid; BBO registered read
        │  (BBO data follows bbo_query_sym with 1-cycle FF latency)
        │
        │  symbol_filter: stock_q (1 cy) + match_partial_r (1 cy) + lookup_match_q (1 cy)
        ▼ +3 cycles  watchlist_hit valid
        │
        │  [3-cycle field delay] aligns price/shares/side/sym_id with watchlist_hit
        │
        │  feat_ext_fv = fields_valid_d3 & watchlist_hit  (gating)
        │
        │  feature_extractor_v2: 4-stage pipeline
        │    Stage 1: integer arithmetic (all 32 features)
        │    Stage 2: sign/magnitude decomposition, VWAP log2-approx
        │    Stage 3: bfloat16 conversion features [0..15]
        │    Stage 4: bfloat16 conversion features [16..31]; assert features_valid
        ▼ +4 cycles
   core_features_valid (broadcast to all 8 lliu_core instances)
        │
        │  pipeline_hold: asserted during and after features_valid until core_result_valid[0]
        │
        │  lliu_core (VEC_LEN=32): 4-state sequencer
        │    SEQ_IDLE   : latch features; assert dp_start  (+1 cy)
        │    SEQ_PRELOAD: 1 cycle weight_mem read latency   (+1 cy)
        │    SEQ_FEED   : 32 cycles feeding one element/cy  (+32 cy)
        │    SEQ_WAIT   : DPE drains pipeline; fp32_acc depth = 5 cy
        │                 bfloat16_mul depth = 2 cy → total drain = 6 cy (+6 cy)
        │    result_valid asserts; output_buffer latches     (+1 cy)
        ▼ +41 cycles
   core_result_valid[0..7] (simultaneous across all 8 cores)
        │
        │  strategy_arbiter: 3-level combinational tournament; registered output
        ▼ +1 cycle
   best_valid, best_score, best_core_id
        │
        │  risk_check: 2-stage pipeline
        │    Stage 0→1: fat-finger compare, price-band DSP
        │    Stage 1→2: position BRAM check; risk_pass / risk_blocked registered
        ▼ +2 cycles
   risk_pass (one-cycle pulse)
        │
        │  ouch_engine FSM: IDLE → FETCH (1 cy BRAM read) → LOAD (assemble; beat 0 on AXI4-S)
        ▼ +3 cycles  to first m_axis beat (LOAD cycle outputs beat 0)
   m_axis_tvalid (OUCH 5.0 Enter Order, 6 beats × 8 bytes = 48 bytes total)
```

**Total from `s_axis_tlast` accepted to `risk_pass`**:
- parser (1) + sym_filter (3) + feat_ext (4) + lliu_core (41) + arb (1) + risk (2) = **52 cycles**

**Total to first OUCH AXI4-S beat**: +3 = **~55 cycles @ 312.5 MHz ≈ 176 ns**

### 5.2 Stage Latency Summary

| Stage | Module | Latency (cycles) |
|-------|--------|-----------------|
| ITCH parse | `itch_parser_v2` | 1 (EMIT entry after last beat) |
| Symbol filter | `symbol_filter` | 3 (stock_q + partial + lookup) |
| Field alignment | `lliu_top_v2` (delay registers) | 0 (concurrent with filter) |
| Feature extraction | `feature_extractor_v2` | 4 |
| Inference (VEC_LEN=32) | `lliu_core` | 41 (1+1+32+6+1) |
| Strategy arbitration | `strategy_arbiter` | 1 |
| Risk check | `risk_check` | 2 |
| **Total to risk_pass** | — | **52** |
| OUCH assembly to first beat | `ouch_engine` | 3 (IDLE→FETCH→LOAD) |
| **Total to first OUCH beat** | — | **~55** |

### 5.3 Throughput and Backpressure

`pipeline_hold` is asserted for the duration of one inference pass (from `core_features_valid` until `core_result_valid[0]`). During this window `itch_parser_v2` de-asserts `s_axis_tready`, applying upstream backpressure into the `axis_async_fifo`. One inference is triggered per qualifying ITCH event (order-book message for a watched symbol).

## 6. Performance Targets

| Metric | Target | Achieved |
|--------|--------|---------|
| System clock | 312.5 MHz | ✓ Timing closure (WNS ≥ 0) |
| ITCH last beat → risk_pass | ≤ 60 cycles | ~52 cycles |
| ITCH last beat → first OUCH beat | ≤ 65 cycles | ~55 cycles |
| FPGA device | Kintex-7 xc7k160tffg676-2 | Fits in ML Standard free tier |

## 7. Key Parameters (`lliu_pkg.sv`)

| Parameter | Value | Description |
|-----------|-------|-------------|
| `NUM_CORES` | 8 | Number of parallel inference cores |
| `FEAT_VEC_LEN_V2` | 32 | Feature vector length (bfloat16 elements) |
| `HIDDEN_LAYER` | 32 | Weight depth per core (must equal `FEAT_VEC_LEN_V2`) |
| `OB_NUM_SYMBOLS` | 64 | Maximum tracked symbols in order book |
| `OB_LEVELS` | 4 | L2 book levels per side per symbol |
| `OB_REF_TABLE_BITS` | 13 | Hash table size (8192 entries, ≈57 RAMB18E1) |
| `SYM_FILTER_ENTRIES` | 64 | Symbol watchlist CAM depth |
| `PTP_SYNC_PERIOD` | 1024 | Cycles between PTP epoch snapshot updates |

## 8. Data Types

Defined in `lliu_pkg.sv`:

| Type | Width | Format | Use |
|------|-------|--------|-----|
| `bfloat16_t` | 16 bits | `[15] sign \| [14:7] exp (bias 127) \| [6:0] mantissa` | features, weights |
| `float32_t` | 32 bits | `[31] sign \| [30:23] exp (bias 127) \| [22:0] mantissa` | inference results, scores |

## 9. Interfaces

### 9.1 AXI4-Stream Ingress (ITCH 5.0)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `s_axis_tdata` | in | 64 | ITCH byte stream, big-endian (tdata[63:56] = first byte) |
| `s_axis_tvalid` | in | 1 | Data valid |
| `s_axis_tready` | out | 1 | Backpressure; de-asserted when `pipeline_hold` is high |
| `s_axis_tlast` | in | 1 | Last beat of the MoldUDP64 packet |

### 9.2 AXI4-Stream Egress (OUCH 5.0)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `m_axis_tdata` | out | 64 | OUCH 5.0 Enter Order, big-endian |
| `m_axis_tkeep` | out | 8 | Byte enables (last beat may be partial) |
| `m_axis_tvalid` | out | 1 | Data valid |
| `m_axis_tlast` | out | 1 | Last beat of the OUCH packet |
| `m_axis_tready` | in | 1 | Backpressure from 10GbE TX MAC |

### 9.3 AXI4-Lite Control (12-bit address)

Inline decode inside `lliu_top_v2`; no sub-module.

| Address | Name | R/W | Default | Description |
|---------|------|-----|---------|-------------|
| 0x014 | CAM_INDEX | W | — | Symbol-filter CAM entry index [7:0] |
| 0x018 | CAM_DATA_LO | W | — | CAM key bits [31:0] |
| 0x01C | CAM_DATA_HI | W | — | CAM key bits [63:32] |
| 0x020 | CAM_CTRL | W | — | [0]=commit strobe, [1]=en_bit (1=valid, 0=invalidate) |
| 0x038 | CAM_INDEX_HI | W | — | CAM entry index [9:8] (extends to 10-bit index) |
| 0x048 | COLLISION_COUNT | R | 0 | Order-book CRC-17 hash collision counter |
| 0x400 | BAND_BPS | W | 200 | Price-band width in basis points |
| 0x404 | MAX_QTY | W | 10000 | Fat-finger global share ceiling |
| 0x408 | SCORE_THRESH | W | 0.0 | Strategy fire threshold (float32 unsigned compare) |
| 0x40C | RISK_CTRL | W | 0 | [0]=kill switch (write-1-to-set, sticky) |
| 0x410 | RISK_STATUS | R | 0 | [1]=kill_sw_r, [0]=risk_blocked_latch (clears on read) |
| 0x500–0x57C | HIST_BIN[0..31] | R | 0 | Latency histogram bins (4-byte count each) |
| 0x580 | HIST_OVERFLOW | R | 0 | Count of samples with delta > 31 cycles |
| 0x584 | HIST_CLEAR | W | — | [0]=pulse clears all histogram bins |
| 0x800–0xBFC | WGT | W | — | Per-core weights: addr[11:10]=2'b10, core=addr[9:7], waddr=addr[6:2] |
| 0xC00–0xC1C | SHARES_CORE_k | W | 100 | Per-core proposed order size [23:0], k = 0..7 |
| 0xE00 | TMPL_ADDR | W | — | OUCH template write address [8:0] (sym_id[6:0] + beat[1:0]) |
| 0xE04 | TMPL_DATA_LO | W | — | OUCH template write data bits [31:0] (stage) |
| 0xE08 | TMPL_DATA_HI | W | — | OUCH template write data bits [63:32] (fires BRAM write) |

### 9.4 Snapshot Interface (`lliu_top_v2` ↔ `pcie_dma_engine`)

| Signal | Dir | Width | Description |
|--------|-----|-------|-------------|
| `snap_req` | in | 1 | One-cycle pulse: start a new BBO snapshot |
| `snap_data` | out | 64 | Combinational: current snapshot beat data |
| `snap_valid` | out | 1 | Combinational: data valid |
| `snap_ready` | in | 1 | Consumer ready |
| `snap_done` | out | 1 | Registered one-cycle pulse after last snapshot beat |

## 10. Key Design Decisions

### 10.1 Fully pipelined, no global stall
`pipeline_hold` is the only backpressure mechanism within `lliu_top_v2`. It prevents `itch_parser_v2` from accepting a new message while inference is in flight, ensuring at most one inference context is active at any time. This eliminates all RAW hazards in the accumulator chains.

### 10.2 Three-cycle symbol filter alignment
`symbol_filter` has three registered stages (stock_q → match_partial_r → lookup_match_q). A matching 3-cycle delay line on all parser field outputs ensures that `feat_ext_fv` — the input-valid to `feature_extractor_v2` — is logically AND'd with a correctly aligned `watchlist_hit`.

### 10.3 Eight independent inference cores
Eight identical `lliu_core` instances receive the same broadcast feature vector. Each core holds independent weights (per-core AXI4-Lite write port) representing a different trading strategy or symbol slice. `strategy_arbiter` selects the highest-scoring above-threshold core in one registered cycle.

### 10.4 DSP-aware risk check (2-stage pipeline)
The price-band multiplication (ref_price × band_bps) is placed in a registered `always_ff` that Vivado infers with `PREG=1` on the DSP48E1, co-locating the source FF with the DSP column and avoiding the relay DSP issue encountered in early runs (WNS −1.805 ns).

### 10.5 OUCH template BRAMs
Static per-symbol fields (stock name, TIF, firm, display) are stored in four 128 × 32-bit BRAMs (`ram_style = "block"`), initialised via AXI4-Lite before the system goes live. Per-order fields (shares, price, order token) are hot-patched at send time, keeping the serialisation latency to 4 cycles (IDLE→FETCH→LOAD→first SEND beat).

### 10.6 PTP timestamp subsystem
`ptp_core` maintains a free-running 64-bit counter and emits a `ptp_sync_pulse` every 1024 cycles, at which point `ptp_epoch` is snapshot to the counter value. Six `timestamp_tap` instances capture `{ptp_epoch, local_sub_cnt[9:0]}` (74 bits) at key pipeline events. `latency_histogram` measures the sub-counter delta between `rx_last` and `risk_pass` in 32 bins, providing nanosecond-resolution latency monitoring via AXI4-Lite.

### 10.7 Snapshot DMA path
`snapshot_mux` maintains a live shadow copy of all 64 symbol BBOs in two RAMB36E1 (bid + ask). On a `snap_req` pulse from `pcie_dma_engine`, it streams 2×64 × 64-bit beats (8 KB) into the staging memory for DMA transfer to the host at 10 ms intervals.

### 10.8 Network input path (kc705_top)
The 156.25 MHz network path applies drop-on-full (`eth_axis_rx_wrap`) and MoldUDP64 header stripping with sequence-number validation (`moldupp64_strip`) before data crosses into the 312.5 MHz inference domain via the async FIFO. Frames that would overflow the FIFO are silently dropped at whole-frame granularity; out-of-sequence datagrams are counted but not reordered.

