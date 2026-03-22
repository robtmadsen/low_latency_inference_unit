# RTL Module Architecture

> **Implementation plan:** [RTL_PLAN.md](../plan/RTL_PLAN.md) · **Master plan:** [MASTER_PLAN.md](../plan/MASTER_PLAN.md) · **Spec:** [SPEC.md](SPEC.md)

## Module Hierarchy

```
lliu_top
├── itch_parser
│   └── itch_field_extract
├── feature_extractor
├── dot_product_engine
│   ├── bfloat16_mul
│   └── fp32_acc
├── weight_mem
├── axi4_lite_slave
└── output_buffer
```

## Module Descriptions

### Top Level

| Module | Description |
|--------|-------------|
| **`lliu_top`** | System integrator, AXI interfaces, pipeline interconnect |

### Parser Stage

| Module | Description |
|--------|-------------|
| **`itch_parser`** | Top of parse pipeline, message alignment across AXI beats, type detection |
| **`itch_field_extract`** | Field extraction for Add Order (`'A'`): price, order ref, side |

### Feature Extraction Stage

| Module | Description |
|--------|-------------|
| **`feature_extractor`** | Price normalization, order flow encoding, rolling window aggregation |

### Inference Core

| Module | Description |
|--------|-------------|
| **`dot_product_engine`** | Pipelined MAC wrapper for small feature vectors, control sequencing, result generation |
| **`bfloat16_mul`** | bfloat16 multiplier used by the dot-product datapath |
| **`fp32_acc`** | float32 accumulator used to sum partial products |

### Memory & Control

| Module | Description |
|--------|-------------|
| **`weight_mem`** | Double-buffered on-chip SRAM banks for weight storage |
| **`axi4_lite_slave`** | Control plane: weight loading, configuration, result readout |
| **`output_buffer`** | Holds inference result for AXI4-Lite readout |

## Design Principles

- Each module maps to a clear pipeline stage or reusable compute primitive
- dot_product_engine / bfloat16_mul / fp32_acc decomposition keeps arithmetic testable in isolation
- `itch_parser` and `itch_field_extract` are separated so message types can be swapped without touching alignment logic
- `weight_mem` is kept intentionally small so model configuration remains simple and quick to verify
