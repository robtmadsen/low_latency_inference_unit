# RTL Implementation Plan

> **Architecture:** [RTL_ARCH.md](../arch/RTL_ARCH.md) · **Master plan:** [MASTER_PLAN.md](MASTER_PLAN.md) · **Spec:** [SPEC.md](../arch/SPEC.md)

Each phase ends with a functional commit. No phase depends on the verification environments — RTL is built and linted independently.

---

## Phase 1: Arithmetic Primitives

**Goal:** Standalone, lint-clean bfloat16 multiplier and float32 accumulator.

### Steps

1. Define package `lliu_pkg.sv` with shared types: bfloat16 typedef, feature vector width parameter, pipeline constants
2. Implement `bfloat16_mul.sv`
   - Inputs: two bfloat16 operands (16-bit each)
   - Output: float32 product (32-bit)
   - Decompose: sign XOR, exponent add with bias correction, mantissa multiply (8×8 → 16-bit), normalize
   - Single-cycle combinational first; pipeline register optional later
3. Implement `fp32_acc.sv`
   - Inputs: float32 addend, accumulate enable, clear
   - Output: float32 running sum
   - Handle: accumulator reset between inference runs, no saturation needed for small vectors
4. Lint both with Verilator: `verilator --lint-only -Wall`

### Commit: `rtl: add bfloat16_mul and fp32_acc arithmetic primitives`

**Files:**
```
rtl/lliu_pkg.sv
rtl/bfloat16_mul.sv
rtl/fp32_acc.sv
```

---

## Phase 2: Dot-Product Engine

**Goal:** Pipelined MAC that consumes a feature vector and weight vector, produces a scalar result.

### Steps

1. Implement `dot_product_engine.sv`
   - Parameterized vector length (default: 4 elements)
   - Sequencing FSM: IDLE → COMPUTE (iterate over elements) → DONE
   - Instantiates `bfloat16_mul` and `fp32_acc`
   - Inputs: feature element (bfloat16), weight element (bfloat16), start signal
   - Output: float32 result + result-valid strobe
   - Accumulator clears on `start`, iterates vector length cycles, asserts `result_valid`
2. Implement `weight_mem.sv`
   - Simple single-port SRAM (no double-buffering yet)
   - Write port: address + data + write-enable (for AXI4-Lite loads)
   - Read port: address → bfloat16 weight out (one per cycle to dot-product engine)
   - Parameterized depth matching vector length
3. Implement `output_buffer.sv`
   - Single float32 register
   - Write: latched on `result_valid` from dot-product engine
   - Read: presented on AXI4-Lite read data bus
4. Lint all with Verilator

### Commit: `rtl: add dot_product_engine, weight_mem, output_buffer`

**Files:**
```
rtl/dot_product_engine.sv
rtl/weight_mem.sv
rtl/output_buffer.sv
```

---

## Phase 3: ITCH Parser

**Goal:** AXI4-Stream ingress that aligns ITCH 5.0 messages and extracts Add Order fields.

### Steps

1. Implement `itch_field_extract.sv`
   - Pure combinational field slicer
   - Input: aligned message bytes (enough to cover a full Add Order message)
   - Output: message_type (8-bit), order_ref (64-bit), side (1-bit buy/sell), price (32-bit), fields_valid
   - Only asserts `fields_valid` for message type `8'h41` ('A' = Add Order)
2. Implement `itch_parser.sv`
   - AXI4-Stream slave interface: `tdata[63:0]`, `tvalid`, `tready`, `tlast`
   - Message alignment FSM:
     - ITCH messages are length-prefixed (2-byte big-endian length field)
     - State machine: READ_LEN → ACCUMULATE → EMIT
     - Handles messages spanning multiple 8-byte beats
     - Handles multiple messages within a single beat (back-to-back)
   - Backpressure: deasserts `tready` when downstream stalls
   - Outputs aligned message bytes + `msg_valid` strobe to `itch_field_extract`
   - Passes through non-Add-Order messages (consumed and discarded)
3. Lint both with Verilator

### Commit: `rtl: add itch_parser and itch_field_extract`

**Files:**
```
rtl/itch_parser.sv
rtl/itch_field_extract.sv
```

---

## Phase 4: Feature Extractor

**Goal:** Transform raw parsed fields into model-ready bfloat16 feature vector.

### Steps

1. Implement `feature_extractor.sv`
   - Input: parsed fields from `itch_field_extract` (price, order_ref, side, fields_valid)
   - Output: bfloat16 feature vector (N elements) + `features_valid` strobe
   - Feature computations:
     - **Price delta:** current price minus last-seen price (stored in register), converted to bfloat16
     - **Side encoding:** buy = +1.0, sell = -1.0 in bfloat16
     - **Order flow accumulator:** running buy-sell imbalance counter, converted to bfloat16
     - **Normalized price:** price as bfloat16 (raw or shifted)
   - Integer-to-bfloat16 conversion logic (shift + truncate to 8-bit mantissa)
   - Pipeline register on output for timing closure
2. Lint with Verilator

### Commit: `rtl: add feature_extractor`

**Files:**
```
rtl/feature_extractor.sv
```

---

## Phase 5: AXI4-Lite Control Plane

**Goal:** Register interface for weight loading, configuration, and result readout.

### Steps

1. Implement `axi4_lite_slave.sv`
   - AXI4-Lite slave: AWADDR/AWVALID/AWREADY, WDATA/WSTRB/WVALID/WREADY, BRESP/BVALID/BREADY, ARADDR/ARVALID/ARREADY, RDATA/RRESP/RVALID/RREADY
   - Register map:
     - `0x00`: Control (start, reset, status)
     - `0x04`: Weight write data
     - `0x08`: Weight write address
     - `0x0C`: Result readout (float32 from output_buffer)
     - `0x10`: Configuration (vector length, enable bits)
   - Write path: decodes address, drives `weight_mem` write port or config registers
   - Read path: muxes result from `output_buffer` or status registers
   - Single outstanding transaction (no pipelining needed)
2. Lint with Verilator

### Commit: `rtl: add axi4_lite_slave`

**Files:**
```
rtl/axi4_lite_slave.sv
```

---

## Phase 6: Top-Level Integration

**Goal:** Wire all modules together into `lliu_top` with clean AXI interfaces.

### Steps

1. Implement `lliu_top.sv`
   - Ports:
     - AXI4-Stream slave (ITCH ingress)
     - AXI4-Lite slave (control plane)
     - Clock, reset
   - Internal wiring:
     - `itch_parser` → `itch_field_extract` → `feature_extractor` → `dot_product_engine`
     - `axi4_lite_slave` → `weight_mem` (write path)
     - `weight_mem` → `dot_product_engine` (read path)
     - `dot_product_engine` → `output_buffer` → `axi4_lite_slave` (read path)
   - Pipeline valid/ready handshakes between stages
   - Reset sequence: all FSMs return to IDLE, accumulators clear
2. Lint full hierarchy with Verilator: `verilator --lint-only -Wall rtl/lliu_top.sv`

### Commit: `rtl: add lliu_top system integration`

**Files:**
```
rtl/lliu_top.sv
```

---

## Phase 7: Lint Clean + Interface Hardening

**Goal:** Full hierarchy passes Verilator lint with zero warnings. Interfaces are spec-compliant.

### Steps

1. Run `verilator --lint-only -Wall -Wno-fatal` on full hierarchy, fix all warnings
2. Review all AXI4-Stream handshakes: `tvalid` must not depend on `tready` (AXI rule)
3. Review all AXI4-Lite handshakes: no combinational loops between valid/ready pairs
4. Add `default` cases to all `case`/`casez` statements
5. Ensure no latches (all `always_ff` or `always_comb` with full assignments)
6. Verify parameterization: vector length change propagates cleanly through hierarchy
7. Add top-level Makefile with `make lint` target

### Commit: `rtl: lint clean, interface hardening, Makefile`

**Files:**
```
Makefile (or rtl/Makefile)
rtl/*.sv (fixes only)
```

---

## Summary

| Phase | Commit Message | Key Modules |
|-------|---------------|-------------|
| 1 | `rtl: add bfloat16_mul and fp32_acc arithmetic primitives` | `bfloat16_mul`, `fp32_acc`, `lliu_pkg` |
| 2 | `rtl: add dot_product_engine, weight_mem, output_buffer` | `dot_product_engine`, `weight_mem`, `output_buffer` |
| 3 | `rtl: add itch_parser and itch_field_extract` | `itch_parser`, `itch_field_extract` |
| 4 | `rtl: add feature_extractor` | `feature_extractor` |
| 5 | `rtl: add axi4_lite_slave` | `axi4_lite_slave` |
| 6 | `rtl: add lliu_top system integration` | `lliu_top` |
| 7 | `rtl: lint clean, interface hardening, Makefile` | All (fixes), Makefile |

**After Phase 7, the RTL is complete and ready for both verification tracks.**
