# `timestamp_tap` — Single-Event Timestamp Capture

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md) ×5

## Purpose

Captures a 74-bit timestamp when a one-cycle trigger event occurs. The timestamp combines the current PTP epoch (64 bits) with a 10-bit sub-epoch counter that resets on each PTP sync pulse. Used to mark key pipeline events for latency histogram and AXI4-Lite telemetry readout.

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `tap_event` | in | 1 | One-cycle pulse: capture timestamp now |
| `ptp_epoch` | in | 64 | Current PTP epoch from `ptp_core` |
| `ptp_counter` | in | 64 | Free-running counter from `ptp_core` |
| `ptp_sync_pulse` | in | 1 | Sync pulse: reset `local_sub_cnt` next cycle |
| `timestamp_out` | out | 74 | Captured timestamp: `{epoch_latch[63:0], local_sub_cnt[9:0]}` |
| `timestamp_valid` | out | 1 | One-cycle pulse aligned with the capture |

## Internal State

| Register | Width | Description |
|----------|-------|-------------|
| `local_sub_cnt` | 10 | Counts clock cycles since last sync pulse; resets to 0 on `ptp_sync_pulse` |
| `epoch_latch` | 64 | Latches `ptp_epoch` on `ptp_sync_pulse`, before epoch increments |
| `timestamp_out` | 74 | Registered capture |
| `timestamp_valid` | 1 | Registered one-cycle valid pulse |

## Functional Description

```
always_ff @(posedge clk):
    // Sub-epoch counter
    if ptp_sync_pulse:
        local_sub_cnt <= 0
        epoch_latch   <= ptp_epoch  // capture epoch before it rolls
    else:
        local_sub_cnt <= local_sub_cnt + 1

    // Tap capture
    timestamp_valid <= tap_event
    if tap_event:
        timestamp_out <= {epoch_latch, local_sub_cnt}
```

`ptp_sync_pulse` arrives 1 cycle before `ptp_epoch` increments (see `ptp_core`), so `epoch_latch` always holds the epoch value that was active at the moment of the sub-count reset.

## Instances in `lliu_top_v2`

| Instance | `tap_event` source | Measure |
|----------|--------------------|---------|
| `u_tap_rx_last` | `s_axis_tlast` | Packet end from AXI4-FIFO |
| `u_tap_fields_valid` | `parser_fields_valid` | Parse complete |
| `u_tap_feat` | `core_features_valid` | Feature extraction done |
| `u_tap_result` | `core_result_valid[0]` | Inference done (core 0 proxy) |
| `u_tap_risk_pass` | `risk_pass` | Risk cleared; used as `t_end` in histogram |

## Timing

- Capture latency: 1 registered cycle from `tap_event` to `timestamp_valid`.
- Sub-count wraps at 1023 (10-bit), synchronized to `ptp_sync_pulse` every 1024 cycles.
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.
