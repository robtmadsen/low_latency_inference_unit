# Module Spec: `lliu_top`

> System overview: [SYSTEM.md](SYSTEM.md)

## Purpose

Top-level integration wrapper. Instantiates all pipeline modules, wires them together, implements the inference sequencer FSM, and exposes the AXI4-Stream (data plane) and AXI4-Lite (control plane) top-level interfaces.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `VEC_LEN` | `FEATURE_VEC_LEN` (4) | Feature vector length; propagated to all pipeline submodules |
| `AXIL_ADDR` | 8 | AXI4-Lite address width (bits) |
| `AXIL_DATA` | 32 | AXI4-Lite data width (bits) |

## Ports

### AXI4-Stream Slave (ITCH ingress)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk` | in | 1 | System clock |
| `rst` | in | 1 | Active-high synchronous reset |
| `s_axis_tdata` | in | 64 | ITCH byte stream (tdata[63:56] = first byte) |
| `s_axis_tvalid` | in | 1 | Stream valid |
| `s_axis_tready` | out | 1 | Stream ready (backpressure) |
| `s_axis_tlast` | in | 1 | Last beat of frame |

### AXI4-Lite Slave (control plane)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `s_axil_awaddr` | in | `AXIL_ADDR` | Write address |
| `s_axil_awvalid` | in | 1 | Write address valid |
| `s_axil_awready` | out | 1 | Write address ready |
| `s_axil_wdata` | in | `AXIL_DATA` | Write data |
| `s_axil_wstrb` | in | `AXIL_DATA/8` | Write strobes |
| `s_axil_wvalid` | in | 1 | Write data valid |
| `s_axil_wready` | out | 1 | Write data ready |
| `s_axil_bresp` | out | 2 | Write response |
| `s_axil_bvalid` | out | 1 | Write response valid |
| `s_axil_bready` | in | 1 | Write response ready |
| `s_axil_araddr` | in | `AXIL_ADDR` | Read address |
| `s_axil_arvalid` | in | 1 | Read address valid |
| `s_axil_arready` | out | 1 | Read address ready |
| `s_axil_rdata` | out | `AXIL_DATA` | Read data |
| `s_axil_rresp` | out | 2 | Read response |
| `s_axil_rvalid` | out | 1 | Read data valid |
| `s_axil_rready` | in | 1 | Read data ready |

## Internal Signals (pipeline interconnect)

| Signal | Width | From → To | Description |
|--------|-------|-----------|-------------|
| `parser_fields_valid` | 1 | itch_parser → feature_extractor | Add Order detected |
| `parser_order_ref` | 64 | itch_parser → feature_extractor | Extracted order reference |
| `parser_side` | 1 | itch_parser → feature_extractor | Buy (1) / sell (0) |
| `parser_price` | 32 | itch_parser → feature_extractor | Extracted price |
| `feat_vec` | bfloat16_t[VEC_LEN] | feature_extractor → sequencer | Computed feature vector |
| `feat_valid` | 1 | feature_extractor → sequencer | Feature vector valid |
| `wgt_rd_addr` | log2(VEC_LEN) | sequencer → weight_mem | Weight read address |
| `wgt_rd_data` | bfloat16_t | weight_mem → DPE | Weight read data |
| `dp_start` | 1 | sequencer → DPE | Start new inference |
| `dp_feature_valid` | 1 | sequencer → DPE | Feature element valid |
| `dp_feature_in` | bfloat16_t | sequencer → DPE | Feature element |
| `dp_weight_in` | bfloat16_t | weight_mem → DPE | Weight element |
| `dp_result` | float32_t | DPE → output_buffer | Inference result |
| `dp_result_valid` | 1 | DPE → output_buffer | Result valid |
| `pipeline_hold` | 1 | lliu_top logic → itch_parser | Backpressure |
| `sys_rst` | 1 | lliu_top logic | `rst \| ctrl_soft_reset` |

## Inference Sequencer FSM

The sequencer is implemented as combinational/registered logic inside `lliu_top` (not a separate module). It bridges the feature extractor and the dot-product engine, managing the 1-cycle weight memory read latency.

```
        feat_valid
            │
    ┌───────▼────────┐
    │   SEQ_IDLE     │◄─────────────────────────────────────┐
    │ dp_start ← 1   │  seq_idx==VEC_LEN-1 (last element)  │
    │ seq_idx  ← 0   │                                      │
    └───────┬────────┘                                      │
            │                                               │
    ┌───────▼────────┐                                      │
    │ SEQ_PRELOAD    │  (1 cycle — weight read latency)     │
    └───────┬────────┘                                      │
            │                                               │
    ┌───────▼────────┐                                      │
    │  SEQ_FEED      │──────────────────────────────────────┘
    │ present feat[i]│  dp_feature_valid=1 each cycle
    │ seq_idx++      │  for i=0..VEC_LEN-1
    └────────────────┘
```

- `dp_start` is registered (appears 1 cycle after `feat_valid`).
- `SEQ_PRELOAD` adds 1 stall cycle so the weight-memory output is valid when `SEQ_FEED` begins.
- `dp_feature_valid` is asserted every cycle during `SEQ_FEED`; no gaps.

## Backpressure Logic

```systemverilog
assign pipeline_hold = feat_valid || (seq_state != SEQ_IDLE);
```

`s_axis_tready` is de-asserted (via `itch_parser`) when `pipeline_hold` is high. This prevents the parser from accepting a new ITCH message while the current inference is in progress, guaranteeing a 1:1 relationship between `parser_fields_valid` and `dp_result_valid`.

## Reset Domains

| Module | Reset used |
|--------|-----------|
| `itch_parser` | `sys_rst` |
| `itch_field_extract` | `sys_rst` |
| `feature_extractor` | `sys_rst` |
| inference sequencer | `sys_rst` |
| `dot_product_engine` | `sys_rst` |
| `weight_mem` | `sys_rst` |
| `output_buffer` | `sys_rst` |
| `axi4_lite_slave` | `rst` (external only) |
