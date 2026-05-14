# `moldupp64_strip` — MoldUDP64 Header Stripper

> Part of [SYSTEM.md](SYSTEM.md) · **Instantiated by**: [`kc705_top`](kc705_top.md) · **Clock domain**: 156.25 MHz (`net_clk`)

## Purpose

Strips the 20-byte MoldUDP64 protocol header from UDP payloads and forwards the raw ITCH 5.0 byte stream downstream. Validates sequence numbers and maintains a saturating dropped-datagram counter. Handles the 8-byte AXI4-Stream alignment boundary introduced by the 20-byte header.

## Ports

### AXI4-Stream Slave (from `udp_complete_64`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `s_axis_tdata` | in | 64 | UDP payload, 8 bytes/beat, big-endian |
| `s_axis_tkeep` | in | 8 | Byte enables |
| `s_axis_tvalid` | in | 1 | |
| `s_axis_tlast` | in | 1 | Last beat of UDP datagram |
| `s_axis_tready` | out | 1 | Backpressure |

### AXI4-Stream Master (to `axis_async_fifo`)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `m_axis_tdata` | out | 64 | ITCH 5.0 byte stream (aligned) |
| `m_axis_tkeep` | out | 8 | Byte enables |
| `m_axis_tvalid` | out | 1 | |
| `m_axis_tlast` | out | 1 | |
| `m_axis_tready` | in | 1 | |

### Sideband Outputs

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `seq_num` | out | 64 | MoldUDP64 sequence number of current datagram |
| `msg_count` | out | 16 | Message count field from header |
| `seq_valid` | out | 1 | One-cycle pulse: `seq_num` and `msg_count` are valid |

### Monitoring

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `dropped_datagrams` | out | 32 | Saturating count of datagrams dropped due to sequence gaps |
| `expected_seq_num` | out | 64 | Next expected sequence number |

## MoldUDP64 Header Layout

| Bytes | Field |
|-------|-------|
| 0–9 | Session ID (10 bytes, ASCII) |
| 10–17 | Sequence number (8 bytes, big-endian uint64) |
| 18–19 | Message count (2 bytes, big-endian uint16) |

Total header: 20 bytes = 2.5 × 8-byte AXI4-S beats.

## FSM — 6 States

| State | Description |
|-------|-------------|
| `S_HEADER_B0` | Consume beat 0 (bytes 0–7: session bytes 0–7) |
| `S_HEADER_B1` | Consume beat 1 (bytes 8–15: session[8..9] + seq_num[0..5]) |
| `S_HEADER_B2` | Consume beat 2 (bytes 16–23: seq_num[6..7] + msg_count + ITCH[0..3]) — stage ITCH[0..3] |
| `S_PAYLOAD` | Concatenate staged [3:0] with incoming [7:4] to form aligned 8-byte ITCH beat |
| `S_DROP` | Drop all remaining beats of a sequence-invalid datagram |
| `S_FLUSH_SHORT` | Handle datagrams shorter than 21 bytes (no ITCH content); drain and return |

### Alignment Handling (S_HEADER_B2 / S_PAYLOAD)

The 20-byte header ends in the middle of beat 2. Bytes [3:0] of beat 2 contain the first 4 ITCH bytes. These are staged in `stage_buf[31:0]` and combined with the lower 4 bytes of beat 3 to produce the first aligned 8-byte ITCH beat:

```
m_axis_tdata = {s_axis_tdata[31:0], stage_buf[31:0]}
```

Subsequent beats simply concatenate the upper half of the previous beat with the lower half of the current beat — a 32-bit shift register alignment pattern.

### Sequence Number Validation

On entering `S_HEADER_B1`, `seq_num` is extracted from the incoming data. If `seq_num != expected_seq_num`:
- The datagram is dropped (`S_DROP`).
- `dropped_datagrams` is incremented (saturating).
- `expected_seq_num` is **NOT** advanced (the module waits for the correct next sequence number; it does not gap-fill).

On a valid datagram: `expected_seq_num` is advanced by 1 after `tlast`.

`seq_valid` pulses once per valid datagram at the `S_HEADER_B2` transition.

## Timing

- Clock: `net_clk`, 156.25 MHz, synchronous active-high reset.
- Header consume latency: 3 beats (3 cycles at line rate, ignoring stalls).
- Alignment adds 0 extra cycles — the staged 4-byte buffer is filled during header processing.
- `s_axis_tready` is de-asserted during `S_DROP` only if the downstream FIFO is full (pass-through backpressure).
