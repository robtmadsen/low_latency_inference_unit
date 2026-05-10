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

```systemverilog
`ifdef KINTEX7_SIM_GTX_BYPASS
    // Replace SFP+ GTX transceiver with direct AXI4-S stimulus
    assign u_eth_rx.mac_rx_tdata  = sim_mac_tdata;
    assign u_eth_rx.mac_rx_tvalid = sim_mac_tvalid;
`endif
```

This allows cocotb and UVM testbenches to inject raw Ethernet frames without instantiating the full GTX transceiver model.

## I/O Pin Notes

Pin assignments in `syn/constraints.xdc` (Section 4) are taken from the KC705 reference design (xc7k325tffg900-2). **These pin names are for reference only** and must be re-assigned when targeting the actual xc7k160tffg676-2 package. The -2 device uses a 676-pin FFG package; key differences include SFP+ cage pin locations and PCIe edge connector mapping.
