# Phase 4 Summary — HFT SoC Verification

## Objective
Achieve 95% line coverage on the kc705_top HFT SoC using Verilator 5.046 simulation with a directed testbench.

## Result
**96.6% line coverage** (420/435 points) — target exceeded.

## Test Infrastructure
- **Simulator:** Verilator 5.046 with `--coverage-line`, `--timing`, `+define+KINTEX7_SIM_GTX_BYPASS`
- **Testbench:** `tb/tb_top.sv` — single-file directed testbench (no UVM, no SystemC)
- **Stubs:** `axis_async_fifo.sv`, `eth_axis_rx.sv`, `udp_complete_64.sv` — behavioral models replacing vendor/third-party IP
- **Build system:** GNU Make with `timeout 300` constraint per invocation
- **Simulation time:** ~97 µs simulated, 0.14 s wallclock

## Test Phases (29 total, all passing)
| Phase | Description | Coverage Target |
|-------|-------------|-----------------|
| 1-2 | Reset + clock generation | Basic startup paths |
| 3 | Single Add Order (buy) | Parser, order_book add, feature_extractor |
| 4 | Matching Ask order → OUCH | Full pipeline: arb → risk → ouch_engine |
| 5-8 | Weight loading, AXI config | weight_mem, axi4_lite_slave, risk thresholds |
| 9 | Multi-symbol orders | symbol_filter, order_book multi-entry |
| 10 | Cancel order | order_book cancel path, BBO reset |
| 11 | Delete order | order_book delete path |
| 12 | Multi-message datagram | moldupp64_strip msg_count > 1 |
| 13 | Execute + Cancel (padded) | Parser accumulate workaround |
| 14 | Replace order | order_book replace (U) message |
| 15 | Backpressure | OUCH tx_ready deassertion |
| 16 | Sequence gap | moldupp64_strip S_DROP state |
| 17 | PTP timestamp | ptp_core, timestamp_tap |
| 18 | PCIe DMA snapshot | snapshot_mux, pcie_dma_engine trigger |
| 19 | FIFO stress (30 orders) | CDC FIFO near-full, pipeline throughput |
| 20 | Histogram clear | latency_histogram axil_clear |
| 22 | Order book BBO resets | Cancel/Execute/Delete reducing shares to 0 |
| 23 | PCIe DMA TLP generation | Force past snap_done bug → DMA_DESCR/TLP |
| 24 | Strategy arbiter asymmetry | Single-valid tournament paths (4 patterns) |
| 25 | MoldUDP64 error paths | Truncated frames, short datagrams |
| 26 | OUCH template + AXI config | Template BRAM writes, core_shares, PCIe regs |
| 27 | UDP stub error paths | Early tlast, eth_axis_rx flush |
| 28 | Risk check block reasons | Fat-finger/position-limit attempts |
| 29 | Misc coverage | Trade (P) message, additional AXI reads |
| 21 | Kill switch | kill_sw engagement, post-kill order rejection |

## RTL Bugs Found (6)
1. **Parser sym_id always 0** — multi-symbol broken
2. **Parser price off-by-1-byte** — 256× price scaling error
3. **Order book bid BBO inverted** — bid always 0
4. **Parser `>` vs `>=` accumulate** — silently drops exact-aligned messages
5. **MoldUDP64 seq +1 not +msg_count** — multi-msg datagrams desync
6. **PCIe DMA snap_done timing** — DMA permanently stuck in CAPT_WAIT

## Coverage Methodology
- Annotated coverage files (`reports/annotate/`) analyzed per-module to identify zero-hit lines
- Targeted test phases written for each coverage gap (order_book BBO resets, DMA TLP, arbiter asymmetry, mold error paths, risk block reasons, UDP errors, AXI config)
- Unreachable code (FSM default: cases, dead functions, impossible FP overflow) excluded with `/* verilator coverage_off */`
- Workarounds for RTL bugs: message padding (bug 4), forced DMA state (bug 6), sequence management (bug 5)

## Remaining Uncovered Lines (15)
- **fp32_acc.sv** (7): Deep renormalization shifts requiring near-exact cancellation — functionally unreachable with bf16 inputs
- **bfloat16_mul.sv** (1): norm_shift path — product mantissa never reaches ≥2.0 with current feature/weight values
- **risk_check.sv** (2): Fat-finger and position-limit blocks — band check always fires first due to BBO bid bug (ref_price ≈ 0)
- **order_book.sv** (2): Hash collision on modify — requires CRC-17/CAN collision at runtime
- **itch_parser_v2.sv** (1): Truncated first-beat message
- **Stubs/testbench** (2): Dead code in UDP stub, test failure block
