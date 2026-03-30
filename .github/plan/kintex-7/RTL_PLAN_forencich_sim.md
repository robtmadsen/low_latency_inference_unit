# RTL Plan — Forencich IP Simulation Integration

**Agent:** `rtl_engineer`  
**Spec:** [Kintex-7_MAS.md §6](../../arch/kintex-7/Kintex-7_MAS.md)  
**Depends on:** `lib/verilog-ethernet/` submodule initialised (see MAS §6.1)  
**Writes to:** `rtl/kc705_top.sv`, `rtl/eth_axis_rx_wrap.sv`  
**Must not write:** any file in `tb/`, `.github/workflows/`, or `syn/`

---

## Overview

The `KINTEX7_SIM_MAC_BYPASS` macro historically bypassed three simulatable Forencich
modules (`ip_complete_64`, `udp_complete_64`, `axis_async_fifo`) in addition to the
unavoidable hardware primitives (GTX, IBUFDS, MMCM). This plan closes that gap.

```
Before (KINTEX7_SIM_MAC_BYPASS):
  mac_rx_* → eth_axis_rx_wrap → ─────────────────────────────────────────────────────
                                  assign udp_payload_* = eth_wrap_*  (IP/UDP skipped)
                                ─────────────────────────────────────────────────────
                                → moldupp64_strip
                                  assign itch_300_* = itch_net_*  (FIFO skipped)
                                → itch_parser

After (KINTEX7_SIM_GTX_BYPASS):
  mac_rx_* → eth_axis_rx_wrap → ip_complete_64 → udp_complete_64 → moldupp64_strip
                                                                      → axis_async_fifo (clk_156→clk_300)
                                                                        → itch_parser
```

**Implementation steps, in order:**

```
[Step 1] Rename macro in kc705_top.sv
[Step 2] Update eth_axis_rx_wrap to expose Ethernet header fields
[Step 3] Instantiate ip_complete_64 and udp_complete_64 in kc705_top.sv
[Step 4] Instantiate axis_async_fifo in kc705_top.sv
[Step 5] Drive fifo_rd_tvalid from FIFO read-side output
[Step 6] Update lint command; confirm zero warnings
```

---

## Prerequisites

Before starting, confirm:

1. The `lib/verilog-ethernet/` submodule is initialised:
   ```sh
   git submodule update --init lib/verilog-ethernet/
   ls lib/verilog-ethernet/rtl/ip_complete_64.v   # must exist
   ls lib/verilog-ethernet/rtl/udp_complete_64.v  # must exist
   ls lib/verilog-ethernet/rtl/axis_async_fifo.v  # must exist
   ls lib/verilog-ethernet/rtl/eth_axis_rx.v      # must exist
   ```

2. The existing `kc705_top.sv` lint passes cleanly with the old macro:
   ```sh
   verilator --lint-only -Wall -sv --top-module kc705_top \
       -DKINTEX7_SIM_MAC_BYPASS \
       rtl/lliu_pkg.sv \
       rtl/bfloat16_mul.sv rtl/fp32_acc.sv rtl/dot_product_engine.sv \
       rtl/itch_parser.sv rtl/itch_field_extract.sv \
       rtl/feature_extractor.sv rtl/weight_mem.sv \
       rtl/axi4_lite_slave.sv rtl/output_buffer.sv \
       rtl/moldupp64_strip.sv rtl/symbol_filter.sv rtl/eth_axis_rx_wrap.sv \
       rtl/kc705_top.sv
   ```
   **Zero warnings required before proceeding.**

---

## Step 1 — Rename macro in `kc705_top.sv`

**File:** `rtl/kc705_top.sv`

Replace every occurrence of `KINTEX7_SIM_MAC_BYPASS` with `KINTEX7_SIM_GTX_BYPASS`.
This is a pure text substitution; no logic changes yet.

Occurrences to rename (search the full file):

| Location in file | Pattern to replace |
|------------------|--------------------|
| Header comment block (line 10 area) | `` `// KINTEX7_SIM_MAC_BYPASS`` → update comment text and macro name |
| Module port list `` `ifdef KINTEX7_SIM_MAC_BYPASS `` | → `` `ifdef KINTEX7_SIM_GTX_BYPASS `` |
| Clock assignment `` `ifdef KINTEX7_SIM_MAC_BYPASS `` | → `` `ifdef KINTEX7_SIM_GTX_BYPASS `` |
| Unused-signal suppress `` `ifdef KINTEX7_SIM_MAC_BYPASS `` | → `` `ifdef KINTEX7_SIM_GTX_BYPASS `` |
| `fifo_almost_full` assignment `` `ifdef KINTEX7_SIM_MAC_BYPASS `` | → `` `ifdef KINTEX7_SIM_GTX_BYPASS `` |
| `eth_axis_rx_wrap` instantiation block `` `ifdef KINTEX7_SIM_MAC_BYPASS `` | → `` `ifdef KINTEX7_SIM_GTX_BYPASS `` |
| CDC FIFO bypass block `` `ifdef KINTEX7_SIM_MAC_BYPASS `` | → `` `ifdef KINTEX7_SIM_GTX_BYPASS `` |

Also update the comment at the top of the file (around lines 10–17) to describe the new
boundary accurately:

```systemverilog
// KINTEX7_SIM_GTX_BYPASS (must be defined for Verilator lint/simulation):
//   - clk_156_in, clk_300_in replace IBUFDS/MMCM/GTX outputs.
//   - mac_rx_* exposed as top-level ports; testbench sends full Ethernet frames
//     (Ethernet + IPv4 + UDP + MoldUDP64 headers — see MAS §6.3).
//   - ip_complete_64, udp_complete_64, axis_async_fifo are instantiated and run
//     in simulation (not bypassed).
//   - fifo_rd_tvalid exposed for SVA latency measurement; driven from real
//     axis_async_fifo m_axis_tvalid.
//
// In synthesis (KINTEX7_SIM_GTX_BYPASS NOT defined):
//   Instantiate Forencich IP (eth_mac_phy_10g, ip_complete_64, udp_complete_64,
//   axis_async_fifo) with the standard Xilinx IBUFDS/IBUFDS_GTE2/MMCM_ADV
//   primitives. These modules are not in rtl/ and not compiled by Verilator.
```

**Lint check after Step 1:**
```sh
verilator --lint-only -Wall -sv --top-module kc705_top \
    -DKINTEX7_SIM_GTX_BYPASS \
    rtl/lliu_pkg.sv \
    rtl/bfloat16_mul.sv rtl/fp32_acc.sv rtl/dot_product_engine.sv \
    rtl/itch_parser.sv rtl/itch_field_extract.sv \
    rtl/feature_extractor.sv rtl/weight_mem.sv \
    rtl/axi4_lite_slave.sv rtl/output_buffer.sv \
    rtl/moldupp64_strip.sv rtl/symbol_filter.sv rtl/eth_axis_rx_wrap.sv \
    rtl/kc705_top.sv
```

Expected: zero warnings (same set as before the rename). If new warnings appear, fix
them before proceeding.

---

## Step 2 — Extend `eth_axis_rx_wrap` to expose Ethernet header fields

**File:** `rtl/eth_axis_rx_wrap.sv`

`ip_complete_64` requires Ethernet header fields (valid strobe, destination MAC,
source MAC, EtherType) in addition to the Ethernet payload stream. These fields are
already produced by the internal Forencich `eth_axis_rx` instance but are not
currently forwarded to `kc705_top`.

### 2a — Add four output ports to `eth_axis_rx_wrap`

```systemverilog
// New outputs — Ethernet header sideband (for ip_complete_64 input)
output logic        eth_hdr_valid,       // pulses 1 cycle when header captured
output logic [47:0] eth_dest_mac,        // destination MAC address
output logic [47:0] eth_src_mac,         // source MAC address
output logic [15:0] eth_type             // EtherType (0x0800 for IPv4)
```

Add these four ports to the module port list of `eth_axis_rx_wrap`.

### 2b — Wire internal `eth_axis_rx` header outputs to the new ports

Inside `eth_axis_rx_wrap`, wire the internal `eth_axis_rx` instance's header output
ports:

```systemverilog
assign eth_hdr_valid = u_eth_rx.output_eth_hdr_valid;
assign eth_dest_mac  = u_eth_rx.output_eth_dest_mac;
assign eth_src_mac   = u_eth_rx.output_eth_src_mac;
assign eth_type      = u_eth_rx.output_eth_type;
```

> **Note:** Verify the Forencich `eth_axis_rx` output port names from
> `lib/verilog-ethernet/rtl/eth_axis_rx.v` before writing this wiring. The expected
> names follow the Forencich `output_eth_*` convention, but the exact names must match
> the module definition in the checked-out submodule. Common alternatives include
> `m_eth_hdr_valid`, `m_eth_dest_mac`, `m_eth_src_mac`, `m_eth_type` (for modules
> that use `m_` prefix for master-side outputs).

### 2c — Suppress header outputs during drop mode

When `drop_current` is asserted (a frame is being silently consumed), suppress the
header valid strobe so `ip_complete_64` never sees a header for a dropped frame:

```systemverilog
assign eth_hdr_valid = u_eth_rx.output_eth_hdr_valid & ~drop_current;
```

The `eth_dest_mac`, `eth_src_mac`, and `eth_type` values do not need to be gated —
they are only consumed when `eth_hdr_valid` is asserted.

**Lint check after Step 2:**
```sh
verilator --lint-only -Wall -sv --top-module eth_axis_rx_wrap \
    rtl/lliu_pkg.sv rtl/eth_axis_rx_wrap.sv \
    lib/verilog-ethernet/rtl/eth_axis_rx.v
```

---

## Step 3 — Instantiate `ip_complete_64` and `udp_complete_64` in `kc705_top.sv`

**File:** `rtl/kc705_top.sv`

### 3a — Add intermediate wire declarations

Inside the `ifdef KINTEX7_SIM_GTX_BYPASS` block, after the `eth_axis_rx_wrap`
instantiation, add:

```systemverilog
    // Ethernet header fields from eth_axis_rx_wrap → ip_complete_64
    logic        eth_hdr_valid;
    logic [47:0] eth_dest_mac;
    logic [47:0] eth_src_mac;
    logic [15:0] eth_type;

    // eth_axis_rx_wrap payload → ip_complete_64 Ethernet payload input
    // (previously eth_wrap_* wired directly to udp_payload_*)
    logic [63:0] eth_wrap_tdata;
    logic [7:0]  eth_wrap_tkeep;
    logic        eth_wrap_tvalid;
    logic        eth_wrap_tlast;
    logic        eth_wrap_tready;

    // ip_complete_64 payload output → udp_complete_64 input
    logic        ip_hdr_valid;
    logic [47:0] ip_eth_dest_mac;
    logic [47:0] ip_eth_src_mac;
    logic [15:0] ip_eth_type;
    logic [5:0]  ip_dscp;
    logic [1:0]  ip_ecn;
    logic [15:0] ip_length;
    logic [7:0]  ip_ttl;
    logic [7:0]  ip_protocol;
    logic [15:0] ip_header_checksum;
    logic [31:0] ip_source_ip;
    logic [31:0] ip_dest_ip;
    logic [63:0] ip_payload_tdata;
    logic [7:0]  ip_payload_tkeep;
    logic        ip_payload_tvalid;
    logic        ip_payload_tlast;
    logic        ip_payload_tready;

    // udp_complete_64 payload output → moldupp64_strip (udp_payload_*)
    logic [15:0] udp_hdr_src_port;
    logic [15:0] udp_hdr_dest_port;
    logic [15:0] udp_length;
    logic        udp_hdr_valid;
```

> **Note:** The exact intermediate wire types and widths for the header sideband
> between `ip_complete_64` and `udp_complete_64` depend on the Forencich module port
> definitions. The declarations above represent the expected IP→UDP sideband. Verify
> against the checked-out source and adjust widths accordingly.

### 3b — Update `eth_axis_rx_wrap` instantiation to connect header ports

Add the four new ports to the existing `eth_axis_rx_wrap` instantiation:

```systemverilog
    eth_axis_rx_wrap u_eth_rx_wrap (
        .clk                (clk_156),
        .rst                (rst_156),
        .mac_rx_tdata       (mac_rx_tdata),
        .mac_rx_tkeep       (mac_rx_tkeep),
        .mac_rx_tvalid      (mac_rx_tvalid),
        .mac_rx_tlast       (mac_rx_tlast),
        .mac_rx_tready      (mac_rx_tready),
        .eth_payload_tdata  (eth_wrap_tdata),
        .eth_payload_tkeep  (eth_wrap_tkeep),
        .eth_payload_tvalid (eth_wrap_tvalid),
        .eth_payload_tlast  (eth_wrap_tlast),
        .eth_payload_tready (eth_wrap_tready),
        // New: Ethernet header sideband for ip_complete_64
        .eth_hdr_valid      (eth_hdr_valid),
        .eth_dest_mac       (eth_dest_mac),
        .eth_src_mac        (eth_src_mac),
        .eth_type           (eth_type),
        .fifo_almost_full   (fifo_almost_full),
        .dropped_frames     (dropped_frames_156)
    );
```

### 3c — Remove the bypass wire-through

Delete or `ifdef`-guard out the old bypass assigns:

```systemverilog
    // DELETE these lines (they were the bypass):
    // assign udp_payload_tdata  = eth_wrap_tdata;
    // assign udp_payload_tkeep  = eth_wrap_tkeep;
    // assign udp_payload_tvalid = eth_wrap_tvalid;
    // assign udp_payload_tlast  = eth_wrap_tlast;
    // assign eth_wrap_tready    = udp_payload_tready;
```

### 3d — Instantiate `ip_complete_64`

```systemverilog
    ip_complete_64 #(
        // No parameters expected for basic configuration; verify from source.
    ) u_ip (
        .clk                            (clk_156),
        .rst                            (rst_156),

        // Configuration (static)
        .local_mac                      (48'h020000000001),
        .local_ip                       (32'hE9360C00),    // 233.54.12.0
        .gateway_ip                     (32'h0A000001),    // 10.0.0.1
        .subnet_mask                    (32'hFFFFFF00),

        // Ethernet input (from eth_axis_rx_wrap)
        .s_eth_hdr_valid                (eth_hdr_valid),
        .s_eth_dest_mac                 (eth_dest_mac),
        .s_eth_src_mac                  (eth_src_mac),
        .s_eth_type                     (eth_type),
        .s_eth_payload_axis_tdata       (eth_wrap_tdata),
        .s_eth_payload_axis_tkeep       (eth_wrap_tkeep),
        .s_eth_payload_axis_tvalid      (eth_wrap_tvalid),
        .s_eth_payload_axis_tready      (eth_wrap_tready),
        .s_eth_payload_axis_tlast       (eth_wrap_tlast),
        .s_eth_payload_axis_tuser       (1'b0),

        // IP output (to udp_complete_64 or a drop node)
        .m_ip_hdr_valid                 (ip_hdr_valid),
        .m_ip_eth_dest_mac              (ip_eth_dest_mac),
        .m_ip_eth_src_mac               (ip_eth_src_mac),
        .m_ip_eth_type                  (ip_eth_type),
        .m_ip_dscp                      (ip_dscp),
        .m_ip_ecn                       (ip_ecn),
        .m_ip_length                    (ip_length),
        .m_ip_ttl                       (ip_ttl),
        .m_ip_protocol                  (ip_protocol),
        .m_ip_header_checksum           (ip_header_checksum),
        .m_ip_source_ip                 (ip_source_ip),
        .m_ip_dest_ip                   (ip_dest_ip),
        .m_ip_payload_axis_tdata        (ip_payload_tdata),
        .m_ip_payload_axis_tkeep        (ip_payload_tkeep),
        .m_ip_payload_axis_tvalid       (ip_payload_tvalid),
        .m_ip_payload_axis_tready       (ip_payload_tready),
        .m_ip_payload_axis_tlast        (ip_payload_tlast),

        // TX input — tie off (RX-only path in this design)
        .s_ip_hdr_valid                 (1'b0),
        .s_ip_dscp                      (6'b0),
        .s_ip_ecn                       (2'b0),
        .s_ip_ttl                       (8'd64),
        .s_ip_protocol                  (8'h11),
        .s_ip_source_ip                 (32'h0A000001),
        .s_ip_dest_ip                   (32'hE9360C00),
        .s_ip_payload_axis_tdata        (64'b0),
        .s_ip_payload_axis_tkeep        (8'b0),
        .s_ip_payload_axis_tvalid       (1'b0),
        .s_ip_payload_axis_tlast        (1'b0),

        // TX output — unconnected (RX-only path)
        .m_eth_hdr_valid                (),
        .m_eth_dest_mac                 (),
        .m_eth_src_mac                  (),
        .m_eth_type                     (),
        .m_eth_payload_axis_tdata       (),
        .m_eth_payload_axis_tkeep       (),
        .m_eth_payload_axis_tvalid      (),
        .m_eth_payload_axis_tready      (1'b1),  // accept and discard TX output
        .m_eth_payload_axis_tlast       (),

        // ARP TX output — tie ready (discard ARP TX; not needed in sim)
        .m_arp_request_valid            (),
        .m_arp_request_ready            (1'b1),
        .m_arp_request_ip               ()
    );
```

> **Note — `ip_complete_64` port map:** The port map above is derived from the
> Forencich verilog-ethernet module conventions and must be **verified against the
> checked-out `lib/verilog-ethernet/rtl/ip_complete_64.v`** before writing RTL.
> Specific items to verify:
>
> 1. **TX input tie-offs:** `ip_complete_64` is bidirectional (TX+RX). In the
>    LLIU receive-only path the TX input ports must be tied off. Verify the exact
>    TX sink port names and tie-off values from the module header.
> 2. **ARP ports:** `ip_complete_64` includes ARP. The ARP TX output (`m_arp_*`)
>    may need `tready = 1` to prevent deadlock if the module waits for ARP completion.
>    Alternatively, the ARP ports may be absent if the version is RX-only. Confirm.
> 3. **`tuser` width:** `s_eth_payload_axis_tuser` may be 1-bit (error flag) in
>    some Forencich versions; confirm and tie to `1'b0` (no error).
> 4. **Configuration registers vs. parameters:** `local_ip`, `local_mac`, etc. may be
>    registered inputs (driven every cycle) rather than `parameter` declarations.
>    Confirm the mechanism used in the checked-out file.

### 3e — Instantiate `udp_complete_64`

```systemverilog
    udp_complete_64 u_udp (
        .clk                            (clk_156),
        .rst                            (rst_156),

        // IP input (from ip_complete_64)
        .s_ip_hdr_valid                 (ip_hdr_valid),
        .s_ip_eth_dest_mac              (ip_eth_dest_mac),
        .s_ip_eth_src_mac               (ip_eth_src_mac),
        .s_ip_eth_type                  (ip_eth_type),
        .s_ip_dscp                      (ip_dscp),
        .s_ip_ecn                       (ip_ecn),
        .s_ip_ttl                       (ip_ttl),
        .s_ip_protocol                  (ip_protocol),
        .s_ip_source_ip                 (ip_source_ip),
        .s_ip_dest_ip                   (ip_dest_ip),
        .s_ip_payload_axis_tdata        (ip_payload_tdata),
        .s_ip_payload_axis_tkeep        (ip_payload_tkeep),
        .s_ip_payload_axis_tvalid       (ip_payload_tvalid),
        .s_ip_payload_axis_tready       (ip_payload_tready),
        .s_ip_payload_axis_tlast        (ip_payload_tlast),

        // UDP output (to moldupp64_strip via udp_payload_*)
        .m_udp_hdr_valid                (udp_hdr_valid),
        .m_udp_eth_dest_mac             (),
        .m_udp_eth_src_mac              (),
        .m_udp_eth_type                 (),
        .m_udp_ip_dscp                  (),
        .m_udp_ip_ecn                   (),
        .m_udp_ip_ttl                   (),
        .m_udp_ip_protocol              (),
        .m_udp_ip_source_ip             (),
        .m_udp_ip_dest_ip               (),
        .m_udp_source_port              (udp_hdr_src_port),
        .m_udp_dest_port                (udp_hdr_dest_port),
        .m_udp_length                   (udp_length),
        .m_udp_payload_axis_tdata       (udp_payload_tdata),
        .m_udp_payload_axis_tkeep       (udp_payload_tkeep),
        .m_udp_payload_axis_tvalid      (udp_payload_tvalid),
        .m_udp_payload_axis_tready      (udp_payload_tready),
        .m_udp_payload_axis_tlast       (udp_payload_tlast),

        // TX input — tie off (RX-only path)
        .s_udp_hdr_valid                (1'b0),
        .s_udp_ip_dscp                  (6'b0),
        .s_udp_ip_ecn                   (2'b0),
        .s_udp_ip_ttl                   (8'd64),
        .s_udp_source_port              (16'h0400),
        .s_udp_dest_port                (16'd26477),
        .s_udp_length                   (16'b0),
        .s_udp_payload_axis_tdata       (64'b0),
        .s_udp_payload_axis_tkeep       (8'b0),
        .s_udp_payload_axis_tvalid      (1'b0),
        .s_udp_payload_axis_tlast       (1'b0),

        // TX output — discard
        .m_ip_hdr_valid                 (),
        .m_ip_payload_axis_tdata        (),
        .m_ip_payload_axis_tkeep        (),
        .m_ip_payload_axis_tvalid       (),
        .m_ip_payload_axis_tready       (1'b1),
        .m_ip_payload_axis_tlast        ()
    );
```

> **Note — `udp_complete_64` port map:** Same verification requirement as for
> `ip_complete_64`. Specific items to confirm:
>
> 1. **Header sideband between IP and UDP output:** Whether `m_udp_dest_port` and
>    `m_udp_source_port` use the exact names above or a different port naming scheme
>    in the checked-out version.
> 2. **Port filtering:** Whether `udp_complete_64` has a built-in destination port
>    filter register input (like `dest_port_filter` or similar) or whether it passes
>    all UDP traffic and the port filter is applied elsewhere. If a filter input exists,
>    tie it to `16'd26477` (MAS §6.3 default UDP port). If no filter exists, add a
>    simple combinational gate after `m_udp_payload_axis_tvalid` to suppress traffic
>    to wrong ports: `udp_payload_tvalid = m_udp_payload_axis_tvalid & (udp_hdr_dest_port == 16'd26477)`.
> 3. **IP header passthrough:** Some `udp_complete_64` versions forward the full IP
>    header fields through to the UDP output sideband. The unconnected output ports
>    above (`()`) assume those are not needed downstream; confirm none are required
>    by `moldupp64_strip`.

**Suppress unused sideband signals with Verilator lint-off to keep lint clean:**

```systemverilog
    /* verilator lint_off UNUSED */
    logic        _unused_udp;
    assign _unused_udp = udp_hdr_valid ^ udp_hdr_src_port[0] ^ udp_hdr_dest_port[0] ^ udp_length[0];
    /* verilator lint_on UNUSED */
```

**Lint check after Step 3:**
```sh
verilator --lint-only -Wall -sv --top-module kc705_top \
    -DKINTEX7_SIM_GTX_BYPASS \
    rtl/lliu_pkg.sv \
    rtl/bfloat16_mul.sv rtl/fp32_acc.sv rtl/dot_product_engine.sv \
    rtl/itch_parser.sv rtl/itch_field_extract.sv \
    rtl/feature_extractor.sv rtl/weight_mem.sv \
    rtl/axi4_lite_slave.sv rtl/output_buffer.sv \
    rtl/moldupp64_strip.sv rtl/symbol_filter.sv rtl/eth_axis_rx_wrap.sv \
    rtl/kc705_top.sv \
    lib/verilog-ethernet/rtl/eth_axis_rx.v \
    lib/verilog-ethernet/rtl/ip_complete_64.v \
    lib/verilog-ethernet/rtl/udp_complete_64.v \
    <...ip_complete_64 and udp_complete_64 dependency files from MAS §6.1...>
```

All new `UNUSED`/`UNDRIVEN` warnings from unused TX output ports must be suppressed
with `/* verilator lint_off UNUSED */` guards around the tie-off sections.

---

## Step 4 — Replace async FIFO bypass with real `axis_async_fifo` instantiation

**File:** `rtl/kc705_top.sv`

### 4a — Remove the bypass wire-through

Inside the `ifdef KINTEX7_SIM_GTX_BYPASS` block, delete the five assign statements
that previously bypassed the FIFO:

```systemverilog
    // DELETE all five of these:
    // assign itch_300_tdata  = itch_net_tdata;
    // assign itch_300_tkeep  = itch_net_tkeep;
    // assign itch_300_tvalid = itch_net_tvalid;
    // assign itch_300_tlast  = itch_net_tlast;
    // assign itch_net_tready = itch_300_tready;
```

Also remove the `fifo_rd_tvalid` direct assignment (it will be replaced in Step 5):

```systemverilog
    // DELETE:
    // assign fifo_rd_tvalid = itch_300_tvalid;
```

### 4b — Update `fifo_almost_full` assignment

The `fifo_almost_full` signal is now driven from the real FIFO's `s_status_almost_full`
output. Remove the `ifdef` block that tied it to `1'b0` and replace it with a forward
declaration pointing to the FIFO output wire (see instantiation in 4c):

```systemverilog
    // Remove:
    // `ifdef KINTEX7_SIM_GTX_BYPASS
    //     assign fifo_almost_full = 1'b0;
    // `else
    //     // Hardware: driven from axis_async_fifo.s_almost_full (clk_156 domain).
    // `endif

    // Replace with (single-domain, no ifdef needed once FIFO is always instantiated
    // in sim — but keep the else-branch for hardware path):
    logic fifo_s_almost_full;
    assign fifo_almost_full = fifo_s_almost_full;
```

### 4c — Instantiate `axis_async_fifo`

```systemverilog
`ifdef KINTEX7_SIM_GTX_BYPASS
    axis_async_fifo #(
        .DEPTH           (128),
        .DATA_WIDTH      (64),
        .KEEP_ENABLE     (1),
        .KEEP_WIDTH      (8),
        .LAST_ENABLE     (1),
        .ID_ENABLE       (0),
        .DEST_ENABLE     (0),
        .USER_ENABLE     (0),
        .PIPELINE_OUTPUT (1),
        .FRAME_FIFO      (0)
    ) u_async_fifo (
        // Write side — clk_156 domain (ITCH stream from moldupp64_strip)
        .s_clk                  (clk_156),
        .s_rst                  (rst_156),
        .s_axis_tdata           (itch_net_tdata),
        .s_axis_tkeep           (itch_net_tkeep),
        .s_axis_tvalid          (itch_net_tvalid),
        .s_axis_tready          (itch_net_tready),
        .s_axis_tlast           (itch_net_tlast),
        .s_status_overflow      (),
        .s_status_bad_frame     (),
        .s_status_good_frame    (),
        .s_status_almost_full   (fifo_s_almost_full),  // → eth_axis_rx_wrap drop
        .s_status_full          (),

        // Read side — clk_300 domain (itch_parser input)
        .m_clk                  (clk_300),
        .m_rst                  (rst_300),
        .m_axis_tdata           (itch_300_tdata),
        .m_axis_tkeep           (itch_300_tkeep),
        .m_axis_tvalid          (itch_300_tvalid),
        .m_axis_tready          (itch_300_tready),
        .m_axis_tlast           (itch_300_tlast),
        .m_status_overflow      (),
        .m_status_bad_frame     (),
        .m_status_good_frame    ()
    );
`else
    // Hardware path: axis_async_fifo also instantiated here (identical parameters).
    // Not compiled by Verilator without KINTEX7_SIM_GTX_BYPASS.
`endif
```

> **Note — `axis_async_fifo` port map:** Verify the following items against the
> checked-out `lib/verilog-ethernet/rtl/axis_async_fifo.v` before writing RTL:
>
> 1. **Depth parameter name:** The Forencich module may use `ADDR_WIDTH` (where
>    depth = 2^ADDR_WIDTH) rather than a direct `DEPTH` parameter. For depth 128,
>    use `ADDR_WIDTH = 7`. Confirm the correct parameter name.
> 2. **`KEEP_ENABLE` vs `KEEP_WIDTH`:** Some versions use `KEEP_ENABLE = 1` to
>    activate the tkeep port; others derive it from `KEEP_WIDTH > 0`. Confirm.
> 3. **Almost-full port name:** The port may be `s_status_almost_full` or
>    `s_almost_full` or `s_full` with a separate almost-full offset parameter.
>    Confirm exact port name and set the threshold offset accordingly.
> 4. **Status port existence:** `m_status_overflow`, `s_status_good_frame`, etc.
>    may not exist in all versions. If a status port is absent in the checked-out
>    module, remove it from the instantiation rather than leaving it unconnected.
> 5. **`USER` / `ID` / `DEST` ports:** These may be absent when the corresponding
>    `*_ENABLE` parameters are 0. If so, remove them from the port map entirely.

**Suppress any remaining Verilator `UNUSED` warnings** from tkeep on the read side
(the `itch_300_tkeep` signal is already suppressed by the existing lint-off block —
verify it is still present and covers the new `itch_300_tkeep` wire).

**Lint check after Step 4:**
```sh
verilator --lint-only -Wall -sv --top-module kc705_top \
    -DKINTEX7_SIM_GTX_BYPASS \
    rtl/lliu_pkg.sv \
    rtl/bfloat16_mul.sv rtl/fp32_acc.sv rtl/dot_product_engine.sv \
    rtl/itch_parser.sv rtl/itch_field_extract.sv \
    rtl/feature_extractor.sv rtl/weight_mem.sv \
    rtl/axi4_lite_slave.sv rtl/output_buffer.sv \
    rtl/moldupp64_strip.sv rtl/symbol_filter.sv rtl/eth_axis_rx_wrap.sv \
    rtl/kc705_top.sv \
    lib/verilog-ethernet/rtl/eth_axis_rx.v \
    lib/verilog-ethernet/rtl/ip_complete_64.v \
    lib/verilog-ethernet/rtl/udp_complete_64.v \
    lib/verilog-ethernet/rtl/axis_async_fifo.v \
    <...all dependency files from MAS §6.1...>
```

---

## Step 5 — Drive `fifo_rd_tvalid` from real FIFO read-side output

**File:** `rtl/kc705_top.sv`

The `fifo_rd_tvalid` top-level output must be driven from the actual FIFO read-side
`m_axis_tvalid` (which is now `itch_300_tvalid`, sourced from the FIFO output).

Inside the `ifdef KINTEX7_SIM_GTX_BYPASS` port body in `kc705_top.sv`, replace the
old direct assignment with a connection to the FIFO output wire:

```systemverilog
    // Drive fifo_rd_tvalid from real axis_async_fifo read-side output.
    // itch_300_tvalid is now driven by u_async_fifo.m_axis_tvalid.
    assign fifo_rd_tvalid = itch_300_tvalid;
```

This assignment looks identical to the old bypass line, but the **source** is now
different: `itch_300_tvalid` is now driven by the FIFO `m_axis_tvalid` output
(Step 4c) instead of a direct combinational assign from `itch_net_tvalid`.

The existing `_unused_tkeep_300` Verilator suppress block must remain:

```systemverilog
    /* verilator lint_off UNUSED */
    logic _unused_tkeep_300;
    assign _unused_tkeep_300 = &itch_300_tkeep;
    /* verilator lint_on UNUSED */
```

---

## Step 6 — Full lint pass (acceptance criterion)

Run the complete lint suite across all modified and newly-involved files.
**Zero warnings is the acceptance criterion** before handoff to `cocotb_engineer`
and `uvm_engineer` for testbench updates.

### 6a — Updated `eth_axis_rx_wrap` lint

```sh
verilator --lint-only -Wall -sv --top-module eth_axis_rx_wrap \
    rtl/lliu_pkg.sv rtl/eth_axis_rx_wrap.sv \
    lib/verilog-ethernet/rtl/eth_axis_rx.v
```

### 6b — Full `kc705_top` lint with all Forencich sources

```sh
verilator --lint-only -Wall -sv --top-module kc705_top \
    -DKINTEX7_SIM_GTX_BYPASS \
    rtl/lliu_pkg.sv \
    rtl/bfloat16_mul.sv rtl/fp32_acc.sv rtl/dot_product_engine.sv \
    rtl/itch_parser.sv rtl/itch_field_extract.sv \
    rtl/feature_extractor.sv rtl/weight_mem.sv \
    rtl/axi4_lite_slave.sv rtl/output_buffer.sv \
    rtl/moldupp64_strip.sv rtl/symbol_filter.sv rtl/eth_axis_rx_wrap.sv \
    rtl/kc705_top.sv \
    lib/verilog-ethernet/rtl/eth_axis_rx.v \
    lib/verilog-ethernet/rtl/ip_complete_64.v \
    lib/verilog-ethernet/rtl/udp_complete_64.v \
    lib/verilog-ethernet/rtl/axis_async_fifo.v \
    <...all Forencich dependency files from MAS §6.1 — ip, arp, udp sub-modules...>
```

### 6c — Confirm unchanged module lints still pass

Verify that the individual module lints that were passing before are still clean:

```sh
for f in bfloat16_mul fp32_acc dot_product_engine \
          moldupp64_strip symbol_filter; do
    verilator --lint-only -Wall -sv --top-module $f \
        rtl/lliu_pkg.sv rtl/$f.sv
done
```

### 6d — `kc705_top.sv` lint WITHOUT `KINTEX7_SIM_GTX_BYPASS` (synthesis path check)

The synthesis path uses stubs/tie-offs in the `else` branches. Lint this path with
`+incdir` pointing to the Forencich RTL (Forencich modules are still referenced):

```sh
verilator --lint-only -Wall -sv --top-module kc705_top \
    rtl/lliu_pkg.sv \
    rtl/bfloat16_mul.sv rtl/fp32_acc.sv rtl/dot_product_engine.sv \
    rtl/itch_parser.sv rtl/itch_field_extract.sv \
    rtl/feature_extractor.sv rtl/weight_mem.sv \
    rtl/axi4_lite_slave.sv rtl/output_buffer.sv \
    rtl/moldupp64_strip.sv rtl/symbol_filter.sv rtl/eth_axis_rx_wrap.sv \
    rtl/kc705_top.sv
```

> The synthesis path `else` branches contain `assign ... = '0` / `1'b0` tie-offs that
> were already present and passing before this work. This lint run confirms the rename
> from `KINTEX7_SIM_MAC_BYPASS` → `KINTEX7_SIM_GTX_BYPASS` did not break the synthesis
> path's tie-off stubs. Expected: zero warnings.

---

## Completion Checklist

| Step | File | Change | Lint status |
|------|------|--------|-------------|
| 1 | `rtl/kc705_top.sv` | All `KINTEX7_SIM_MAC_BYPASS` → `KINTEX7_SIM_GTX_BYPASS` | ⬜ |
| 2a | `rtl/eth_axis_rx_wrap.sv` | Add `eth_hdr_valid`, `eth_dest_mac`, `eth_src_mac`, `eth_type` output ports | ⬜ |
| 2b | `rtl/eth_axis_rx_wrap.sv` | Wire header outputs from internal `eth_axis_rx` output ports | ⬜ |
| 2c | `rtl/eth_axis_rx_wrap.sv` | Gate `eth_hdr_valid` with `~drop_current` | ⬜ |
| 3b | `rtl/kc705_top.sv` | `eth_axis_rx_wrap` instantiation: add four header output connections | ⬜ |
| 3c | `rtl/kc705_top.sv` | Remove old bypass assigns for `udp_payload_*` | ⬜ |
| 3d | `rtl/kc705_top.sv` | Instantiate `ip_complete_64` with verified port map | ⬜ |
| 3e | `rtl/kc705_top.sv` | Instantiate `udp_complete_64` with verified port map | ⬜ |
| 4a | `rtl/kc705_top.sv` | Remove FIFO bypass assigns for `itch_300_*` and `itch_net_tready` | ⬜ |
| 4b | `rtl/kc705_top.sv` | Update `fifo_almost_full` to wire from FIFO `s_status_almost_full` | ⬜ |
| 4c | `rtl/kc705_top.sv` | Instantiate `axis_async_fifo` (write: `clk_156`; read: `clk_300`) | ⬜ |
| 5  | `rtl/kc705_top.sv` | `fifo_rd_tvalid` wired to `itch_300_tvalid` (now from FIFO output) | ⬜ |
| 6a | `eth_axis_rx_wrap` | Standalone lint: zero warnings | ⬜ |
| 6b | `kc705_top` | Full lint with Forencich sources: zero warnings | ⬜ |
| 6c | All other modules | Individual lints unchanged: zero warnings | ⬜ |
| 6d | `kc705_top` | Synthesis-path lint (no define): zero warnings | ⬜ |

> When all rows are checked, hand off to `cocotb_engineer` and `uvm_engineer` to
> update `test_kc705_e2e.py`, `test_kc705_latency.py`, `lliu_kc705_test.sv`, and
> `lliu_kc705_perf_test.sv` per MAS §6.5 (full Ethernet frame encapsulation required).
> All Makefiles and CI that previously passed `+define+KINTEX7_SIM_MAC_BYPASS` must be
> updated to `+define+KINTEX7_SIM_GTX_BYPASS`.
