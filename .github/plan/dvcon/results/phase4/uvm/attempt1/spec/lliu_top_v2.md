# `lliu_top_v2` — LLIU v2.0 Top-Level Integration

> Part of [SYSTEM.md](SYSTEM.md) · **Target**: Kintex-7 xc7k160tffg676-2 · 312.5 MHz

## Purpose

Top-level wrapper that integrates the complete LLIU v2.0 inference and order-management pipeline. Receives a stripped ITCH 5.0 AXI4-Stream (from `kc705_top` via `axis_async_fifo`), drives an OUCH 5.0 AXI4-Stream output, and exposes a 12-bit AXI4-Lite control interface. All register decoding is inline (no sub-module).

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `VEC_LEN` | `FEAT_VEC_LEN_V2` (32) | Feature vector length; must equal `HIDDEN` |
| `HIDDEN` | `HIDDEN_LAYER` (32) | Weight depth per `lliu_core` instance |

## Ports

### AXI4-Stream Slave — ITCH 5.0 ingress

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `s_axis_tdata` | in | 64 | ITCH byte stream, big-endian |
| `s_axis_tvalid` | in | 1 | Beat valid |
| `s_axis_tready` | out | 1 | Backpressure; de-asserted when `pipeline_hold` |
| `s_axis_tlast` | in | 1 | Last beat of packet |

### AXI4-Stream Master — OUCH 5.0 egress

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `m_axis_tdata` | out | 64 | OUCH 5.0 Enter Order, big-endian |
| `m_axis_tkeep` | out | 8 | Byte enables |
| `m_axis_tvalid` | out | 1 | Beat valid |
| `m_axis_tlast` | out | 1 | Last beat of packet |
| `m_axis_tready` | in | 1 | Backpressure from TX MAC |

### AXI4-Lite Slave — 12-bit control

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `s_axil_awaddr` | in | 12 | Write address |
| `s_axil_awvalid` | in | 1 | |
| `s_axil_awready` | out | 1 | |
| `s_axil_wdata` | in | 32 | Write data |
| `s_axil_wvalid` | in | 1 | |
| `s_axil_wready` | out | 1 | |
| `s_axil_bresp` | out | 2 | Always 2'b00 |
| `s_axil_bvalid` | out | 1 | |
| `s_axil_bready` | in | 1 | |
| `s_axil_araddr` | in | 12 | Read address |
| `s_axil_arvalid` | in | 1 | |
| `s_axil_arready` | out | 1 | |
| `s_axil_rdata` | out | 32 | Read data |
| `s_axil_rresp` | out | 2 | Always 2'b00 |
| `s_axil_rvalid` | out | 1 | |
| `s_axil_rready` | in | 1 | |

### Snapshot interface (to `pcie_dma_engine`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `snap_req` | in | 1 | One-cycle pulse: start new BBO snapshot |
| `snap_data` | out | 64 | Combinational snapshot beat |
| `snap_valid` | out | 1 | Combinational valid |
| `snap_ready` | in | 1 | Consumer ready |
| `snap_done` | out | 1 | Registered one-cycle pulse after last beat |

### Monitoring

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `collision_count_out` | out | 32 | CRC-17 hash collision counter from `order_book` |
| `tx_overflow_out` | out | 1 | OUCH TX backpressure watchdog from `ouch_engine` |

## Submodule Instances

| Instance | Module | Role |
|----------|--------|------|
| `u_ptp` | `ptp_core` | Free-running 64-bit counter; sync pulse every 1024 cycles |
| `u_parser` | `itch_parser_v2` | Multi-type ITCH 5.0 parser |
| `u_tap_rx_last` | `timestamp_tap` | Timestamp on `s_axis_tlast` |
| `u_tap_fields_valid` | `timestamp_tap` | Timestamp on `parser_fields_valid` |
| `u_ob` | `order_book` | BBO + L2 order book for 64 symbols |
| `u_sym_filter` | `symbol_filter` | 64-entry LUT-CAM watchlist |
| `u_feat_ext` | `feature_extractor_v2` | 32-feature, 4-stage pipeline |
| `u_tap_feat` | `timestamp_tap` | Timestamp on `core_features_valid` |
| `gen_cores[0..7]` | `lliu_core` | 8 independent inference cores |
| `u_tap_result` | `timestamp_tap` | Timestamp on `core_result_valid[0]` |
| `u_arb` | `strategy_arbiter` | 3-level tournament tree arbiter |
| `u_risk` | `risk_check` | Pre-trade risk enforcement |
| `u_tap_risk_pass` | `timestamp_tap` | Timestamp on `risk_pass` |
| `u_ouch` | `ouch_engine` | OUCH 5.0 packet assembler |
| `u_tap_ouch_last` | `timestamp_tap` | Timestamp on OUCH `m_axis_tlast` |
| `u_hist` | `latency_histogram` | 32-bin latency histogram |
| `u_snap` | `snapshot_mux` | BBO shadow buffer + snapshot streamer |

## Functional Description

### Field-alignment pipeline

`symbol_filter` takes 3 registered cycles from `parser_fields_valid` to produce `watchlist_hit`. A matching 3-stage delay line (`_d1`→`_d2`→`_d3`) on `fields_valid`, `price`, `shares`, `side`, and `sym_id` ensures the gating signal `feat_ext_fv = fields_valid_d3 & watchlist_hit` presents correctly aligned data to `feature_extractor_v2`.

### Pipeline hold

```
pipeline_hold = core_features_valid | in_flight
in_flight: set on core_features_valid; cleared on core_result_valid[0]
```
`pipeline_hold` is fed back to `itch_parser_v2`, which de-asserts `s_axis_tready` while high. At most one inference context is active at any time.

### Hold registers

When `feat_ext_fv` fires, `lliu_top_v2` latches `price_d1`, `sym_id_d1`, `side_d1`, and the BBO mid-price (`(bbo_bid_price >> 1) + (bbo_ask_price >> 1)`) into stable registers. These are forwarded to `risk_check` and `ouch_engine` after the ~41-cycle inference completes.

### AXI4-Lite inline decoder

Two capture registers (`aw_cap`, `w_cap`) allow address and data to arrive in either order. When both are captured a write transaction fires, generating a `BVALID` response.

**Readable registers:**

| Address decode | Source |
|---------------|--------|
| `0x048` | `collision_count` from `order_book` |
| `0x410` | `{30'h0, kill_sw_r, risk_blocked_latch}` — reading clears `risk_blocked_latch` |
| `addr[11:7] == 5'b00101` (0x500–0x57C) | `axil_bin_data` from `latency_histogram` |
| `0x580` | `overflow_bin` from `latency_histogram` |

Per-core weight writes: `addr[11:10] == 2'b10` selects weight space; `addr[9:7]` = core index; `addr[6:2]` = weight address; write data `[15:0]` = `bfloat16_t` weight.

## Timing

Single clock domain (`clk`, 312.5 MHz). Synchronous active-high reset. `BRESP`/`RRESP` tied to `2'b00`. The kill switch (`0x40C[0]`) is write-1-to-set only; cleared only by hardware reset.
