# RTL Plan — Kintex-7 KC705 Integration

**Agent:** `rtl_engineer`  
**Spec:** [Kintex-7_MAS.md](../../arch/kintex-7/Kintex-7_MAS.md)  
**Writes to:** `rtl/` only  
**Lint command:** `verilator --lint-only -Wall -sv --top-module <module> rtl/lliu_pkg.sv rtl/<file>.sv`

---

## Overview

Four new RTL modules must be written and two existing v1 modules must be updated to
meet the 300 MHz pipeline-depth requirement. The implementation order follows the
datapath: upstream changes first, downstream integration last.

```
[Step 1] Audit & fix v1 pipeline depth     → rtl/bfloat16_mul.sv
                                           → rtl/fp32_acc.sv
                                           → rtl/dot_product_engine.sv

[Step 2] MoldUDP64 header stripper         → rtl/moldupp64_strip.sv   (NEW)

[Step 3] Symbol watchlist filter           → rtl/symbol_filter.sv     (NEW)

[Step 4] Drop-on-full Ethernet RX wrapper  → rtl/eth_axis_rx_wrap.sv  (NEW)

[Step 5] KC705 top-level integrator        → rtl/kc705_top.sv         (NEW)

[Step 6] Lint all modified + new files
```

---

## Step 1 — Pipeline depth audit and fix: v1 arithmetic core

**Files:** `rtl/bfloat16_mul.sv`, `rtl/fp32_acc.sv`, `rtl/dot_product_engine.sv`

**Why first:** The MAS (§2.4) mandates ≥ 3–4 pipeline stages through the dot-product
engine before synthesis is attempted. The v1 `bfloat16_mul` is fully combinational
(no registered output). A combinational multiply spanning a DSP48E1 is guaranteed to
fail timing at 300 MHz on the Kintex-7 -2 speed grade.

### 1a — `bfloat16_mul` — add output register

The current implementation has a single combinational path from `{a, b}` → `result`.
Add one registered stage on the output:

```
Before: a, b → [combinational multiply] → result
After:  a, b → [combinational multiply] → [FF clk/rst] → result_r (registered)
```

- Change port list: add `clk` and `rst` inputs.
- Add `always_ff @(posedge clk)` register for `result`.
- Latency becomes 1 cycle (was 0).
- Update all instantiations in `dot_product_engine` accordingly.

### 1b — `fp32_acc` — break accumulation into two registered stages

The accumulator path is a 32-bit floating-point add in a tight feedback loop.
Break it into two stages:

```
Stage 1: partial_sum = acc_reg + addend       (registered → partial_sum_r)
Stage 2: acc_reg     = partial_sum_r (or 0)   (registered → acc_out)
```

- Stage 1 register holds the intermediate sum from the combinational adder.
- Stage 2 register is the existing `acc_reg`; it now reads from stage 1 instead of
  directly from the adder output.
- Latency increases from 1 cycle to 2 cycles. The `acc_en` and `acc_clear` control
  signals must be pipelined by one cycle to match.

### 1c — `dot_product_engine` — re-verify end-to-end cycle budget

After changes to 1a and 1b:
- Track the `elem_cnt` → `result_valid` cycle count through the FSM.
- The total latency from `start` → `result_valid` increases by the additional pipeline
  stages (1 from mul + 1 from acc = +2 cycles vs v1).
- Confirm the total remains ≤ 6 cycles per the MAS hot-path latency table (§2.4).
- Update any `result_valid` assertion timing in the FSM to account for the new depth.

**Lint after Step 1:**
```sh
verilator --lint-only -Wall -sv --top-module bfloat16_mul \
    rtl/lliu_pkg.sv rtl/bfloat16_mul.sv

verilator --lint-only -Wall -sv --top-module fp32_acc \
    rtl/lliu_pkg.sv rtl/fp32_acc.sv

verilator --lint-only -Wall -sv --top-module dot_product_engine \
    rtl/lliu_pkg.sv rtl/bfloat16_mul.sv rtl/fp32_acc.sv \
    rtl/dot_product_engine.sv
```

---

## Step 2 — New module: `moldupp64_strip`

**File:** `rtl/moldupp64_strip.sv`  
**Domain:** 156.25 MHz (network clock, `clk_156`)  
**Spec reference:** MAS §2.3

### Purpose

Strips the 20-byte MoldUDP64 header from the UDP payload stream. Validates sequence
numbers to detect gaps and drops. Only clean, in-order ITCH messages are written to
the async FIFO. Reduces FIFO occupancy by eliminating header bytes from the stream.

### MoldUDP64 Header Layout

| Field          | Byte offset | Width  |
|----------------|-------------|--------|
| Session        | 0           | 10 B   |
| Sequence Number| 10          | 8 B    |
| Message Count  | 18          | 2 B    |
| **ITCH payload** | **20**    | —      |

Total header: **20 bytes = 2.5 × 64-bit beats** at 8 bytes/beat.

### Port List

```systemverilog
module moldupp64_strip (
    input  logic        clk,          // 156.25 MHz
    input  logic        rst,

    // Input: UDP payload stream (includes MoldUDP64 header)
    input  logic [63:0] s_tdata,
    input  logic [7:0]  s_tkeep,
    input  logic        s_tvalid,
    input  logic        s_tlast,
    output logic        s_tready,

    // Output: stripped ITCH stream only
    output logic [63:0] m_tdata,
    output logic [7:0]  m_tkeep,
    output logic        m_tvalid,
    output logic        m_tlast,
    input  logic        m_tready,

    // Sequence number output (CDC'd to 300 MHz domain separately)
    output logic [63:0] seq_num,
    output logic [15:0] msg_count,
    output logic        seq_valid,    // pulses 1 cycle when seq_num/msg_count are captured

    // Gap detection / drop counter (AXI4-Lite readable)
    output logic [31:0] dropped_datagrams,
    output logic [63:0] expected_seq_num
);
```

### State Machine

```
HEADER_B0: consume beat 0 (session bytes [7:0])
HEADER_B1: consume beat 1 (session bytes [9:8] + seq_num bytes [5:0])
HEADER_B2: consume beat 2 (seq_num bytes [7:6] + msg_count[1:0])
            → assemble seq_num[63:0] and msg_count[15:0] across beats
            → validate: if seq_num != expected_seq_num → DROP state
PAYLOAD:    pass through remaining beats to m_* with corrected tkeep/tdata
DROP:       consume and discard all remaining beats until tlast
```

At `tlast` in PAYLOAD state: if `seq_valid → expected_seq_num += msg_count`.  
At `tlast` in DROP state: increment `dropped_datagrams`, leave `expected_seq_num`
unchanged (gap detected — host readable but not resolved in v2).

### Key implementation notes

- The 20-byte header straddles beat boundaries (beats 0–2 with partial occupancy on
  beats 1 and 2). The state machine must assemble fields across multiple `tdata` beats
  using shift-registers or explicit field extraction by byte index.
- `s_tready` is always 1 in DROP state. In PAYLOAD state, `s_tready = m_tready`.
- Beat 2 carries the last 4 bytes of header + first 4 bytes of ITCH payload. The
  first ITCH output beat must be constructed from the upper 4 bytes of beat 2 combined
  with the lower 4 bytes of beat 3. Implement a 64-bit staging register to handle
  this realignment.
- `seq_num` and `msg_count` registers should be `(* keep = "true" *)` to prevent
  synthesis pruning; they are read by CDC registers.

**Lint after Step 2:**
```sh
verilator --lint-only -Wall -sv --top-module moldupp64_strip \
    rtl/lliu_pkg.sv rtl/moldupp64_strip.sv
```

---

## Step 3 — New module: `symbol_filter`

**File:** `rtl/symbol_filter.sv`  
**Domain:** 300/250 MHz (application clock, `clk_300`)  
**Spec reference:** MAS §2.4

### Purpose

Compares the 8-character Stock field extracted by `itch_field_extract` against a
64-entry configurable watchlist. Asserts `watchlist_hit` in a single cycle. Only
messages for watched symbols are forwarded to `feature_extractor`.

### Port List

```systemverilog
module symbol_filter (
    input  logic        clk,
    input  logic        rst,

    // Stock field from itch_field_extract
    input  logic [63:0] stock,           // 8-byte ASCII ticker
    input  logic        stock_valid,

    // Match output
    output logic        watchlist_hit,   // 1 cycle after stock_valid

    // AXI4-Lite configuration (write watchlist entries)
    // addr[7:2] = entry index [0..63], addr[1] = valid bit
    input  logic [7:0]  cam_wr_index,    // entry to write (0–63)
    input  logic [63:0] cam_wr_data,     // key to write
    input  logic        cam_wr_valid,    // write enable
    input  logic        cam_wr_en_bit    // 1=valid, 0=invalidate entry
);
```

### Implementation

LUT-CAM: 64 registers, each 64 bits wide + 1 valid bit.

```
always_ff @(posedge clk):
    cam_entry[cam_wr_index] <= cam_wr_data  (when cam_wr_valid)
    cam_valid[cam_wr_index] <= cam_wr_en_bit

match_vec[i] = cam_valid[i] & (stock == cam_entry[i])   [combinational, for i in 0..63]
watchlist_hit_comb = |match_vec

always_ff @(posedge clk):
    watchlist_hit <= stock_valid & watchlist_hit_comb    [registered output, 1-cycle latency]
```

Resource estimate: 64 × 64-bit registers = 4,096 FFs; comparison tree ≈ 512 LUTs.
Well within the xc7k160t budget (101,440 LUTs / 202,880 FFs).

**Lint after Step 3:**
```sh
verilator --lint-only -Wall -sv --top-module symbol_filter \
    rtl/lliu_pkg.sv rtl/symbol_filter.sv
```

---

## Step 4 — New module: `eth_axis_rx_wrap`

**File:** `rtl/eth_axis_rx_wrap.sv`  
**Domain:** 156.25 MHz  
**Spec reference:** MAS §2.2 (`eth_axis_rx` drop-on-full policy)

### Purpose

A thin wrapper around the Forencich `eth_axis_rx` module that implements the
Drop-on-Full policy. When the downstream `axis_async_fifo` asserts `almost_full`,
the wrapper gates the `tready` signal to `eth_axis_rx`'s output side and
discards the current or incoming frame before it enters the stack. Prevents
MAC stall and frame-alignment corruption at 10GbE line rate.

### Port List

```systemverilog
module eth_axis_rx_wrap (
    input  logic        clk,          // 156.25 MHz
    input  logic        rst,

    // From eth_mac_phy_10g
    input  logic [63:0] mac_rx_tdata,
    input  logic [7:0]  mac_rx_tkeep,
    input  logic        mac_rx_tvalid,
    input  logic        mac_rx_tlast,
    output logic        mac_rx_tready,

    // To ip_complete_64
    output logic [63:0] eth_payload_tdata,
    output logic [7:0]  eth_payload_tkeep,
    output logic        eth_payload_tvalid,
    output logic        eth_payload_tlast,
    input  logic        eth_payload_tready,

    // Drop-on-full control (from axis_async_fifo, 156.25 MHz)
    input  logic        fifo_almost_full,

    // Monitoring (AXI4-Lite readable)
    output logic [31:0] dropped_frames
);
```

### Drop Logic

The drop decision is frame-granular: once a frame begins (`tvalid && frame_active`),
it cannot be partially dropped. The policy triggers on the **next** frame boundary.

```
frame_active: set at first beat (tvalid & !tlast), clear at tlast

drop_next:    latch fifo_almost_full at frame boundary (tlast or idle)
              → if asserted, set drop_current for the entire next frame

drop_current: when set:
              → mac_rx_tready = 1 (consume all beats silently)
              → output tvalid = 0 (suppress downstream)
              → at tlast: increment dropped_frames, clear drop_current
```

This ensures:
- The MAC is never stalled (tready always 1 when dropping).
- Frames are dropped whole — no partial frames enter `ip_complete_64`.
- `dropped_frames[31:0]` saturates at 32'hFFFF_FFFF; never overflows.

**Lint after Step 4:**
```sh
verilator --lint-only -Wall -sv --top-module eth_axis_rx_wrap \
    rtl/lliu_pkg.sv rtl/eth_axis_rx_wrap.sv
```

> **Note:** The Forencich `eth_axis_rx` module is instantiated inside this wrapper.
> It is not under `rtl/` — it is vendor IP. The lint command above lints the wrapper
> skeleton. Full compile requires the Forencich source tree on the include path.

---

## Step 5 — New module: `kc705_top`

**File:** `rtl/kc705_top.sv`  
**Spec reference:** MAS §1, §2.5 (clocking, pin constraints)

### Purpose

Top-level integration module for the KC705 board. Instantiates all network, CDC,
and application-path modules. Drives all FPGA I/O pins. References all Forencich
third-party IP modules.

### Port List (board-level I/O only)

```systemverilog
module kc705_top (
    // 200 MHz system clock (LVDS, differential)
    input  logic        sys_clk_p,
    input  logic        sys_clk_n,

    // Active-high global reset (KC705 CPU_RESET button, LVCMOS15)
    input  logic        cpu_reset,

    // SFP+ cage (J3) — 10GbE
    input  logic        sfp_rx_p,
    input  logic        sfp_rx_n,
    output logic        sfp_tx_p,
    output logic        sfp_tx_n,

    // 156.25 MHz MGT reference clock (LVDS, from KC705 SFP cage)
    input  logic        mgt_refclk_p,
    input  logic        mgt_refclk_n,

    // AXI4-Lite host interface (from PCIe / soft CPU)
    input  logic        axil_clk,
    input  logic        axil_rst,
    input  logic [31:0] axil_awaddr,
    input  logic        axil_awvalid,
    output logic        axil_awready,
    input  logic [31:0] axil_wdata,
    input  logic [3:0]  axil_wstrb,
    input  logic        axil_wvalid,
    output logic        axil_wready,
    output logic [1:0]  axil_bresp,
    output logic        axil_bvalid,
    input  logic        axil_bready,
    input  logic [31:0] axil_araddr,
    input  logic        axil_arvalid,
    output logic        axil_arready,
    output logic [31:0] axil_rdata,
    output logic [1:0]  axil_rresp,
    output logic        axil_rvalid,
    input  logic        axil_rready,

    // Inference result output
    output logic [31:0] dp_result,
    output logic        dp_result_valid
);
```

### Internal Clock Generation

```
sys_clk_p/n (200 MHz LVDS)
    → IBUFDS → sys_clk_buf
        → MMCM_ADV:
            CLKOUT0 → clk_300 (300 MHz, application hot path)  [primary]
            CLKOUT1 → clk_125 (125 MHz, AXI4-Lite / PCIe)      [optional]
            (fallback: reconfigure MMCM to 250 MHz if timing fails)

mgt_refclk_p/n (156.25 MHz)
    → IBUFDS_GTE2 → mgtrefclk
        → used by eth_mac_phy_10g GTX

clk_156 is recovered from the GTX transceiver inside eth_mac_phy_10g.
```

### Instantiation Order (datapath top-to-bottom)

```
1. IBUFDS / IBUFDS_GTE2 — differential input buffers for sys_clk and mgt_refclk
2. MMCM_ADV             — generate clk_300 (and optionally clk_125)
3. sync_reset (x2)      — one per clock domain (clk_156, clk_300)
4. eth_mac_phy_10g      — Forencich MAC+PHY (clk_156 domain)
5. eth_axis_rx_wrap     — drop-on-full Ethernet RX (clk_156)
6. ip_complete_64       — IP header parse/filter (clk_156, Forencich)
7. udp_complete_64      — UDP header parse/filter (clk_156, Forencich)
8. moldupp64_strip      — MoldUDP64 header strip + seq validation (clk_156)
9. axis_async_fifo      — CDC FIFO: clk_156 write → clk_300 read (Forencich)
   → `s_almost_full` output is in the WRITE domain (clk_156); connect directly
     to `eth_axis_rx_wrap.fifo_almost_full` — no re-synchronisation required.
10. symbol_filter       — LUT-CAM watchlist check (clk_300)
11. itch_parser         — ITCH message alignment + type decode (clk_300)
12. itch_field_extract  — Add Order field extraction (clk_300)
13. feature_extractor   — price norm + order-flow encode (clk_300)
14. dot_product_engine  — pipelined MAC (clk_300) [bfloat16_mul, fp32_acc inside]
15. weight_mem          — on-chip weight SRAM (clk_300)
16. axi4_lite_slave     — control plane register bank (clk_300 or clk_125)
17. output_buffer       — result latch for AXI4-Lite readout (clk_300)
```

### Wire-up notes

- The `axis_async_fifo.s_almost_full` output is in the **write clock domain**
  (clk_156 — the network side is the write side). Connect it directly to
  `eth_axis_rx_wrap.fifo_almost_full` with no re-synchronisation; both signals
  are already in clk_156. (Earlier wire-up drafts incorrectly stated this signal
  was in clk_300 — that is wrong; the Forencich `s_almost_full` flag is always
  in the write-side clock domain.)
- `symbol_filter` sits between `itch_field_extract` (stock field output) and
  `feature_extractor` (valid gating). Wire: `itch_field_extract.stock →
  symbol_filter.stock`, `symbol_filter.watchlist_hit → feature_extractor.en`.
- `axi4_lite_slave` must expose registers for: symbol filter CAM writes,
  `dropped_frames` readout (from `eth_axis_rx_wrap`), `dropped_datagrams` and
  `expected_seq_num` readout (from `moldupp64_strip`, CDC'd), and a read-only
  `gtx_lock_status` register (bit 0 = GTX PLL locked; in simulation always reads 1
  via tie-off). Define new AXI4-Lite address offsets in `lliu_pkg.sv` and update
  `axi4_lite_slave.sv` accordingly — this is an explicit RTL change alongside
  `kc705_top.sv`. Coordinate the register map with `uvm_engineer` before writing
  test sequences (see note below).
- All AXI4-Stream connections between Forencich modules use 64-bit tdata with
  tkeep, tlast, tvalid, tready per MAS §3.

### Simulation Bypass (`KINTEX7_SIM_GTX_BYPASS`)

`kc705_top.sv` must expose `mac_rx_*` signals as top-level I/O ports for Verilator
system tests. The GTX transceiver and `eth_mac_phy_10g` cannot be simulated in
Verilator. Use a conditional define to bypass them:

```systemverilog
`ifdef KINTEX7_SIM_GTX_BYPASS
    // Simulation: expose mac_rx_* as top-level I/O; bypass GTX and eth_mac_phy_10g.
    // clk_156 is driven from an additional input clock port instead of the GTX.
    // ip_complete_64, udp_complete_64, and axis_async_fifo are instantiated (not bypassed).
    input  logic        clk_156_in,           // drives clk_156 in simulation
    input  logic [63:0] mac_rx_tdata,
    input  logic [7:0]  mac_rx_tkeep,
    input  logic        mac_rx_tvalid,
    input  logic        mac_rx_tlast,
    output logic        mac_rx_tready,
`else
    // Hardware: clk_156 derived from GTX, mac_rx_* are internal wires only.
`endif
```

When `KINTEX7_SIM_GTX_BYPASS` is NOT defined, the `clk_156` domain clock is the
recovered GTX clock inside `eth_mac_phy_10g` and no `mac_rx_*` top-level ports
exist. The Yosys synthesis flow in `syn/synth.ys` must NOT define this flag.

Both `cocotb_engineer` and `uvm_engineer` must add `+define+KINTEX7_SIM_GTX_BYPASS`
to their Makefiles for any test that uses `kc705_top` as TOPLEVEL.

> **Note:** The full `kc705_top` lint command now requires Forencich source files from
> `lib/verilog-ethernet/rtl/` on the source list. See `RTL_PLAN_forencich_sim.md` §6
> for the updated complete lint invocation.

```sh
# Lint kc705_top — updated: KINTEX7_SIM_GTX_BYPASS replaces KINTEX7_SIM_MAC_BYPASS.
# Forencich IP sources from lib/verilog-ethernet/rtl/ must be included.
# See RTL_PLAN_forencich_sim.md for complete command with Forencich dependency list.
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
    <...Forencich dependency files per MAS §6.1...>
```

---

## Step 6 — Final lint pass

Run the full lint suite over all new and modified files after Step 5 is complete.
Zero warnings is the acceptance criterion before handoff to `backend_engineer`.

```sh
# Individual modules
for f in bfloat16_mul fp32_acc dot_product_engine \
          moldupp64_strip symbol_filter eth_axis_rx_wrap; do
    verilator --lint-only -Wall -sv --top-module $f \
        rtl/lliu_pkg.sv rtl/$f.sv
done

# Full design (kc705_top pulls everything in)
# Note: Forencich sources from lib/verilog-ethernet/rtl/ required — see
# RTL_PLAN_forencich_sim.md for the complete command with dependency file list.
verilator --lint-only -Wall -sv --top-module kc705_top \
    -DKINTEX7_SIM_GTX_BYPASS \
    rtl/lliu_pkg.sv \
    rtl/bfloat16_mul.sv rtl/fp32_acc.sv rtl/dot_product_engine.sv \
    rtl/itch_parser.sv rtl/itch_field_extract.sv rtl/feature_extractor.sv \
    rtl/weight_mem.sv rtl/axi4_lite_slave.sv rtl/output_buffer.sv \
    rtl/moldupp64_strip.sv rtl/symbol_filter.sv rtl/eth_axis_rx_wrap.sv \
    rtl/kc705_top.sv \
    lib/verilog-ethernet/rtl/eth_axis_rx.v \
    lib/verilog-ethernet/rtl/ip_complete_64.v \
    lib/verilog-ethernet/rtl/udp_complete_64.v \
    lib/verilog-ethernet/rtl/axis_async_fifo.v \
    <...Forencich dependency files per MAS §6.1...>
```

---

## Completion Checklist

| Step | Module(s) | Status |
|------|-----------|--------|
| 1a | `bfloat16_mul` — add output register | ⬜ |
| 1b | `fp32_acc` — two-stage accumulator | ⬜ |
| 1c | `dot_product_engine` — re-verify cycle budget | ⬜ |
| 2  | `moldupp64_strip` — header strip + seq validation | ⬜ |
| 3  | `symbol_filter` — LUT-CAM watchlist | ⬜ |
| 4  | `eth_axis_rx_wrap` — drop-on-full wrapper | ⬜ |
| 5a | `kc705_top` — full board-level integration | ⬜ |
| 5b | `axi4_lite_slave` — add CAM-write regs, dropped_frames/datagrams/seq_num readout, gtx_lock_status tie-off | ⬜ |
| 5c | `kc705_top` — add `KINTEX7_SIM_GTX_BYPASS` conditional ports | ⬜ |
| 6  | Lint: zero warnings across all files | ⬜ |
| 4  | `eth_axis_rx_wrap` — drop-on-full wrapper | ⬜ |
| 5  | `kc705_top` — full board-level integration | ⬜ |
| 6  | Lint: zero warnings across all files | ⬜ |

> When all rows are checked, hand off to `backend_engineer` for Yosys inspection
> and Vivado ML Standard synthesis + P&R. If step 6 exposes timing-critical paths
> in `dot_product_engine` that require more pipeline stages, return to step 1c
> before synthesis.
