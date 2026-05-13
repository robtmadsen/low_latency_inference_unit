# `kc705_top` — KC705 Board-Level Integrator

> Part of [SYSTEM.md](SYSTEM.md) · **Root module of synthesized design**

## Purpose

Board-level top module for the Xilinx KC705 evaluation board (Kintex-7 xc7k160tffg676-2). Instantiates the 156.25 MHz Ethernet ingress network (SFP+ 10GbE → UDP → MoldUDP64 → CDC FIFO) feeding the 312.5 MHz `lliu_top_v2` inference engine, plus the `pcie_dma_engine` for host memory offload.

## Ports

### Clocks and Reset

| Port | Dir | Description |
|------|-----|-------------|
| `sys_clk_p` / `sys_clk_n` | in | 200 MHz differential board clock |
| `cpu_reset` | in | Active-high push-button reset |
| `mgt_refclk_p` / `mgt_refclk_n` | in | 156.25 MHz SFP+ MGT reference clock |

### SFP+ 10GbE

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `sfp_rx_p` / `sfp_rx_n` | in | 1 | Differential RX serial |
| `sfp_tx_p` / `sfp_tx_n` | out | 1 | Differential TX serial |
| `sfp_tx_disable` | out | 1 | Drive low to enable laser |
| `sfp_rs` | out | 2 | Rate select pins (tie to 2'b00 for 10G) |

### AXI4-Lite (from host via PCIe BAR1)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `axil_awaddr` | in | 12 | LLIU control write address |
| `axil_awvalid` | in | 1 | |
| `axil_awready` | out | 1 | |
| `axil_wdata` | in | 32 | |
| `axil_wvalid` | in | 1 | |
| `axil_wready` | out | 1 | |
| `axil_bresp` | out | 2 | |
| `axil_bvalid` | out | 1 | |
| `axil_bready` | in | 1 | |
| `axil_araddr` | in | 12 | |
| `axil_arvalid` | in | 1 | |
| `axil_arready` | out | 1 | |
| `axil_rdata` | out | 32 | |
| `axil_rresp` | out | 2 | |
| `axil_rvalid` | out | 1 | |
| `axil_rready` | in | 1 | |

### PCIe Gen2 ×4

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `pcie_tx_p` / `pcie_tx_n` | out | 4 | PCIe TX lanes |
| `pcie_rx_p` / `pcie_rx_n` | in | 4 | PCIe RX lanes |
| `pcie_refclk_p` / `pcie_refclk_n` | in | 1 | 100 MHz PCIe reference |
| `pcie_rst_n` | in | 1 | PCIe reset |

### OUCH 5.0 Egress (to SFP+ TX or host loopback in sim)

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `m_axis_tdata` | out | 64 | OUCH byte stream |
| `m_axis_tkeep` | out | 8 | Byte enables |
| `m_axis_tvalid` | out | 1 | |
| `m_axis_tlast` | out | 1 | |
| `m_axis_tready` | in | 1 | |

### Monitoring / Debug

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `collision_count_out` | out | 32 | Hash collision count from `order_book` |
| `tx_overflow_out` | out | 1 | OUCH TX backpressure watchdog |
| `dropped_frames_out` | out | 32 | MAC-level frame drops from `eth_axis_rx_wrap` |
| `dropped_datagrams_out` | out | 32 | MoldUDP64 sequence drops from `moldupp64_strip` |
| `expected_seq_num_out` | out | 64 | Expected next MoldUDP64 sequence number |

## Submodule Instances

| Instance | Module | Clock domain | Description |
|----------|--------|-------------|-------------|
| `u_eth_rx` | `eth_axis_rx_wrap` | `net_clk` (156.25 MHz) | 10GbE MAC RX, drop-on-full |
| `u_udp` | `udp_complete_64` | `net_clk` | UDP/IP demux (Forencich verilog-ethernet) |
| `u_mold` | `moldupp64_strip` | `net_clk` | MoldUDP64 header stripper |
| `u_cdc` | `axis_async_fifo` | net_clk → sys_clk | Clock-domain crossing FIFO |
| `u_lliu` | `lliu_top_v2` | `sys_clk` (312.5 MHz) | Inference + OUCH engine |
| `u_pcie` | `pcie_dma_engine` | `sys_clk` / `user_clk` | PCIe DMA to host |

## Clock Generation

An MMCM (Vivado `clk_wiz_0` IP) accepts the 200 MHz board clock and generates:
- `sys_clk`: 312.5 MHz — drives `lliu_top_v2` and `pcie_dma_engine.sys_clk`.
- `net_clk`: 156.25 MHz — drives Ethernet ingress chain.

The 156.25 MHz MGT reference clock drives the SFP+ transceiver (10GBASE-R PCS/PMA via `ten_gig_eth_pcs_pma` IP).

## Simulation Bypass

When `KINTEX7_SIM_GTX_BYPASS` is defined, additional top-level ports are conditionally compiled into the port list:

```systemverilog
`ifdef KINTEX7_SIM_GTX_BYPASS
    ,
    input  logic        clk_156_in,
    input  logic        clk_300_in,
    input  logic [63:0] mac_rx_tdata,
    input  logic [7:0]  mac_rx_tkeep,
    input  logic        mac_rx_tvalid,
    input  logic        mac_rx_tlast,
    output logic        mac_rx_tready,
    output logic        fifo_rd_tvalid
`endif
```

The testbench drives these ports directly — there are no hierarchical assigns into submodule internals. See the [Simulation Bypass (`KINTEX7_SIM_GTX_BYPASS`)](#simulation-bypass-kintex7_sim_gtx_bypass) section below for full port descriptions and usage notes.

## Clock Domain Crossing (CDC)

### Overview

`kc705_top` contains exactly one CDC boundary. ITCH message data crosses from the **156.25 MHz** Ethernet ingress domain (`clk_156`) to the **312.5 MHz** inference domain (`clk_300`) via a single `axis_async_fifo` instance (`u_async_fifo`, Forencich verilog-ethernet).

All other inter-domain signals (monitoring counters) are handled by a separate 2-FF re-sampling chain described below.

### `axis_async_fifo` Parameters

| Parameter | Value | Notes |
|-----------|-------|-------|
| `DEPTH` | 128 | Entries; `s_status_depth` is 8 bits |
| `DATA_WIDTH` | 64 | One 64-bit ITCH word per beat |
| `KEEP_ENABLE` | 1 | `tkeep` forwarded but not used downstream |
| `KEEP_WIDTH` | 8 | One keep bit per byte |
| `LAST_ENABLE` | 1 | `tlast` forwarded |
| `ID_ENABLE` | 0 | Unused |
| `DEST_ENABLE` | 0 | Unused |
| `USER_ENABLE` | 0 | Unused |
| `RAM_PIPELINE` | 1 | One register stage on read side |
| `FRAME_FIFO` | 0 | Non-frame-aware mode |

### Port Mapping

| FIFO port | Connected signal | Domain | Description |
|-----------|-----------------|--------|-------------|
| `s_clk` | `clk_156` | write | 156.25 MHz Ethernet domain clock |
| `s_rst` | `rst_156` | write | Synchronous deassert on `clk_156` |
| `s_axis_tdata` | `itch_net_tdata[63:0]` | write | ITCH stream from `moldupp64_strip` |
| `s_axis_tkeep` | `itch_net_tkeep[7:0]` | write | |
| `s_axis_tvalid` | `itch_net_tvalid` | write | |
| `s_axis_tready` | `itch_net_tready` | write | Back-pressure to `moldupp64_strip` |
| `s_axis_tlast` | `itch_net_tlast` | write | |
| `s_status_depth` | `fifo_s_depth[7:0]` | write | Current write-side fill level |
| `m_clk` | `clk_300` | read | 312.5 MHz inference domain clock |
| `m_rst` | `rst_300` | read | Synchronous deassert on `clk_300` |
| `m_axis_tdata` | `itch_300_tdata[63:0]` | read | ITCH stream to byte-swapper |
| `m_axis_tvalid` | `itch_300_tvalid` | read | Also drives `fifo_rd_tvalid` output |
| `m_axis_tready` | `itch_300_tready` | read | Driven by `lliu_top_v2` |
| `m_axis_tlast` | `itch_300_tlast` | read | |

### Drop-on-Full Policy

`eth_axis_rx_wrap` implements a drop-on-full policy driven by `fifo_almost_full`:

```
assign fifo_almost_full = (fifo_s_depth >= 8'd64);
```

When `fifo_almost_full` is asserted (FIFO more than half full), `eth_axis_rx_wrap` asserts its internal drop signal and discards the current Ethernet frame, incrementing `dropped_frames_out`. This prevents FIFO overflow at the cost of frame loss under sustained overload. The threshold of 64 provides headroom for one maximum ITCH-message burst per MAS §2.3.

### Byte-Swap Between Domains

`moldupp64_strip` outputs ITCH data in **little-endian** order (byte 0 → `tdata[7:0]`). `itch_parser_v2` inside `lliu_top_v2` expects **big-endian** (first byte of the ITCH message at `tdata[63:56]`). `kc705_top` performs a 64-bit byte-reversal on the FIFO read-side output before passing the stream into `lliu_top_v2`:

```
assign itch_300_tdata_swapped = {
    itch_300_tdata[7:0],   itch_300_tdata[15:8],
    itch_300_tdata[23:16], itch_300_tdata[31:24],
    itch_300_tdata[39:32], itch_300_tdata[47:40],
    itch_300_tdata[55:48], itch_300_tdata[63:56]
};
```

### `fifo_rd_tvalid` Output

`fifo_rd_tvalid` is an additional top-level output (present only under `KINTEX7_SIM_GTX_BYPASS`) assigned directly from `itch_300_tvalid` (the FIFO read-side `m_axis_tvalid`). Its purpose is to provide a clean cycle-accurate observable for SVA latency assertions — testbenches use it to start the latency measurement clock when the first ITCH beat exits the CDC FIFO.

### Reset Synchronizers

Each clock domain has an independent 2-FF synchronizer that asynchronously asserts and synchronously deasserts reset:

```systemverilog
// clk_300 domain
always_ff @(posedge clk_300 or posedge cpu_reset) begin
    if (cpu_reset) rst_300_sr <= 2'b11;
    else           rst_300_sr <= {rst_300_sr[0], 1'b0};
end
assign rst_300 = rst_300_sr[1];

// clk_156 domain
always_ff @(posedge clk_156 or posedge cpu_reset) begin
    if (cpu_reset) rst_156_sr <= 2'b11;
    else           rst_156_sr <= {rst_156_sr[0], 1'b0};
end
assign rst_156 = rst_156_sr[1];
```

Both resets source from the same `cpu_reset` active-high push-button. They deassert independently on their own clock edges; `rst_300` will deassert 2 × 3.2 ns = 6.4 ns after `cpu_reset` falls, and `rst_156` will deassert 2 × 6.4 ns = 12.8 ns after `cpu_reset` falls. The `axis_async_fifo` requires its write-side reset (`s_rst`) to remain asserted for at least one full write clock cycle, and similarly for the read side — both conditions are satisfied.

### Monitoring Counter Resampling

The 32-bit counters `dropped_frames_out`, `dropped_datagrams_out`, and the 64-bit `expected_seq_num_out` are produced in the `clk_156` domain. They are re-sampled into `clk_300` via a 2-stage FF chain (no handshake). Because these counters are monotonically increasing, an occasional glitch from the metastability window introduces at most a transient under-read of the count but never corrupts the long-term value.

## Simulation Bypass (`KINTEX7_SIM_GTX_BYPASS`)

> **Define value:** `KINTEX7_SIM_GTX_BYPASS` is a **presence-only flag** — it takes no value. Pass it to Verilator as `-DKINTEX7_SIM_GTX_BYPASS` (on the command line) or `+define+KINTEX7_SIM_GTX_BYPASS` (in a tool `.f` file). Do **not** assign a numeric or string value; any value will be silently ignored by the preprocessor, but the intent is purely a flag.
>
> **Required for simulation:** This define **must** be set whenever `kc705_top` is compiled under Verilator. Without it, `clk_300` and `clk_156` are undriven (IBUFDS/MMCM_ADV/GTX primitives are not compiled), the simulation-only ports are absent, and the design will elaborate but be completely nonfunctional — all datapath signals are zero-assigned stubs.
>
> **Must not be set for synthesis:** Do not pass this define when invoking Vivado or Yosys. Synthesis must see the hardware clock/reset path and the real GTX transceiver instantiation.

When the define is set, the following additional top-level ports are exposed (added after the last normal port via a conditional port list):

| Port | Dir | Width | Description |
|------|-----|-------|-------------|
| `clk_156_in` | in | 1 | Replaces GTX recovered clock; testbench drives at 6.4 ns period |
| `clk_300_in` | in | 1 | Replaces MMCM output; testbench drives at 3.33 ns period |
| `mac_rx_tdata` | in | 64 | Ethernet frame data (testbench drives full frames) |
| `mac_rx_tkeep` | in | 8 | Byte enables |
| `mac_rx_tvalid` | in | 1 | |
| `mac_rx_tlast` | in | 1 | |
| `mac_rx_tready` | out | 1 | |
| `fifo_rd_tvalid` | out | 1 | CDC FIFO read-side valid; used by SVA latency checker |

Both clock inputs may be tied to the same signal for single-clock simulation. When running dual-clock, the testbench must drive `clk_156_in` and `clk_300_in` with phase-independent clocks (no fixed phase relationship is required or expected by the design).

## I/O Pin Notes

Pin assignments in `syn/constraints.xdc` (Section 4) are taken from the KC705 reference design (xc7k325tffg900-2). **These pin names are for reference only** and must be re-assigned when targeting the actual xc7k160tffg676-2 package. The -2 device uses a 676-pin FFG package; key differences include SFP+ cage pin locations and PCIe edge connector mapping.
