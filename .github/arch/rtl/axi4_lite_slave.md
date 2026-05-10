# Module Spec: `axi4_lite_slave`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

AXI4-Lite control-plane interface. Implements a flat register map for weight loading, inference control, status polling, result readout, and KC705 extension monitoring. Single outstanding transaction model; no pipelining. Uses the external `rst` only (not `sys_rst`) so the control-plane registers remain stable while the datapath is being soft-reset.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `ADDR_WIDTH` | 8 | AXI4-Lite address bus width |
| `DATA_WIDTH` | 32 | AXI4-Lite data bus width |

## AXI4-Lite Ports

Standard AXI4-Lite slave signals (write address, write data, write response, read address, read data channels). See [SYSTEM.md](SYSTEM.md) §8 for signal-level description.

## Register Map

| Address | Name | Access | Reset | Description |
|---------|------|--------|-------|-------------|
| 0x00 | CTRL | W | — | [0] `ctrl_start` (self-clearing); [1] `ctrl_soft_reset` (self-clearing) |
| 0x04 | STATUS | R | 0 | [0] `status_result_ready`; [1] `status_busy` |
| 0x08 | WGT_ADDR | W | 0 | Weight write address (`log2(FEATURE_VEC_LEN)` bits used) |
| 0x0C | WGT_DATA | W | 0 | Weight write data (bfloat16); writing this register triggers `wgt_wr_en` for one cycle |
| 0x10 | RESULT | R | 0 | Inference result (float32 from `output_buffer`) |
| 0x14 | CAM_INDEX | W | 0 | Symbol-filter CAM entry index [7:0] |
| 0x18 | CAM_DATA_LO | W | 0 | CAM key lower 32 bits |
| 0x1C | CAM_DATA_HI | W | 0 | CAM key upper 32 bits |
| 0x20 | CAM_CTRL | W | 0 | [0] `cam_wr_valid` (self-clearing); [1] `cam_wr_en_bit` |
| 0x24 | DROPPED_FRAMES | R | 0 | `eth_axis_rx_wrap` dropped frame count (CDC'd input) |
| 0x28 | DROPPED_DGRAMS | R | 0 | `moldupp64_strip` dropped datagram count (CDC'd input) |
| 0x2C | SEQ_LO | R | 0 | `expected_seq_num[31:0]` (CDC'd input) |
| 0x30 | SEQ_HI | R | 0 | `expected_seq_num[63:32]` (CDC'd input) |
| 0x34 | GTX_LOCK | R | 0 | [0] GTX PLL locked (CDC'd input; tied 1 in simulation) |
| 0x38 | CAM_INDEX_HI | W | 0 | Symbol-filter CAM entry index [9:8] (extends CAM_INDEX) |
| 0x3C | HIST_ADDR | W | 0 | Latency histogram bin address [4:0] |
| 0x40 | HIST_DATA | R | 0 | Latency histogram bin count for `HIST_ADDR` |
| 0x44 | HIST_CLEAR | W | — | [0] Clear all histogram bins (self-clearing) |
| 0x48 | COLLISION_COUNT | R | 0 | `order_book` hash collision counter |
| 0x4C | HIST_OVERFLOW | R | 0 | Latency histogram overflow bin count |

## Side-Band Ports (non-AXI)

### Outputs to datapath

| Port | Width | Description |
|------|-------|-------------|
| `wgt_wr_addr` | `log2(FEATURE_VEC_LEN)` | Combinational from WGT_ADDR register |
| `wgt_wr_data` | 16 | bfloat16 weight value from WGT_DATA register |
| `wgt_wr_en` | 1 | One-cycle pulse on write to WGT_DATA |
| `ctrl_start` | 1 | Self-clearing; registered pulse on write of CTRL[0] |
| `ctrl_soft_reset` | 1 | Self-clearing; registered pulse on write of CTRL[1] |

### Inputs from datapath

| Port | Width | Description |
|------|-------|-------------|
| `status_result_ready` | 1 | From `output_buffer.result_ready` |
| `status_busy` | 1 | From `lliu_top` sequencer: `seq_state != SEQ_IDLE` |
| `result_data` | 32 | Float32 inference result from `output_buffer` |

### KC705 extension outputs

| Port | Width | Description |
|------|-------|-------------|
| `cam_wr_index` | 10 | `{CAM_INDEX_HI[1:0], CAM_INDEX[7:0]}` |
| `cam_wr_data` | 64 | `{CAM_DATA_HI, CAM_DATA_LO}` |
| `cam_wr_valid` | 1 | One-cycle pulse on write of CAM_CTRL[0] |
| `cam_wr_en_bit` | 1 | Latched from CAM_CTRL[1] |
| `axil_bin_addr` | 5 | Latency histogram bin address from HIST_ADDR |
| `axil_clear` | 1 | One-cycle pulse on write of HIST_CLEAR[0] |

### KC705 extension inputs (must be CDC'd by caller)

| Port | Width | Description |
|------|-------|-------------|
| `dropped_frames` | 32 | From `eth_axis_rx_wrap` (needs synchronisation if different clock domain) |
| `dropped_datagrams` | 32 | From `moldupp64_strip` (needs synchronisation) |
| `expected_seq_num` | 64 | From MoldUDP sequencer (needs synchronisation) |
| `gtx_lock` | 1 | From GTX PLL (needs 2-flop sync) |
| `axil_bin_data` | 32 | From `latency_histogram` (same clock domain) |
| `overflow_bin` | 32 | From `latency_histogram` (same clock domain) |
| `collision_count` | 32 | From `order_book` (same clock domain) |

## Transaction Model

Single outstanding transaction. The write path latches address and data separately; the response (`bvalid`) is sent only after both `awvalid` and `wvalid` have been seen. The read path responds in one cycle once `arvalid` is accepted.

## Reset Note

`axi4_lite_slave` uses the raw `rst` input (not `sys_rst`). This is intentional: `ctrl_soft_reset` originates from a write to this module, so using `sys_rst` would create a latch-like loop where the register asserting soft-reset is itself cleared by soft-reset before it can be sampled. The datapath modules use `sys_rst = rst | ctrl_soft_reset`.
