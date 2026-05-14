# Phase 4 Verification Summary

## Overview

Full cocotb testbench for the `kc705_top` HFT SoC, targeting the complete pipeline from
ITCH 5.0 message ingestion through inference, risk checking, and OUCH order output.

- **Simulator:** Verilator 5.046 with `--coverage-line --timing`
- **Framework:** cocotb 2.0.1
- **DUT:** kc705_top (Kintex-7 KC705 HFT SoC)
- **Clock domains:** clk_156 (156.25 MHz network), clk_300 (312.5 MHz application)

## Test Results

| Metric | Value |
|--------|-------|
| Total tests | 68 |
| Passed | 68 |
| Failed | 0 |
| Simulation time | ~5,170 us |
| Wall-clock time | ~52 s |

## Coverage Results

### DUT Module Coverage (target: 95%)

| Scope | Lines Hit | Total | Coverage |
|-------|-----------|-------|----------|
| **DUT modules (rtl/)** | **1,958** | **2,015** | **97.2%** |
| DUT excl. pcie_dma_engine | 1,780 | 1,809 | 98.4% |
| External modules (verilog-ethernet) | 2,000 | 2,923 | 68.4% |
| All modules combined | 3,958 | 4,938 | 80.2% |

### DUT Modules at 100% Coverage (15 of 22 modules)

bfloat16_mul, dot_product_engine, itch_parser_v2, kc705_top,
latency_histogram, lliu_core, lliu_top_v2, ouch_engine, output_buffer,
ptp_core, risk_check, strategy_arbiter, symbol_filter, timestamp_tap, weight_mem

### DUT Modules Below 100%

| Module | Hit/Total | Coverage | Gap Reason |
|--------|-----------|----------|------------|
| pcie_dma_engine.sv | 178/206 | 86.4% | BAR0 sim stub (21 lines); snap_done bug (7 lines) |
| order_book.sv | 297/302 | 98.3% | Replace-side bug (Bug #5); FSM defaults |
| fp32_acc.sv | 168/171 | 98.2% | Deep mantissa renormalization (rare) |
| snapshot_mux.sv | 38/39 | 97.4% | FSM default state (unreachable) |
| feature_extractor_v2.sv | 274/287 | 95.5% | Dead code function; VWAP zero-div |
| moldupp64_strip.sv | 105/110 | 95.5% | Header truncation edge cases |
| eth_axis_rx_wrap.sv | 16/18 | 88.9% | Dropped-frames saturation counter |

### Uncoverable Lines Analysis

- **pcie_dma_engine BAR0 handler (21 lines):** `ax_rx_tvalid` is hardcoded to `1'b0` in the
  simulation stub. Real PCIe TLP traffic requires Vivado IP (pcie_7x_0) which is not
  synthesizable in Verilator. These lines are exercisable only in FPGA synthesis with a
  PCIe BFM or real host.

- **pcie_dma_engine snap_done race (7 lines):** Genuine RTL bug (Bug #7) makes the staging
  capture completion path unreachable. `snap_done` and `snap_valid` never overlap due to
  combinational vs registered timing in snapshot_mux.

- **feature_extractor_v2 mag_to_bf16 (13 lines):** Function is defined but never called
  from any procedural code path — dead code.

### External Module Coverage Gaps

The Forencich verilog-ethernet library TX paths (`ip_eth_tx_64`, `udp_ip_tx_64`,
`udp_checksum_gen_64`) are at 35-48% coverage because the DUT has no Ethernet TX
functionality — all TX inputs are tied off in `kc705_top.sv`.

## Bugs Found

8 bugs documented in `reports/bugs_found.md`:

1. **Order book BBO bid comparison inverted** (CRITICAL, fixed) — blocked all OUCH output
2. **Parser price field off-by-one** (HIGH, fixed) — wrong prices for A/F/C/P messages
3. **Parser accumulate transition off-by-one** (MEDIUM, fixed) — `>` vs `>=` boundary
4. **eth_axis_rx_wrap drop decision operand swap** (LOW, documented)
5. **Replace message side always sell** (design limitation, documented)
6. **Forencich stack drops 8-byte UDP payloads** (external, worked around)
7. **PCIe DMA snap_done/snap_valid timing race** (HIGH, documented) — DMA hangs forever
8. **PCIe DMA CDC rising-edge only detection** (LOW, documented) — alternating triggers lost

## Pipeline Verification

End-to-end pipeline traced and verified:

```
Parser (cycle 0) → Symbol Filter watchlist_hit (cycle 3) → Feature Extractor
features_valid (cycle 3) → Core features_valid (cycle 10) → Core result_valid
(cycle 72, score=7.47M) → Arbiter best_valid (cycle 75) → Risk pass (cycle 81)
→ OUCH packet (6 beats)
```

Total pipeline latency: ~93 cycles from parser to OUCH output at 312.5 MHz.

## Test Categories

### Functional Tests (30 tests)
- Pipeline smoke, all ITCH types, multi-symbol, backpressure, AXI-Lite readback,
  sequence gap, burst messages, rapid-fire, kill switch, short frame, weight loading,
  end-to-end BBO inference, order book operations, histogram reads, order book stress,
  multi-symbol BBO, risk edge cases, PCIe DMA snapshot, score threshold, continuous flow

### Direct Injection Tests (10 tests)
- Direct injection, multi-symbol injection, burst injection, risk fail injection,
  kill switch injection, all types injection, book depth, score threshold,
  pipeline trace, pipeline debug

### Coverage-Targeted Tests (16 tests)
- Order book replace/execute paths, hash collision probing, arbiter tournament tree,
  OUCH backpressure mid-packet, parser edge cases (short/truncated messages),
  MoldUDP64 malformed frames, multi-OUCH end-to-end, BBO clearing paths,
  forced hash collisions, AXI-Lite register coverage, truncated accumulate,
  OUCH overflow, max-probe collision, execute-to-zero

### PCIe DMA & Infrastructure Tests (12 tests)
- PCIe DMA FSM exercise (force bar0_ctrl_r, timer, TLP generation)
- PCIe DMA armed descriptor (force DMA_DESCR_LAT → DMA_TLP)
- PCIe DMA CAPT_WAIT force (force through bug-blocked states)
- PCIe DMA capt_done force (attempt staging capture completion)
- PCIe DMA long run (natural timer trigger + force recovery)
- Snapshot rapid toggle, ARP processing, IP error paths
- FIFO pressure (back-to-back frames + output back-pressure)
- Risk all block reasons, histogram bin update, order book default paths
- bfloat16/fp32 extreme values, feature VWAP zero-volume
- eth_rx_wrap drop saturation, MoldUDP64 truncation edges
- Full-fill execution at BBO, replace BBO improvement

## Files Modified

| File | Change |
|------|--------|
| `rtl/order_book.sv` | Fixed BBO bid comparison (line 450) |
| `rtl/itch_parser_v2.sv` | Fixed price offset and transition condition |
| `rtl/kc705_top.sv` | Added sim_itch_inject MUX, byte-swap fix |
| `tb/test_kc705.py` | Complete testbench: 68 tests, ~4600 lines |
| `tb/Makefile` | Coverage flags, test target |
| `tb/gen_coverage.py` | DUT vs external module coverage separation |
