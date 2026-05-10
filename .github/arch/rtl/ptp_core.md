# `ptp_core` — Free-Running PTP Timestamp Counter

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Provides a free-running 64-bit hardware timestamp counter and a periodic synchronization pulse used to align sub-cycle timestamp taps. The synchronization epoch increments every 1024 clock cycles (3.2 µs at 312.5 MHz). No external PTP grandmaster is required; the counter runs autonomously from hardware reset.

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `ptp_sync_pulse` | out | 1 | One-cycle pulse asserted 1 cycle before epoch roll-over (when `sync_cnt == 1022`) |
| `ptp_epoch` | out | 64 | Current epoch value (`ptp_epoch_r`); stable until next roll-over |
| `ptp_counter` | out | 64 | Free-running monotonic counter (increments every cycle) |

## Internal Registers

| Register | Width | Description |
|----------|-------|-------------|
| `ptp_counter_r` | 64 | Increments by 1 every cycle from reset |
| `sync_cnt` | 10 | Sub-epoch cycle counter, 0..1023 |
| `ptp_epoch_r` | 64 | Epoch register; updates when `sync_cnt == 1023` |

## Functional Description

```
always_ff @(posedge clk):
    ptp_counter_r <= ptp_counter_r + 1
    sync_cnt      <= (sync_cnt == 1023) ? 0 : sync_cnt + 1
    ptp_epoch_r   <= (sync_cnt == 1023) ? ptp_epoch_r + 1 : ptp_epoch_r
    ptp_sync_pulse <= (sync_cnt == 1022)   // 1 cycle before epoch update
```

`ptp_epoch_r` starts at 0 after reset and advances monotonically. There is no provision for external correction or rate adjustment; absolute time accuracy is not a design goal. The module provides relative time references sufficient for per-packet latency measurement.

## Usage in `lliu_top_v2`

- `ptp_counter` is consumed by `feature_extractor_v2` (feature[31]: inter-arrival period) and all `timestamp_tap` instances.
- `ptp_epoch` and `ptp_sync_pulse` are forwarded to `timestamp_tap` instances.
- `ptp_counter` is also available via AXI4-Lite read at address `0x014` (low 32 bits) and `0x018` (high 32 bits) — see `SYSTEM.md §5`.

## Timing

- Counter rolls over after $2^{64}$ cycles ≈ 1870 years at 312.5 MHz.
- `ptp_sync_pulse` leads the epoch update by exactly 1 cycle, giving `timestamp_tap` time to latch the epoch before it changes.
- Clock: `clk`, 312.5 MHz, synchronous active-high reset (counter and epoch start at 0).
