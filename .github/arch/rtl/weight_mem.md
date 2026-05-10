# Module Spec: `weight_mem`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

Simple synchronous single-port SRAM storing `DEPTH` bfloat16 weights. Provides a write port for AXI4-Lite weight loading and a read port for the dot-product engine. Read latency is 1 cycle (registered output). Does not clear its weight array on reset.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `DEPTH` | `FEATURE_VEC_LEN` (4) | Number of bfloat16 weights |

## Ports

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset (affects `rd_data` only) |
| `wr_addr` | in | `log2(DEPTH)` | Write address (from AXI4-Lite via `axi4_lite_slave`) |
| `wr_data` | in | `bfloat16_t` (16) | Write data |
| `wr_en` | in | 1 | Write enable (write occurs on posedge clk when asserted) |
| `rd_addr` | in | `log2(DEPTH)` | Read address (from inference sequencer in `lliu_top`) |
| `rd_data` | out | `bfloat16_t` (16) | Read data; valid 1 cycle after `rd_addr` |

## Functional Description

### Write Port

```systemverilog
always_ff @(posedge clk) begin
    if (wr_en) mem[wr_addr] <= wr_data;
end
```

Writes are performed unconditionally when `wr_en` is high. No write-first or read-during-write behavior is defined (simultaneous read/write to the same address has undefined output on `rd_data`).

### Read Port

```systemverilog
always_ff @(posedge clk) begin
    if (rst) rd_data <= '0;
    else     rd_data <= mem[rd_addr];
end
```

**Read latency: 1 cycle.** `rd_addr` is presented in the `SEQ_PRELOAD` state of the inference sequencer; `rd_data` is valid in the first `SEQ_FEED` cycle.

## Memory Array

```
mem : bfloat16_t[DEPTH]
```

Intended to map to FPGA distributed RAM or small block RAM depending on `DEPTH`. For `DEPTH = 4`, synthesis typically uses LUT-based distributed RAM. At `DEPTH = 32`, Vivado may infer a RAMB18.

## Reset Behavior

`rst` clears `rd_data` to zero but does **not** zero the `mem` array. Weight contents survive a `sys_rst` (including `ctrl_soft_reset`). The host must re-load weights if they become invalid after reset.

## Timing

The inference sequencer (`lliu_top`) accounts for the 1-cycle read latency:

- `SEQ_IDLE` → `SEQ_PRELOAD`: `rd_addr` presented (= seq_idx = 0)
- `SEQ_PRELOAD` → `SEQ_FEED`: `rd_data` now valid; simultaneously advance `rd_addr` for next element
- Each `SEQ_FEED` cycle: `rd_data` holds weight for current element; `rd_addr` is advanced for next

There is no simultaneous read/write concern during inference because `wr_en` is driven by the AXI4-Lite write path, which is blocked from modifying weights while inference is in progress (the `status_busy` signal is available to software to poll before loading new weights).
