# `snapshot_mux` — BBO Shadow Buffer + Snapshot Streamer

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Maintains a shadow copy of best-bid-offer (BBO) data for all 64 symbols in two RAMB36E1 instances (one per side) and streams the entire snapshot over a 64-bit AXI4-Stream interface on demand. Used by `pcie_dma_engine` to DMA BBO state to the host every 10 ms.

## Ports

### BBO Update Input (from `order_book`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `bbo_valid` | in | 1 | One-cycle pulse: BBO has changed for `bbo_sym_id` |
| `bbo_sym_id` | in | 16 | Symbol whose BBO updated |
| `bbo_bid_price` | in | 32 | New best bid price |
| `bbo_bid_size` | in | 24 | New best bid size (low 24 bits used) |
| `bbo_ask_price` | in | 32 | New best ask price |
| `bbo_ask_size` | in | 24 | New best ask size (low 24 bits used) |

### Snapshot Control (from `pcie_dma_engine`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `snap_req` | in | 1 | One-cycle pulse: begin streaming snapshot |
| `snap_ready` | in | 1 | Consumer ready (AXI4-S style) |
| `snap_data` | out | 64 | **Combinational** snapshot beat |
| `snap_valid` | out | 1 | **Combinational** valid |
| `snap_done` | out | 1 | Registered one-cycle pulse: last beat sent |

## BRAM Organization

| BRAM | Instances | Depth | Width | Content |
|------|-----------|-------|-------|---------|
| `bid_bram` | RAMB36E1 | 64 | 64 | `{price[31:0], 8'h00, size[23:0]}` per symbol |
| `ask_bram` | RAMB36E1 | 64 | 64 | `{price[31:0], 8'h00, size[23:0]}` per symbol |

Beat layout for each snapshot word:

```
[63:32]  price (32 bits)
[31:24]  0x00  (reserved)
[23: 0]  size  (24 bits)
```

## BBO Write Latency

`bbo_valid` drives a 1-cycle delayed write to both BRAMs:

```
always_ff: bbo_wr_en <= bbo_valid; bbo_wr_addr <= bbo_sym_id; ...
```

The 1-cycle delay allows the BRAM input registers (WREG=1) to settle before the write enable fires, preventing write-during-read hazards on a concurrent snapshot stream.

## Snapshot State Machine

Three logical phases, driven by a `beat_cnt` counter:

| Phase | Duration | Description |
|-------|----------|-------------|
| `PREFETCH` | 1 cycle | Issue BRAM read for symbol 0 |
| `SEND_BID` | 64 cycles | Stream 64 bid beats (bid_bram addresses 0–63) |
| `SEND_ASK` | 64 cycles | Stream 64 ask beats (ask_bram addresses 0–63) |

Total: 1 + 64 + 64 = 129 cycles (+ stall cycles on `~snap_ready`).

`snap_valid` and `snap_data` are **combinational** outputs derived from the current BRAM read data and `beat_cnt`; they are registered by the consuming `pcie_dma_engine`.

`snap_done` is a registered 1-cycle pulse asserted after the final ask beat (`beat_cnt == 128 & snap_ready`).

## Concurrent Update / Stream Conflict

If `bbo_valid` arrives while a snapshot is in progress, the write proceeds normally (BRAM write port is independent of read port on RAMB36E1 in SDP mode). The snapshot stream may present a mix of old and new prices — this is acceptable for a 10 ms telemetry snapshot.

## Timing

- BRAM read latency: 1 cycle (registered output mode, `DOA_REG=1`).
- `snap_data`/`snap_valid` are combinational from BRAM DO; they are registered at the `pcie_dma_engine` input.
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.
