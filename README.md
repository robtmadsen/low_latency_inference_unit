# Low-Latency Inference Unit (LLIU)

A hardware accelerator for real-time inference on streaming NASDAQ ITCH 5.0 market data, verified independently with both UVM and cocotb.

## What It Does

Parses live-format NASDAQ ITCH 5.0 binary data, extracts trading features, and runs single-sample inference through a pipelined bfloat16 dot-product engine — all in under 5 cycles at 300 MHz.

```
AXI4-Stream → ITCH Parser → Feature Extractor → Dot-Product Engine → Result
                                                       ↑
                                              AXI4-Lite (weights)
```

## RTL Architecture

| Module | Description |
|--------|-------------|
| `lliu_top` | System integrator, AXI interfaces, pipeline interconnect |
| `itch_parser` | Message alignment across AXI beats, type detection |
| `itch_field_extract` | Field extraction for Add Order: price, order ref, side |
| `feature_extractor` | Price normalization, order flow encoding |
| `dot_product_engine` | Pipelined MAC for small feature vectors |
| `bfloat16_mul` | bfloat16 multiplier |
| `fp32_acc` | float32 accumulator |
| `weight_mem` | Double-buffered on-chip SRAM for weights |
| `axi4_lite_slave` | Control plane: weight loading, config, result readout |
| `output_buffer` | Holds inference result for readout |

## Dual Verification

Both environments are fully independent and self-sufficient — each can verify the entire design alone. The goal is a head-to-head comparison of UVM vs cocotb.

### UVM (ASIC-Grade)

- AXI4-Stream + AXI4-Lite agents with full scoreboard
- DPI-C bridge to shared Python golden model (NumPy)
- SVA bind files for protocol compliance and FSM safety
- Functional coverage: message type × price range × side × backpressure
- Real ITCH data replay + constrained-random + error injection

### cocotb (Python-Native)

- AXI4-Stream + AXI4-Lite drivers/monitors with transaction scoreboard
- Shared golden model called natively from Python
- Protocol compliance checkers as concurrent coroutines
- Functional coverage with bin tracking and closure reporting
- Block-level and system-level tests via Makefile TOPLEVEL selection

### Shared

- **Golden model**: Single Python/NumPy reference used by both environments
- **Sample data**: Real NASDAQ ITCH 5.0 binary (`data/tvagg_sample.bin`) from [NASDAQ TotalView-ITCH](https://emi.nasdaq.com/ITCH/Nasdaq%20ITCH/)
- **Latency profiling**: Cycle-accurate per-message timing, p50/p99/p99.9 percentiles, jitter

## Project Structure

```
rtl/                          # SystemVerilog RTL
tb/
├── uvm/                      # UVM testbench (VCS / Verilator)
└── cocotb/                   # cocotb testbench (Verilator)
data/
├── tvagg_sample.bin          # Decompressed ITCH 5.0 binary (~3.7 MB)
└── tvagg_sample.gz           # Compressed source
```

## Toolchain

| Category | Tool |
|----------|------|
| HDL | SystemVerilog 2017 |
| Simulation | Verilator 5.0+ / Synopsys VCS |
| UVM Verification | UVM 1.2, SVA, DPI-C |
| cocotb Verification | cocotb, Python 3.12, NumPy |

## Design Choices

- **ITCH 5.0**: Real HFT protocol, not a toy — validated against actual NASDAQ sample data
- **bfloat16 multiply + float32 accumulate**: Mixed-precision arithmetic used in production ML accelerators
- **Batch size = 1**: Latency-optimized for HFT, not throughput-optimized for training
- **Small inference engine**: Verification is the focus, not model complexity
