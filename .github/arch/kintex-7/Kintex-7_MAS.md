# Kintex-7 XC7K160T — Micro-Architectural Specification

**Project:** `low_latency_inference_unit` (LLIU)  
**Target:** Xilinx Kintex-7 (`xc7k160tffg676-2`, Vivado ML Standard free tier)  
**Clock domain:** 156.25 MHz (transceiver reference) + 300 MHz target / 250 MHz fallback (application)  
**Network library:** [verilog-ethernet](https://github.com/alexforencich/verilog-ethernet) (Forencich)  
**Protocol:** NASDAQ ITCH 5.0 over UDP/IP multicast (10GbE)

> **Device change — April 2026:** Original target was the KC705 board (`xc7k325tffg900-2`).  The XC7K325T requires Vivado Enterprise (no free tier) or nextpnr-xilinx P&R — but the XC7K325T fabric was never reverse-engineered by Project X-Ray and cannot be targeted by nextpnr-xilinx.  Switched to **`xc7k160tffg676-2`** (Vivado ML Standard free tier, AMD UG973).  GTX transceivers present; design fits with headroom (101,440 LUTs, 600 DSP48E1, 162 RAMB36E1).  The RTL top module retains the `kc705_top` name.

---

## 1. System Block Diagram

```
  SFP+ Cage (KC705 J3)
        │  10GbE optical
        ▼
  ┌─────────────────────────────────────────────────────────────┐
  │  GTX Transceiver (156.25 MHz reference, XCLK from KC705)   │
  └───────────────────────┬─────────────────────────────────────┘
                          │ XGMII / serial SERDES
  ┌───────────────────────▼─────────────────────────────────────┐
  │  eth_mac_phy_10g      (MAC + PHY wrapper — Forencich)       │
  │   ├── eth_phy_10g     64b/66b encode/decode, block sync     │
  │   └── eth_mac_10g     preamble, CRC32 generation/check      │
  └───────────────────────┬─────────────────────────────────────┘
                          │ AXI4-Stream (64-bit, 156.25 MHz)
  ┌───────────────────────▼─────────────────────────────────────┐
  │  eth_axis_rx          raw Ethernet frame → payload stream   │
  └───────────────────────┬─────────────────────────────────────┘
                          │ AXI4-Stream (Ethernet payload)
  ┌───────────────────────▼─────────────────────────────────────┐
  │  ip_complete_64       IPv4 parse, checksum verify, filter   │
  └───────────────────────┬─────────────────────────────────────┘
                          │ AXI4-Stream (IP payload)
  ┌───────────────────────▼─────────────────────────────────────┐
  │  udp_complete_64      UDP port filter → raw data payload    │
  └───────────────────────┬─────────────────────────────────────┘
                          │ AXI4-Stream (UDP payload, 156.25 MHz)
  ┌───────────────────────▼─────────────────────────────────────┐
  │  moldupp64_strip      strip 20-byte header, gap detect      │
  │                       drop duplicate/bad seq numbers        │
  └───────────────────────┬─────────────────────────────────────┘
                          │ AXI4-Stream (clean ITCH only, 156.25 MHz)
  ┌───────────────────────▼─────────────────────────────────────┐
  │  axis_async_fifo      156.25 MHz → 300/250 MHz clock crossing │
  └───────────────────────┬─────────────────────────────────────┘
                          │ AXI4-Stream (64-bit, 300/250 MHz)
  ┌───────────────────────▼─────────────────────────────────────┐
  │  itch_parser / itch_field_extract   (LLIU hot path)         │
  │  feature_extractor                                          │
  │  dot_product_engine (bfloat16_mul, fp32_acc)                │
  │  weight_mem · axi4_lite_slave · output_buffer               │
  └─────────────────────────────────────────────────────────────┘
                          │ AXI4-Lite (result readout)
                     Host CPU / PCIe
```

---

## 2. Block Descriptions

### 2.1 Physical & Link Layer — Forencich Modules

These blocks interface directly with KC705 hardware and run in the **156.25 MHz** GTX clock domain.

#### `eth_phy_10g`

| Property | Detail |
|----------|--------|
| Function | 64b/66b encode/decode, block synchronisation, scrambling |
| Primitives | Connects to Kintex-7 GTX Transceiver via `XGMII` |
| Clock | 156.25 MHz (recovered from GTX) |
| Key signals | `xgmii_txd[63:0]`, `xgmii_txc[7:0]`, `xgmii_rxd[63:0]`, `xgmii_rxc[7:0]` |

The PHY is the first block after the GTX. It presents a clean XGMII bus to the MAC.

#### `eth_mac_10g`

| Property | Detail |
|----------|--------|
| Function | Ethernet framing, preamble insertion/stripping, CRC32 (FCS) generation and verification |
| Interface | XGMII inward, AXI4-Stream outward |
| Clock | 156.25 MHz |
| Error output | `rx_error_bad_fcs` — assert signals up the stack on CRC failure |

Frames with bad FCS are dropped here; they never enter the network stack.

#### `eth_mac_phy_10g` _(top-level instantiation point)_

Forencich wrapper that combines `eth_phy_10g` and `eth_mac_10g` into a single module. **This is the module you instantiate in the KC705 top-level.** It exposes:

- GTX serial pins (`sfp_tx_p/n`, `sfp_rx_p/n`)
- AXI4-Stream TX/RX ports at 156.25 MHz

---

### 2.2 Network Stack — Protocol Parsing

These blocks strip Ethernet, IP, and UDP headers, leaving only the raw application payload. All run at **156.25 MHz** in this implementation.

#### `eth_axis_rx`

Strips the Ethernet header (destination MAC, source MAC, EtherType) and outputs the payload as an AXI4-Stream. Passes IP packets upstream; silently drops non-IPv4 frames (ARP, etc. can be looped to `eth_axis_tx` if needed).

**Drop-on-Full policy:** `eth_axis_rx` must be configured with a **drop-on-full** behaviour tied to the `axis_async_fifo` almost-full signal. When the FIFO asserts `almost_full`, `eth_axis_rx` is instructed to abort the current frame and discard the rest of it at the wire rather than asserting backpressure toward the MAC.

Why this matters:
- The Forencich `eth_mac_10g` has no internal receive buffer. If it cannot push data downstream, it stalls the XGMII RX path and **corrupts subsequent frame alignment** at the 10GbE line rate.
- In HFT, a cleanly dropped packet is recoverable (NASDAQ will retransmit via SoupBinTCP gap-fill, and the sequence number discontinuity is detectable). A MAC stall that introduces jitter into the next packet is not recoverable without re-synchronisation.
- Asserting `tready = 0` toward a Forencich block that has already accepted a frame mid-stream is undefined behaviour and can deadlock the pipeline.

**Implementation:** Connect the `axis_async_fifo` `almost_full` output to a `drop_frame` flag in `eth_axis_rx`. When `drop_frame` is asserted at frame start (`tvalid && !tlast`, first beat), the module discards all beats of that frame and increments a `dropped_frames[31:0]` counter register. The counter is exposed via AXI4-Lite for host monitoring.

#### `ip_complete_64`

| Property | Detail |
|----------|--------|
| Function | IPv4 header parse, checksum verification, multicast group filtering |
| Configuration | Destination IP register for multicast group (NASDAQ feed address) |
| Drop conditions | Bad IP checksum, non-UDP protocol, TTL = 0 |
| Output | AXI4-Stream of IP payload (UDP datagram) |

Configure the multicast destination address in `local_ip` / `multicast_ip` ports to accept only the NASDAQ feed's multicast group.

#### `udp_complete_64`

| Property | Detail |
|----------|--------|
| Function | UDP header parse, destination port filtering |
| Configuration | `udp_dest_port` register — NASDAQ ITCH uses dedicated ports per multicast group |
| Output | AXI4-Stream of UDP payload (MoldUDP64 + ITCH messages) |

After this block the stream is a raw MoldUDP64 session stream. The MoldUDP64 header is stripped and sequence numbers are validated in the **156.25 MHz domain** (`moldupp64_strip`) before any data enters the async FIFO — see section 2.3.

---

### 2.3 Clock-Domain Crossing & Buffering

#### `sync_reset`

```
156.25 MHz domain ──[ sync_reset ]──► 156.25 MHz synchronised reset
300 MHz domain    ──[ sync_reset ]──► 300 MHz synchronised reset
```

On the KC705, the global `CPU_RESET` button is asynchronous. Each clock domain requires its own synchronised reset. **Failure to synchronise resets to the GTX clock is a common source of metastability on Kintex-7.**

Two independent `sync_reset` instances are required:
1. One in the 156.25 MHz network path.
2. One in the 300 MHz application path.

#### `moldupp64_strip` _(runs at 156.25 MHz — before the FIFO)_

| Field | Offset | Width |
|-------|--------|-------|
| Session | 0 | 10 bytes |
| Sequence Number | 10 | 8 bytes |
| Message Count | 18 | 2 bytes |
| **ITCH payload starts** | **20** | — |

This lightweight state machine runs in the **156.25 MHz network domain**, immediately after `udp_complete_64` and **before** the async FIFO. Placing it here provides two concrete benefits:

1. **Early drop**: Duplicate sequence numbers and malformed datagrams are discarded before any data enters the FIFO. Only clean, in-order ITCH payloads cross the clock boundary.
2. **FIFO resource savings**: The 20-byte MoldUDP64 header is never written into the FIFO, reducing the required depth for a given burst tolerance.

Outputs `seq_num[63:0]` and `msg_count[15:0]` on a separate slow-path bus that is clock-domain-crossed independently (small CDC registers, not a stream FIFO) into the 300 MHz domain so the host can poll for gaps via AXI4-Lite.

Full gap recovery (retransmit request via NASDAQ SoupBinTCP) is out of scope for v2 but the register interface must be wired.

#### `axis_async_fifo` _(clock crossing FIFO)_

| Property | Detail |
|----------|--------|
| Function | Safe AXI-Stream handoff from 156.25 MHz (network) → 300/250 MHz (application) |
| Input stream | Clean ITCH data only (MoldUDP64 header already stripped) |
| Depth | ≥ 128 entries of 64-bit data + 8-bit keep + 1-bit last |
| Implementation | Distributed RAM preferred (low latency); Block RAM acceptable for deeper FIFOs |
| Almost-full threshold | Assert when headroom < one max-size ITCH message burst (~64 beats) |
| **Overflow policy** | **Assert `almost_full` → `eth_axis_rx` drops current frame at wire; FIFO never stalls** |

Because MoldUDP64 headers are stripped upstream, each FIFO entry carries only ITCH payload bytes. The required depth is smaller than it would be if raw UDP datagrams were queued — 128 entries is sufficient for worst-case burst absorption at market open.

The `almost_full` signal must be routed back to `eth_axis_rx` in the 156.25 MHz domain with **no additional synchronisation latency** (both signals are already in 156.25 MHz). Asserting it one full maximum-frame-length ahead of true full (i.e., ~18 beats of headroom at 1,518-byte Ethernet max) ensures the drop decision is made before any new frame can begin writing.

Place this FIFO **between `moldupp64_strip` and `itch_parser`**.

---

### 2.4 Application Logic — Hot Path

The hot path targets **300 MHz** and maps directly to the LLIU RTL defined in [RTL_ARCH.md](../RTL_ARCH.md). The stream entering this domain is already clean ITCH data — the MoldUDP64 header has been stripped and sequence numbers validated in the 156.25 MHz domain (see section 2.3).

> **Timing note — 300 MHz on Kintex-7 -2:** 300 MHz is aggressive for dense logic near DSP columns (the `dot_product_engine` uses DSP48E1 slices for `bfloat16_mul` and `fp32_acc`). Routing congestion around DSP columns is the most likely failure mode. If P&R cannot meet 300 MHz after applying the DSP floorplan constraints below, **drop to 250 MHz**. A stable 250 MHz clock with zero timing violations is preferable to a 300 MHz clock with intermittent hold/setup violations. The latency contract adjusts proportionally (see table below).

#### `itch_parser` / `itch_field_extract`

Receives the ITCH byte stream starting at message type byte. Handles alignment across 64-bit beats. Extracts Add Order (`'A'`) fields and asserts `parser_fields_valid`. Full description in [RTL_ARCH.md](../RTL_ARCH.md).

#### Symbol Filter _(new module, `symbol_filter`)_

| Property | Detail |
|----------|--------|
| Function | Compares the 8-character Stock field against a configurable watchlist |
| Watchlist storage | **LUT-CAM** — 64 entries × 64-bit key, match in a **single 300/250 MHz cycle** |
| Interface | Takes `stock[63:0]` from `itch_field_extract`, outputs `watchlist_hit` |
| Configuration | Watchlist loaded via `axi4_lite_slave` register bank |

This module gates the inference engine: only messages for watched symbols propagate to `feature_extractor`. All others are silently discarded. This is critical for throughput — the full ITCH feed covers thousands of symbols.

##### CAM Implementation

For a 64-entry × 64-bit watchlist, a register-based CAM implemented directly in Kintex-7 LUTs is both faster and more resource-efficient than a LUTRAM lookup:

- **Structure:** 64 registers, each holding one 8-character Stock key (`reg [63:0] cam_entry [0:63]`). Each entry has a valid bit.
- **Match logic:** A 64-wide bitwise-equality reduction: `assign watchlist_hit = |(valid & match_vec)` where `match_vec[i] = (stock == cam_entry[i])`.
- **Latency:** The entire comparison tree fits within a single LUT level after synthesis — **1 cycle** at 300 MHz with no carry chain dependency.
- **Resource cost:** 64 × 64 = 4,096 flip-flops (≈ 4,096 / 8 = ~512 LUTs for comparison logic on Kintex-7 6-input LUTs). Well within the 101,440 LUT budget of the `xc7k160t`.
- **Write port:** Single-cycle register write from `axi4_lite_slave` (address-indexed, no multi-port contention).

> A LUTRAM implementation would require a sequential address lookup (read-then-compare) and cannot guarantee single-cycle match across all 64 entries simultaneously. The CAM approach is strictly better here because the key width (64 bits) is fixed and the entry count is small enough that the comparison logic is not the bottleneck.

#### `feature_extractor` → `dot_product_engine` → `output_buffer`

Unchanged from the LLIU v1 design. See [RTL_ARCH.md](../RTL_ARCH.md) for full pipeline description.

##### `dot_product_engine` — Pipeline Depth Requirement

The `dot_product_engine` **must be pipelined to at least 3–4 stages** to meet timing at 300 MHz on the Kintex-7 -2 speed grade. DSP48E1 slices have internal pipeline registers (P-register, M-register) that must be fully utilised. The RTL engineer must ensure:

1. The `bfloat16_mul` output is registered before entering `fp32_acc`.
2. The `fp32_acc` accumulation path is broken into at least two registered stages.
3. No combinatorial paths span more than one DSP48E1 column in the placement.

If the v1 `dot_product_engine` RTL does not meet these requirements, the `rtl_engineer` agent must add pipeline registers before P&R is attempted. Escalate via the `rtl_engineer` agent before attempting synthesis.

##### Floorplan Constraint (XDC)

Add a Pblock in `syn/constraints.xdc` to keep the `dot_product_engine` hierarchy co-located near a DSP column and away from the SFP transceiver region:

```tcl
create_pblock pblock_dpe
add_cells_to_pblock [get_pblocks pblock_dpe] \
    [get_cells -hierarchical -filter {NAME =~ *dot_product_engine*}]
resize_pblock [get_pblocks pblock_dpe] -add {SLICE_X60Y0:SLICE_X79Y49 DSP48_X3Y0:DSP48_X3Y19}
```

Adjust the exact site range after inspecting the routed design in Vivado's device view.

**Pre-FIFO latency (156.25 MHz domain):**

| Stage | Cycles (156.25 MHz) |
|-------|---------------------|
| `udp_complete_64` header strip | ~6 |
| `moldupp64_strip` (20-byte header + seq check) | 3–4 |
| CDC FIFO write → read (async handoff) | ~5 (read-side) |
| **Sub-total to FIFO output** | **~15 cycles (~96 ns)** |

**Hot-path latency (post-FIFO, 300/250 MHz domain):**

| Stage | Cycles (300 MHz) | Cycles (250 MHz fallback) |
|-------|-----------------|---------------------------|
| `itch_parser` / `itch_field_extract` | ≤ 4 | ≤ 4 |
| `symbol_filter` | 1 | 1 |
| `feature_extractor` | ≤ 5 | ≤ 5 |
| `dot_product_engine` (≥ 3-stage pipeline) | ≤ 6 | ≤ 6 |
| **Total (FIFO output → `dp_result_valid`)** | **< 18 cycles (~60 ns)** | **< 18 cycles (~72 ns)** |

> The `dot_product_engine` cycle count increases from ≤ 4 (v1 simulation) to ≤ 6 to account for the mandatory additional pipeline registers. The absolute wall-clock latency at 250 MHz (~72 ns hot path) remains well within HFT on-chip processing budgets.

**Total estimated on-chip wire-to-result:**
- **300 MHz path:** ~96 ns (pre-FIFO) + ~60 ns (hot path) ≈ **~156 ns**
- **250 MHz fallback:** ~96 ns (pre-FIFO) + ~72 ns (hot path) ≈ **~168 ns**

---

### 2.5 Support & Clocking

#### Kintex-7 Clock Resources

| Clock | Source | Frequency | Domain | Notes |
|-------|--------|-----------|--------|-------|
| `clk_156` | GTX recovered / MGTREFCLK0 (SFP cage) | 156.25 MHz | Network (PHY, MAC, stack) | Fixed by 10GbE spec |
| `clk_300` | MMCM on-board oscillator (200 MHz typical) | 300 MHz | Application (hot path, LLIU core) | **Primary target — aggressive on -2** |
| `clk_250` | Same MMCM, alternate config | 250 MHz | Application fallback | Use if 300 MHz P&R fails |
| `clk_125` | Optional, from MMCM | 125 MHz | PCIe / AXI4-Lite host interface | Optional |

Use a single `MMCM_ADV` primitive to generate `clk_300` (and optionally `clk_125`) from the 200 MHz system oscillator (`SYSCLK`). The MMCM can be reconfigured at runtime (DRP port) to switch between 300 MHz and 250 MHz without a full bitstream reload — wire the MMCM DRP interface to an AXI4-Lite register if runtime clock switching is required.

> **300 MHz vs 250 MHz decision point:** Attempt 300 MHz first. If Vivado reports negative slack on any path through `dot_product_engine` after applying the DSP Pblock constraint, switch the MMCM output to 250 MHz and re-run P&R. Do not accept a routed design with negative slack.

#### Pin Constraints (board-specific — must be updated for target board)

> **Note:** The pin assignments below were derived from the original KC705 board (`xc7k325tffg900-2`) and are provided as a reference template only. They **will not match** a non-KC705 XC7K160T board. Obtain the target board schematic, identify the SFP+ cage GTX lane, the MGT reference clock IBUFDS_GTE2 input, the system oscillator differential input, and the reset button, then update `syn/constraints.xdc` section 4 accordingly before running Vivado P&R.

| Signal | KC705 Reference Pin | I/O Standard |
|--------|-----------|--------------|
| `sfp_tx_p` | H2 | DIFF_HSTL |
| `sfp_rx_p` | G4 | DIFF_HSTL |
| `mgt_refclk_p` (156.25 MHz) | C8 | LVDS |
| `sys_clk_p` (200 MHz) | AD12 | LVDS |
| `cpu_reset` | AB7 | LVCMOS15 |

Full pin assignments are in `syn/constraints.xdc`.

---

## 3. Inter-Module AXI4-Stream Interfaces

All AXI4-Stream buses in this design are **64-bit wide** (`tdata[63:0]`, `tkeep[7:0]`, `tlast`, `tvalid`, `tready`).

| Connection | From | To | Clock |
|------------|------|----|-------|
| Raw frames | `eth_mac_phy_10g` RX | `eth_axis_rx` | 156.25 MHz |
| Ethernet payload | `eth_axis_rx` | `ip_complete_64` | 156.25 MHz |
| IP payload | `ip_complete_64` | `udp_complete_64` | 156.25 MHz |
| UDP payload | `udp_complete_64` | `moldupp64_strip` | 156.25 MHz |
| Clean ITCH stream | `moldupp64_strip` | `axis_async_fifo` (write) | 156.25 MHz |
| Clean ITCH stream | `axis_async_fifo` (read) | `itch_parser` | 300/250 MHz |

---

## 4. New Modules Required for KC705 Integration

The following modules are **not** part of the existing LLIU v1 RTL and must be developed by the `rtl_engineer` agent as part of the KC705 bring-up effort.

| Module | File | Owner |
|--------|------|-------|
| `moldupp64_strip` | `rtl/moldupp64_strip.sv` | `rtl_engineer` |
| `symbol_filter` | `rtl/symbol_filter.sv` | `rtl_engineer` |
| `eth_axis_rx` (drop-on-full wrapper) | `rtl/eth_axis_rx_wrap.sv` | `rtl_engineer` |
| KC705 top-level | `rtl/kc705_top.sv` | `rtl_engineer` |

The Forencich `verilog-ethernet` modules are third-party IP — they are not placed under `rtl/` directly. They must be referenced as a submodule or vendored library and compiled as a separate source list in the synthesis script.

---

## 5. Open Questions / Risks

| # | Item | Risk | Mitigation |
|---|------|------|------------|
| 1 | GTX transceiver lock time at reset | Medium — may delay link-up by seconds | Implement `gt_reset_sm` state machine per Xilinx UG476 |
| 2 | Multicast IGMP join | Low for lab setup, required for production | Host sends IGMP join before traffic starts |
| 3 | MoldUDP64 gap recovery | Out of scope v1 | Sequence number register exposed via AXI4-Lite |
| 4 | 300 MHz timing closure | **High** — DSP column routing congestion is the most likely failure mode on Kintex-7 -2 for dense dot-product pipelines | (a) Ensure `dot_product_engine` is ≥ 3–4 pipeline stages (escalate to `rtl_engineer`); (b) apply DSP Pblock in XDC; (c) if negative slack remains after P&R, drop to 250 MHz fallback clock |
| 6 | FIFO overflow / MAC stall | **High** — backpressure into the Forencich MAC corrupts frame alignment at 10GbE line rate | Drop-on-Full policy: route `axis_async_fifo.almost_full` → `eth_axis_rx` drop flag; drop entire frames cleanly at wire; expose `dropped_frames` counter via AXI4-Lite |

---

## 6. Simulation Strategy & Forencich IP Integration

This section defines how the Forencich IP stack (`ip_complete_64`, `udp_complete_64`,
`axis_async_fifo`) integrates into the Verilator simulation flow, closing the coverage
gap where both cocotb and UVM testbenches previously bypassed all three simulatable
Forencich blocks.

---

### 6.1 `verilog-ethernet` Submodule

The Forencich `verilog-ethernet` library must be added as a Git submodule at
`lib/verilog-ethernet/`, pointing to the canonical upstream repository:

```sh
git submodule add https://github.com/alexforencich/verilog-ethernet lib/verilog-ethernet/
git submodule update --init
```

The submodule must be initialised before any Verilator compile that targets
`kc705_top` with `KINTEX7_SIM_GTX_BYPASS` defined (see §6.2).

#### Primary modules required for simulation

| File | Purpose |
|------|---------|
| `lib/verilog-ethernet/rtl/eth_axis_rx.v` | Ethernet frame header strip; instantiated inside `eth_axis_rx_wrap` |
| `lib/verilog-ethernet/rtl/ip_complete_64.v` | IPv4 RX: header parse, checksum verify, multicast group filter |
| `lib/verilog-ethernet/rtl/udp_complete_64.v` | UDP RX: header parse, destination port filter, payload extraction |
| `lib/verilog-ethernet/rtl/axis_async_fifo.v` | Async FIFO for 156.25 MHz → 300 MHz clock-domain crossing |

#### Dependencies (must also be compiled alongside the primary modules)

The following files are expected under `lib/verilog-ethernet/rtl/`. The exact list
must be verified against the checked-out submodule's `modules.tcl` or README filelist.

| Required by | Expected files (expected path under `lib/verilog-ethernet/rtl/`) |
|-------------|-------------------------------------------------------------------|
| `ip_complete_64.v` | `ip.v` (or parameterised `ip_64.v`), `ip_eth_rx.v`, `ip_eth_tx.v`, `arp.v`, `arp_cache.v`, `arp_eth_rx.v`, `arp_eth_tx.v`, `eth_arb_mux.v` |
| `udp_complete_64.v` | `udp.v` (or `udp_64.v`), `udp_ip_rx.v`, `udp_ip_tx.v` |
| `axis_async_fifo.v` | `axis_async_fifo_wr.v`, `axis_async_fifo_rd.v` (internal sub-modules, if the checked-out version splits them) |

> **Note:** The exact dependency filelist must be verified against the checked-out
> `lib/verilog-ethernet/` tree. Run `grep -r '^module ' lib/verilog-ethernet/rtl/` or
> inspect the Forencich README's per-module filelist. Some Forencich modules have a
> `_64` suffix (wide-bus variants) and a non-suffix generic (data-width parameterised).
> Confirm whether `ip_complete_64.v` instantiates `ip_64.v` or a generic `ip.v` in
> the checked-out version; the Verilator compile line must reference the correct set.

#### Verilator source list

Once the submodule is initialised, all Forencich dependency files must be added to the
Verilator invocation for `kc705_top`. A representative full compile line is given in
§6.5 and expanded step-by-step in `RTL_PLAN_forencich_sim.md`.

---

### 6.2 Revised Bypass Boundary — `KINTEX7_SIM_GTX_BYPASS`

The simulation conditional compile macro is **renamed** from `KINTEX7_SIM_MAC_BYPASS`
to **`KINTEX7_SIM_GTX_BYPASS`**. The new name precisely identifies what is bypassed:
only the **hardware-only GTX transceiver, IBUFDS, MMCM, and SFP** primitives that
Verilator cannot simulate. The simulatable Forencich modules (`eth_axis_rx`,
`ip_complete_64`, `udp_complete_64`, `axis_async_fifo`) are now **compiled and
exercised** in simulation under this define.

All agent files, Makefiles, and lint scripts that previously passed
`+define+KINTEX7_SIM_MAC_BYPASS` must be updated to `+define+KINTEX7_SIM_GTX_BYPASS`.
See §6.5 for the updated lint command.

#### What `KINTEX7_SIM_GTX_BYPASS` still bypasses (hardware primitives only)

| Bypassed hardware | Reason |
|-------------------|--------|
| Kintex-7 GTX transceiver (XGMII/SERDES) | Xilinx primitive; not Verilator-simulatable |
| `IBUFDS` / `IBUFDS_GTE2` differential input buffers | Xilinx primitive |
| `MMCM_ADV` clock multiplier/divider | Xilinx primitive |
| `eth_mac_phy_10g` (PHY + MAC combined wrapper) | Depends on GTX transceiver internally |
| SFP+ serial pads (`sfp_rx_p/n`, `sfp_tx_p/n`) | Physical-layer pins; no simulation model |

Under `KINTEX7_SIM_GTX_BYPASS`, the two simulation-only top-level ports substitute
for GTX/MMCM output clocks:

- `clk_156_in` — drives `clk_156` (replaces GTX recovered clock)
- `clk_300_in` — drives `clk_300` (replaces MMCM output)

Both testbench clock ports are exposed as top-level I/O; the testbench may supply
independent clock sources for a two-clock scenario or tie both to the same signal
for a single-clock regression that simplifies handshaking analysis.

#### What `KINTEX7_SIM_GTX_BYPASS` no longer bypasses (new behaviour)

| Module | Previous behaviour | New behaviour |
|--------|--------------------|---------------|
| `eth_axis_rx` (inside `eth_axis_rx_wrap`) | Instantiated (already working correctly) | Instantiated; unchanged |
| `ip_complete_64` | Bypassed — `eth_wrap_*` wired directly to `udp_payload_*` | **Instantiated** between `eth_axis_rx_wrap` output and `moldupp64_strip` input |
| `udp_complete_64` | Bypassed — same wire-through | **Instantiated** between `ip_complete_64` output and `moldupp64_strip` input |
| `axis_async_fifo` | Bypassed — ITCH stream assigned directly from `itch_net_*` to `itch_300_*` | **Instantiated** bridging `clk_156` write side to `clk_300` read side |

#### `eth_axis_rx_wrap` header field extension

`eth_axis_rx_wrap` currently exposes only the Ethernet payload stream to
`kc705_top`. To wire `ip_complete_64` correctly, `eth_axis_rx_wrap` must be
extended to also expose the Ethernet header fields that the internal `eth_axis_rx`
instance already produces:

| New output port | Width | Source |
|----------------|-------|--------|
| `eth_hdr_valid` | 1 | `eth_axis_rx.output_eth_hdr_valid` |
| `eth_dest_mac` | 48 | `eth_axis_rx.output_eth_dest_mac[47:0]` |
| `eth_src_mac` | 48 | `eth_axis_rx.output_eth_src_mac[47:0]` |
| `eth_type` | 16 | `eth_axis_rx.output_eth_type[15:0]` |

These four outputs are suppressed (tied to their `eth_axis_rx` natural values) during
drop mode so that `ip_complete_64` never sees a header for a frame whose payload has
been discarded.

> **Note:** The exact Forencich `eth_axis_rx` output port names must be verified from
> `lib/verilog-ethernet/rtl/eth_axis_rx.v`. The names above follow the Forencich
> `output_*` naming convention observed in the verilog-ethernet library but may differ
> in the specific checked-out version.

#### `axis_async_fifo` clock assignment in simulation

`axis_async_fifo` is an asynchronous dual-clock FIFO. In simulation, the write and
read clocks are wired as follows:

| FIFO port | Connected to | Rationale |
|-----------|-------------|-----------|
| `s_clk` (write side) | `clk_156_in` | ITCH stream written at 156.25 MHz |
| `s_rst` (write-side reset) | `rst_156` | Synchronised to write domain |
| `m_clk` (read side) | `clk_300_in` | `itch_parser` reads at 300 MHz |
| `m_rst` (read-side reset) | `rst_300` | Synchronised to read domain |

For single-clock regression runs where `clk_156_in` and `clk_300_in` are driven by
the same testbench clock, the FIFO operates as a synchronous FIFO — latency is
well-defined and the CDC grey-code logic is trivially exercised. Two-clock test
scenarios require independent `Clock()` coroutines (cocotb) or separate clock
generator instances (UVM `tb_top.sv`).

#### `fifo_rd_tvalid` port

The `fifo_rd_tvalid` top-level output is driven from the real `axis_async_fifo`
read-side `m_axis_tvalid` (not a direct wire-through from `itch_net_tvalid`).
This is required so that SVA latency assertions in the testbench observe the true
FIFO-read-side beat timing, including the FIFO `PIPELINE_OUTPUT` register stage.

---

### 6.3 Testbench Driver Requirements

All testbench drivers that target `kc705_top` via `mac_rx_*` must send **fully
encapsulated Ethernet frames**. The complete header stack required to pass data from
the `mac_rx_*` ports through to `moldupp64_strip` is:

```
[ Ethernet hdr ][ IPv4 hdr  ][UDP hdr ][ MoldUDP64 hdr ][ ITCH message(s) ]
[   14 bytes   ][ 20 bytes  ][ 8 bytes][   20 bytes    ][  variable       ]
```

#### Ethernet header (14 bytes)

| Field | Size | Required value |
|-------|------|----------------|
| Destination MAC | 6 B | `01:00:5e:xx:xx:xx` — standard IPv4 multicast MAC. Lower 23 bits derived from the multicast group IP per RFC 1112. For default IP `233.54.12.0` (0xE9\_360C\_00), lower 23 bits = `0x36_0C00`, giving MAC `01:00:5e:36:0c:00`. |
| Source MAC | 6 B | Testbench-defined; suggested `02:00:00:00:00:01` (locally administered) |
| EtherType | 2 B | `0x0800` (IPv4) |

#### IPv4 header (20 bytes, no options)

| Field | Required value |
|-------|----------------|
| Version / IHL | `0x45` (IPv4, 20-byte header, no options) |
| DSCP / ECN | `0x00` |
| Total Length | `20 + 8 + 20 + ITCH_payload_len` (IP header + UDP header + MoldUDP64 header + ITCH bytes) |
| Identification | Incrementing counter or `0x0000` |
| Flags / Fragment Offset | `0x4000` (Don't Fragment), offset `0` |
| TTL | `64` |
| Protocol | `0x11` (UDP) |
| Header Checksum | Computed per RFC 791 (the driver must calculate and insert the correct value) |
| Source IP | Testbench-defined; suggested `10.0.0.1` |
| Destination IP | Configurable; **default `233.54.12.0`** (NASDAQ ITCH multicast group, `0xE9360C00`) |

#### UDP header (8 bytes)

| Field | Required value |
|-------|----------------|
| Source Port | Testbench-defined; suggested `1024` |
| Destination Port | Configurable; **default `26477`** (NASDAQ ITCH multicast port) |
| Length | `8 + 20 + ITCH_payload_len` (UDP header + MoldUDP64 header + ITCH bytes) |
| Checksum | `0x0000` (checksum is optional for IPv4/UDP per RFC 768) |

#### MoldUDP64 header (20 bytes)

| Field | Byte offset | Size | Value |
|-------|-------------|------|-------|
| Session | 0 | 10 B | ASCII session ID (e.g. `b"SESSION001"`) |
| Sequence Number | 10 | 8 B | 64-bit little-endian sequence number |
| Message Count | 18 | 2 B | Count of ITCH messages in this datagram, little-endian |

#### `ip_complete_64` configuration

`ip_complete_64` must be configured with the **matching multicast destination
address** rather than a pass-all / accept-any mode. This approach is chosen because:

1. It exercises the actual IP checksum verification and address filter code paths in
   `ip_complete_64`, giving meaningful simulation coverage of those paths.
2. It mirrors production behaviour: in the field, `ip_complete_64` accepts only
   packets addressed to the NASDAQ feed multicast group.
3. Tests that intentionally send non-matching IPs (wrong multicast group, unicast,
   broadcast) can therefore verify the drop behaviour of `ip_complete_64` directly.

Required `ip_complete_64` configuration port values for the default testbench:

| Port | Default value |
|------|---------------|
| `local_ip` | `32'hE9360C00` (`233.54.12.0`) |
| `gateway_ip` | `32'h0A000001` (`10.0.0.1`) |
| `subnet_mask` | `32'hFFFFFF00` (`255.255.255.0`) |
| `local_mac` | `48'h020000000001` (must match testbench source MAC) |

`udp_complete_64` must be configured with the matching destination UDP port:

| Port | Default value |
|------|---------------|
| Destination port config input | `16'd26477` |

> **Note:** The exact configuration port names for `ip_complete_64` and
> `udp_complete_64` must be verified against the checked-out Forencich source files.
> The Forencich library uses `local_*` / `gateway_*` / `subnet_mask` conventions for
> IP-stack configuration inputs; the exact port names and whether they are
> registered inputs or `parameter` declarations must be confirmed from the actual
> module headers before writing testbench stimulus code or the `kc705_top` port map.

---

### 6.4 `axis_async_fifo` Parameters for Simulation

The `axis_async_fifo` instantiation inside `ifdef KINTEX7_SIM_GTX_BYPASS` must use
the following parameters, consistent with the MAS §2.3 depth requirement and the
64-bit pipeline bus width:

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| `DEPTH` | `128` | Per §2.3 — sufficient for burst absorption at market open; MoldUDP64 headers stripped upstream so only ITCH payload beats are stored |
| `DATA_WIDTH` | `64` | 64-bit AXI4-Stream bus throughout the KC705 pipeline |
| `KEEP_WIDTH` | `8` | `DATA_WIDTH / 8 = 8` |
| `ID_WIDTH` | `0` | TID not used in this pipeline |
| `DEST_WIDTH` | `0` | TDEST not used in this pipeline |
| `USER_WIDTH` | `0` | TUSER not used in this pipeline |
| `PIPELINE_OUTPUT` | `1` | Adds one registered output stage; reduces read-side critical-path pressure at 300 MHz |
| `FRAME_FIFO` | `0` | Frame-granular drop is handled upstream at `eth_axis_rx_wrap`; the FIFO itself stores individual beats as independent words |

The `s_status_almost_full` output (write-side, `clk_156` domain) must be wired
directly to `eth_axis_rx_wrap.fifo_almost_full` with no additional synchronisation
— both signals are in the `clk_156` domain (the write side of the FIFO is the
network domain).

> **Note:** Verify the exact parameter names against the checked-out
> `lib/verilog-ethernet/rtl/axis_async_fifo.v`. In some Forencich versions, depth
> is specified via `ADDR_WIDTH` (depth = 2^ADDR_WIDTH) rather than a direct `DEPTH`
> parameter. For `DEPTH = 128`, `ADDR_WIDTH = 7`. Also verify the almost-full
> threshold parameter name and default value (commonly `ALMOST_FULL_OFFSET`, where
> the threshold fires at `DEPTH - ALMOST_FULL_OFFSET` entries used). Set the offset
> to ≥ 18 to ensure the almost-full signal asserts with at least one full max-size
> ITCH message burst of headroom before the FIFO reaches capacity.

---

### 6.5 Impact on Existing Tests

#### Module-level tests (unaffected)

All existing cocotb and UVM tests that drive individual modules directly at their
AXI4-Stream input ports — `moldupp64_strip`, `symbol_filter`, `eth_axis_rx_wrap`,
`itch_parser`, `dot_product_engine`, etc. — are **not affected** by this change.
These tests do not instantiate `kc705_top` and do not compile the Forencich IP stack.

#### `kc705_top` system tests (driver update required)

Tests that target `kc705_top` and inject stimulus via `mac_rx_*` must now construct
and transmit fully encapsulated Ethernet frames per §6.3. The previously acceptable
pattern of injecting raw MoldUDP64 datagrams (without Ethernet/IP/UDP headers)
directly into `mac_rx_*` will now be **silently rejected** by `ip_complete_64`
(wrong EtherType / missing IP header fields) and no inference result will reach
`dp_result_valid`. This is a breaking change for those tests.

#### Updated Verilator lint command

The full `kc705_top` lint invocation replaces `-DKINTEX7_SIM_MAC_BYPASS` with
`-DKINTEX7_SIM_GTX_BYPASS` and adds all Forencich source files:

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
    <...Forencich dependency files per §6.1...>
```

> **Note:** Replace `<...Forencich dependency files per §6.1...>` with the complete
> dependency list verified from the checked-out submodule. The exact file list depends
> on the version of verilog-ethernet checked out as the submodule.

#### Summary of test file impact

| Test / Source file | Impact |
|--------------------|--------|
| `tests/test_bfloat16_mul.py` | None — targets `bfloat16_mul` directly |
| `tests/test_moldupp64_strip.py` | None — targets `moldupp64_strip` directly |
| `tests/test_symbol_filter.py` | None — targets `symbol_filter` directly |
| `tests/test_eth_axis_rx_wrap.py` | None — targets `eth_axis_rx_wrap` directly (raw Ethernet frames in, Ethernet payload out) |
| `tests/test_kc705_e2e.py` | **Update driver**: must send full Eth/IP/UDP/MoldUDP64-encapsulated frames |
| `tests/test_kc705_latency.py` | **Update driver**: same full-frame encapsulation requirement |
| `tb/uvm/tests/lliu_kc705_test.sv` | **Update sequence**: `moldupp64_seq` must prepend Eth/IP/UDP headers before injecting on `mac_rx_*` |
| `tb/uvm/tests/lliu_kc705_perf_test.sv` | **Update sequence**: same full-frame encapsulation requirement |
| All other block-level and v1 arithmetic test files | No modification required |
