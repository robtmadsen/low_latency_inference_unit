# `eth_axis_rx_wrap` — 10GbE MAC RX Drop-on-Full Wrapper

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`kc705_top`](kc705_top.md) · **Clock domain**: 156.25 MHz (`net_clk`)

## Purpose

Wraps the Forencich `eth_axis_rx` MAC receiver to add frame-granular drop-on-full behaviour. The MAC RX ready signal is held permanently asserted (MAC is never stalled); instead, complete frames are dropped at frame boundaries when the downstream FIFO signals near-full. Maintains a saturating 32-bit dropped-frame counter for monitoring.

## Ports

### MAC RX Input (from SFP+ 10GBASE-R PCS/PMA)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `mac_rx_tdata` | in | 64 | Raw MAC RX data |
| `mac_rx_tkeep` | in | 8 | Byte enables |
| `mac_rx_tvalid` | in | 1 | MAC RX valid |
| `mac_rx_tlast` | in | 1 | End of MAC frame |
| `mac_rx_tready` | out | 1 | **Permanently 1** — MAC is never stalled |
| `mac_rx_tuser` | in | 1 | Frame error flag from MAC |

### Ethernet Header Sideband (to `udp_complete_64`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `eth_hdr_valid` | out | 1 | Pulsed with first payload beat |
| `eth_dest_mac` | out | 48 | Destination MAC address |
| `eth_src_mac` | out | 48 | Source MAC address |
| `eth_type` | out | 16 | EtherType field |

### Payload AXI4-Stream (to `udp_complete_64`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `m_axis_tdata` | out | 64 | Ethernet payload |
| `m_axis_tkeep` | out | 8 | Byte enables |
| `m_axis_tvalid` | out | 1 | |
| `m_axis_tlast` | out | 1 | |
| `m_axis_tready` | in | 1 | Backpressure from `udp_complete_64` |
| `m_axis_tuser` | out | 1 | Frame error propagated |

### FIFO Status Input

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `fifo_almost_full` | in | 1 | CDC FIFO occupancy > threshold; triggers drop decision |

### Monitoring

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `dropped_frames` | out | 32 | Saturating count of frames dropped due to FIFO pressure |

## Drop Logic

```
drop_frame: set when fifo_almost_full & mac_rx_tlast (end of previous frame)
             cleared when next mac_rx_tlast completes the dropped frame

if drop_frame:
    m_axis_tvalid = 0    (suppress all beats of this frame)
    dropped_frames ← saturate(dropped_frames + 1) on tlast of dropped frame
else:
    pass through beats verbatim
```

The decision is made at frame boundaries only to avoid presenting a truncated frame to the UDP stack.

## Underlying IP

`eth_axis_rx` from Alex Forencich's [verilog-ethernet](https://github.com/alexforencich/verilog-ethernet) library (under `lib/verilog-ethernet/`). This module handles 64-bit XGMII decode, preamble strip, and CRC check. `eth_axis_rx_wrap` adds only the drop-on-full gate on top.

## Timing

- Clock: `net_clk`, 156.25 MHz, synchronous active-high reset.
- No added latency when not dropping (combinational pass-through plus `eth_axis_rx` internal pipeline).
- Drop decision latency: 0 cycles — decision taken at exact frame boundary.
