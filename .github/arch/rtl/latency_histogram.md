# `latency_histogram` — 32-Bin Pipeline Latency Histogram

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`lliu_top_v2`](lliu_top_v2.md)

## Purpose

Accumulates a 32-bin histogram of AXI4-S last-beat-to-risk-pass latency. Bins cover 0–31 cycles; events exceeding 31 cycles increment an overflow bin. All bins are readable via AXI4-Lite and can be atomically cleared. Implemented with distributed RAM (LUTRAM) to avoid BRAM timing closure issues on the 3-stage pipeline.

## Ports

### Timestamp Inputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `ts_rx_last` | in | 74 | Timestamp from `u_tap_rx_last` (`t_start`) |
| `ts_rx_last_valid` | in | 1 | One-cycle valid for `t_start` |
| `ts_risk_pass` | in | 74 | Timestamp from `u_tap_risk_pass` (`t_end`) |
| `ts_risk_pass_valid` | in | 1 | One-cycle valid for `t_end` |

### AXI4-Lite Read Port

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `axil_bin_addr` | in | 5 | Bin index to read (0–31) |
| `axil_bin_data` | out | 32 | Current count of selected bin |
| `axil_clear` | in | 1 | One-cycle pulse: reset all bins and `overflow_bin` to 0 |
| `overflow_bin` | out | 32 | Count of events with delta > 31 |

## Internal Structure

- `bins[31:0][31:0]` — 32-entry distributed RAM, 32-bit saturating counters.
- `overflow_bin_r` — 32-bit register, increments on delta > 31.
- All bins initialized to 0 at reset; `axil_clear` also zeroes all.

## 3-Stage Pipeline

```
Stage 1 (cycle N+0→N+1):
    Latch t_start on ts_rx_last_valid.
    On ts_risk_pass_valid: delta[9:0] = ts_risk_pass[9:0] - t_start[9:0]
    sel_bin_r <= (delta > 31) ? 5'd31_overflow : delta[4:0]

Stage 1.5 (cycle N+1→N+2):   ← critical-path break
    pre_read_r <= bins[sel_bin_r]   // LUTRAM read issued here
    overflow_flag_r <= (delta > 31)
    sel_bin_q <= sel_bin_r

Stage 2 (cycle N+2→N+3):
    if overflow_flag_r:
        overflow_bin_r <= saturate(overflow_bin_r + 1)
    else:
        bins[sel_bin_q] <= saturate(pre_read_r + 1)
    valid_out <= 1 (one cycle)
```

Stage 1.5 is the key timing decision: issuing the LUTRAM read one stage early removes the 32:1 address MUX from the critical path between `delta` computation and the counter writeback.

## AXI4-Lite Access (from `lliu_top_v2` inline decoder)

- Address range `0x500–0x57C` (`addr[11:7] == 5'b00101`): `axil_bin_addr = addr[6:2]`; `axil_bin_data` returned combinationally from `bins[axil_bin_addr]`.
- Address `0x580`: returns `overflow_bin`.
- Write to `0x584` with any data: asserts `axil_clear` for 1 cycle.

## Back-to-back Hazard

If two `ts_risk_pass_valid` pulses arrive within 3 cycles, the second increments a bin while the first's writeback is in-flight. A bypass MUX in Stage 2 forwards the in-flight result: if `sel_bin_q == sel_bin_q_prev` and the previous writeback is pending, the new value is `prev_new_value + 1`. Back-to-back events are prevented in practice by `pipeline_hold`, but the bypass ensures correctness.

## Timing

- Histogram update latency: 3 cycles from `ts_risk_pass_valid` to counter writeback.
- Read latency: combinational (registered by AXI4-Lite response path in `lliu_top_v2`).
- Clock: `clk`, 312.5 MHz, synchronous active-high reset.
