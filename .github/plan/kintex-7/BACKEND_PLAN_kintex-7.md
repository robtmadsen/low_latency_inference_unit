# Backend Plan — Kintex-7 KC705 Synthesis & Place-and-Route

**Agent:** `backend_engineer`  
**Spec:** [Kintex-7_MAS.md](../../arch/kintex-7/Kintex-7_MAS.md)  
**Target:** Xilinx Kintex-7 KC705 (`xc7k325tffg900-2`)  
**Writes to:** `syn/` only

---

## Toolchain

| Stage | Tool | Version |
|-------|------|---------|
| Synthesis | Yosys (`synth_xilinx`) | ≥ 0.38 |
| Place & Route | nextpnr-xilinx + Project X-Ray | current main |
| Chip database | Project X-Ray `xc7k325t.bin` | from X-Ray release |
| Frame assembly | `fasm2frames` | from Project X-Ray |
| Bitstream | `xc7frames2bit` | from Project X-Ray |

Verify availability before starting:

```sh
yosys --version
nextpnr-xilinx --version
fasm2frames --help
xc7frames2bit --help
```

---

## `syn/` Directory Layout

```
syn/
  synth.ys                  # Yosys synthesis script
  constraints.xdc           # Clock definitions, I/O pin assignments,
                            # timing exceptions, Pblock constraints
  lliu.json                 # Yosys netlist → nextpnr input
  lliu_synth.v              # Flattened Verilog (inspection / linting only)
  lliu_routed.json          # nextpnr placed-and-routed netlist
  lliu.fasm                 # Flat bitstream annotations
  lliu.frames               # Assembled frames (pre-bitstream)
  lliu.bit                  # Final bitstream
  reports/
    utilization.txt         # Cell counts: LUTs, FFs, BRAMs, DSPs
    timing.txt              # Worst negative slack, critical path report
    warnings.txt            # Yosys and nextpnr warning log
```

---

## Step 1 — Pre-synthesis checklist

Before running Yosys, confirm every item below. Do **not** proceed if any item is
unresolved — escalate to `rtl_engineer` or `architect` as noted.

| # | Check | Pass criterion | Escalate to |
|---|-------|----------------|-------------|
| 1 | All RTL files present | `rtl/kc705_top.sv` and all 4 new modules compile with `verilator --lint-only` | `rtl_engineer` |
| 2 | Forencich library path known | `verilog-ethernet/` is a git submodule or symlink accessible from the repo root | `rtl_engineer` / `architect` |
| 3 | `bfloat16_mul` has registered output | `clk` port present in module signature | `rtl_engineer` |
| 4 | `dot_product_engine` pipeline depth ≥ 3–4 stages | Verified by RTL review or cocotb latency test | `rtl_engineer` |
| 5 | No latches in RTL | Verilator lint `--lint-only -Wall` produces zero latch warnings | `rtl_engineer` |
| 6 | `lliu_pkg.sv` parameter `FEATURE_VEC_LEN` value confirmed | Needed to size DSP Pblock correctly | `rtl_engineer` |

When all checks pass, proceed to Step 2.

---

## Step 2 — Write `syn/synth.ys`

The Yosys synthesis script. Read-side variables (`XRAY_DIR`, `VERILOG_ETHERNET_DIR`)
are set in the shell environment by the caller (or `make` variables in a future
`syn/Makefile`).

```tcl
# syn/synth.ys
# ------------
# Synthesis script for LLIU KC705
# Usage: yosys syn/synth.ys
# Env vars expected:
#   VERILOG_ETHERNET_DIR  — path to verilog-ethernet checkout
#   (all rtl/ files are referenced relative to repo root)

# ── Read RTL ──────────────────────────────────────────────────
# Package first (defines types used by all modules)
read_verilog -sv -I../rtl ../rtl/lliu_pkg.sv

# Forencich third-party IP (network stack)
read_verilog -sv \
  $env(VERILOG_ETHERNET_DIR)/rtl/eth_mac_phy_10g.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/eth_mac_phy_10g_rx.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/eth_mac_phy_10g_tx.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/eth_phy_10g.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/eth_phy_10g_rx.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/eth_phy_10g_tx.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/eth_mac_10g.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/eth_axis_rx.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/ip_complete_64.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/ip.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/ip_eth_rx_64.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/ip_eth_tx_64.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/udp_complete_64.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/udp.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/udp_ip_rx_64.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/udp_ip_tx_64.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/axis_async_fifo.v \
  $env(VERILOG_ETHERNET_DIR)/rtl/axis_async_fifo_adapter.v

# LLIU v1 compute core
read_verilog -sv \
  ../rtl/bfloat16_mul.sv \
  ../rtl/fp32_acc.sv \
  ../rtl/dot_product_engine.sv \
  ../rtl/itch_parser.sv \
  ../rtl/itch_field_extract.sv \
  ../rtl/feature_extractor.sv \
  ../rtl/weight_mem.sv \
  ../rtl/axi4_lite_slave.sv \
  ../rtl/output_buffer.sv

# KC705 new modules
read_verilog -sv \
  ../rtl/moldupp64_strip.sv \
  ../rtl/symbol_filter.sv \
  ../rtl/eth_axis_rx_wrap.sv \
  ../rtl/kc705_top.sv

# ── Synthesise ─────────────────────────────────────────────────
hierarchy -check -top kc705_top

# ── Latch check — MUST run BEFORE synth_xilinx ─────────────────
# After synth_xilinx maps the design, $dlatch cells become LDCE/LDPE Xilinx
# primitives and this check will silently pass even if latches were inferred.
# Run proc + opt_clean first to elaborate always blocks and expose $dlatch cells.
proc
opt_clean
# Hard abort: any latch = RTL bug. Escalate to rtl_engineer before proceeding.
select -assert-none t:$dlatch t:$adlatch t:$dlatchsr

# synth_xilinx targets Xilinx 7-series and UltraScale primitives.
# -flatten: merge all hierarchy into a single module for P&R.
# -nodsp: NOT set — allow DSP48E1 inference for bfloat16_mul / fp32_acc.
# -nocarry: NOT set — allow carry-chain inference for adders.
synth_xilinx -top kc705_top -flatten

# ── Write outputs ──────────────────────────────────────────────
write_json syn/lliu.json
write_verilog -noattr syn/lliu_synth.v

# ── Resource report ────────────────────────────────────────────
tee -o syn/reports/utilization.txt stat -tech xilinx
```

> **Important:** The latch check runs **before** `synth_xilinx` so that `$dlatch`
> cells are visible. After synthesis, latches are mapped to `LDCE`/`LDPE` Xilinx
> primitives and the generic cell check would silently pass. If the check fires,
> do not proceed — escalate to `rtl_engineer`.

---

## Step 3 — Write `syn/constraints.xdc`

This file defines all timing constraints, I/O standards, and floorplan Pblocks.
It is consumed by nextpnr-xilinx at P&R time.

### 3.1 Clock definitions

```tcl
# ── Primary clocks ──────────────────────────────────────────────
# 200 MHz system oscillator (LVDS differential input, KC705 pin AD12)
create_clock -name sys_clk -period 5.000 [get_ports sys_clk_p]

# 156.25 MHz MGT reference clock (SFP cage, IBUFDS_GTE2 output)
create_clock -name mgt_refclk -period 6.400 [get_ports mgt_refclk_p]

# ── Generated clocks (MMCM outputs) ─────────────────────────────
# clk_300: 300 MHz application hot path  (primary target)
create_generated_clock -name clk_300 \
    -source [get_ports sys_clk_p] \
    -multiply_by 3 -divide_by 2 \
    [get_pins u_mmcm/CLKOUT0]

# clk_125: 125 MHz AXI4-Lite / PCIe interface (optional)
create_generated_clock -name clk_125 \
    -source [get_ports sys_clk_p] \
    -multiply_by 5 -divide_by 8 \
    [get_pins u_mmcm/CLKOUT1]

# clk_156: 156.25 MHz GTX recovered clock (network domain)
# Declared as a generated clock derived from the GTX transceiver.
# Exact net name depends on eth_mac_phy_10g instantiation in kc705_top.
create_generated_clock -name clk_156 \
    -source [get_ports mgt_refclk_p] \
    -divide_by 1 \
    [get_pins u_mac_phy/u_phy/u_gt/RXOUTCLK]
```

### 3.2 Clock domain crossing exceptions

```tcl
# ── CDC exceptions ──────────────────────────────────────────────
# Scope false_paths to paths that pass THROUGH the async FIFO cell hierarchy.
# This covers only the gray-code pointer crossing synchronisers inside the FIFO,
# not all paths between the two clock domains — blanket cross-domain false_paths
# would silently exempt any improperly synchronised signal added in future.
#
# The axis_async_fifo s_almost_full output is in the WRITE domain (clk_156);
# it connects directly to eth_axis_rx_wrap (also clk_156) — no CDC crossing and
# no false_path needed for that signal.
set_false_path \
    -from [get_clocks clk_156] \
    -to   [get_clocks clk_300] \
    -through [get_cells -hierarchical -filter {NAME =~ *axis_async_fifo*}]
set_false_path \
    -from [get_clocks clk_300] \
    -to   [get_clocks clk_156] \
    -through [get_cells -hierarchical -filter {NAME =~ *axis_async_fifo*}]

# moldupp64_strip → 300 MHz domain: seq_num / msg_count are stable CDC registers
# sampled by the 300 MHz domain only after a domain-crossing handshake.
# If nextpnr-xilinx does not support -through on set_false_path, use max_delay
# with a 1× clk_300 period to allow one setup margin for the receiving FF.
set_max_delay 3.333 -datapath_only \
    -from [get_cells -hierarchical -filter {NAME =~ *moldupp64_strip*seq_num*}] \
    -to   [get_clocks clk_300]
```

> **Rationale:** scoped false_paths avoid silently ignoring unsynchronised signals
> added in future. All `clk_156`-internal and `clk_300`-internal paths remain
> fully timing-checked. The `axis_async_fifo` uses internal gray-code synchronisers
> that make its cross-domain data paths structurally safe.
>
> **nextpnr-xilinx note:** if `-through` is not honoured by the tool, fall back to
> blanket `set_false_path` only after verifying that every cross-domain signal is
> either inside `axis_async_fifo` or an explicitly-CDC'd register. Document any
> such fallback in `syn/reports/warnings.txt`.

### 3.3 I/O pin assignments (KC705)

```tcl
# ── SFP+ cage J3 (10GbE) ────────────────────────────────────────
set_property PACKAGE_PIN H2  [get_ports sfp_tx_p]
set_property PACKAGE_PIN H1  [get_ports sfp_tx_n]
set_property PACKAGE_PIN G4  [get_ports sfp_rx_p]
set_property PACKAGE_PIN G3  [get_ports sfp_rx_n]

# ── MGT reference clock (156.25 MHz, SFP cage) ──────────────────
set_property PACKAGE_PIN C8  [get_ports mgt_refclk_p]
set_property PACKAGE_PIN C7  [get_ports mgt_refclk_n]

# ── 200 MHz system oscillator ────────────────────────────────────
set_property PACKAGE_PIN AD12 [get_ports sys_clk_p]
set_property PACKAGE_PIN AD11 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_n]

# ── CPU_RESET button (active-high, LVCMOS15) ────────────────────
set_property PACKAGE_PIN AB7  [get_ports cpu_reset]
set_property IOSTANDARD LVCMOS15 [get_ports cpu_reset]
```

### 3.4 DSP Pblock — dot_product_engine

This Pblock co-locates all DSP48E1 slices for `dot_product_engine` with their
adjacent LUT/FF resources to minimize routing wire length through the DSP columns.
Adjust site ranges after inspecting the first P&R result.

```tcl
# ── DSP Pblock ───────────────────────────────────────────────────
create_pblock pblock_dpe
add_cells_to_pblock [get_pblocks pblock_dpe] \
    [get_cells -hierarchical -filter {NAME =~ *dot_product_engine*}]

# Target DSP column X3 (centre-right of die), rows Y0–Y19.
# Includes adjacent SLICE columns for pipeline registers.
resize_pblock [get_pblocks pblock_dpe] \
    -add {SLICE_X60Y0:SLICE_X79Y49 DSP48_X3Y0:DSP48_X3Y19}

# Optionally: constrain weight_mem BRAMs close to the DSP column.
create_pblock pblock_wmem
add_cells_to_pblock [get_pblocks pblock_wmem] \
    [get_cells -hierarchical -filter {NAME =~ *weight_mem*}]
resize_pblock [get_pblocks pblock_wmem] \
    -add {RAMB36_X4Y0:RAMB36_X4Y9}
```

### 3.5 Timing exceptions for reset synchronisers

```tcl
# Reset synchronisers — only the FIRST capture flop (FF1) should have a
# multicycle exception. FF2's output drives downstream reset logic and must
# meet single-cycle timing at the destination domain frequency.
#
# Convention: the RTL engineer must name the first stage consistently so this
# filter is unambiguous. If sync_reset uses always_ff naming, rename ff1 to
# match *sync_reset*/ff1_reg in synthesis output.
#
# WARNING: Do NOT use -from [get_cells *sync_reset*] without a stage filter —
#          that would apply the 2-cycle relaxation to FF2's output paths too,
#          allowing downstream reset logic to silently violate single-cycle timing.
set_multicycle_path -setup 2 -from \
    [get_cells -hierarchical -filter {NAME =~ *sync_reset*/ff1_reg*}]
set_multicycle_path -hold  1 -from \
    [get_cells -hierarchical -filter {NAME =~ *sync_reset*/ff1_reg*}]
```

---

## Step 4 — Run synthesis

```sh
cd /path/to/repo/root

export VERILOG_ETHERNET_DIR=./verilog-ethernet

mkdir -p syn/reports

yosys syn/synth.ys 2>&1 | tee syn/reports/warnings.txt
```

### Pass criteria

| Check | Tool output to inspect | Action on failure |
|-------|------------------------|-------------------|
| Zero latches | `select -assert-none` exits cleanly | Escalate to `rtl_engineer` |
| Zero unresolved modules | No `Warning: Module '...' not found` lines | Check Forencich file list in `synth.ys` |
| DSP48E1 inferred | `Number of DSP48E1:` > 0 in utilization report | Review `bfloat16_mul` / `fp32_acc` RTL; escalate to `rtl_engineer` if zero DSPs |
| BRAM inferred | `Number of RAMB36E1:` > 0 | Review `weight_mem` RTL |
| LUT count < 150,000 | Utilization report | — (xc7k325t has 203,800 LUTs) |
| FF count < 300,000 | Utilization report | — (xc7k325t has 407,600 FFs) |
| `lliu.json` written | File exists and non-empty | Check Yosys `write_json` invocation |

Save the full utilization report:

```sh
grep -E "Number of|LUT|Flip|BRAM|DSP" syn/reports/utilization.txt
```

---

## Step 5 — Run Place & Route (300 MHz attempt)

### 5.1 First P&R run — 300 MHz target

```sh
nextpnr-xilinx \
  --chipdb /path/to/xray/xc7k325t.bin \
  --xdc syn/constraints.xdc \
  --json syn/lliu.json \
  --write syn/lliu_routed.json \
  --fasm syn/lliu.fasm \
  --timing-allow-fail \
  2>&1 | tee syn/reports/timing.txt
```

`--timing-allow-fail` is included for the first run only so a timing report is
always generated even if the tool cannot close timing. Remove it once timing closes.

### 5.2 Read the timing report

Extract the worst negative slack (WNS) immediately after P&R:

```sh
grep -E "Max frequency|Slack|critical" syn/reports/timing.txt | head -20
```

### 5.3 Decision tree

```
WNS ≥ 0 ns on all paths in clk_300 domain?
  ├── YES → Timing closed at 300 MHz. Proceed to Step 6.
  └── NO  → Which path is failing?
        ├── Path through dot_product_engine DSPs
        │     → Step 5.4: DSP Pblock tuning
        ├── Path through symbol_filter CAM comparison tree
        │     → Step 5.5: CAM register retiming
        ├── Path through axis_async_fifo read logic
        │     → Verify false_path constraint applied; if missing, add to XDC
        └── Any other path after DSP tuning doesn't close
              → Step 5.6: Fall back to 250 MHz
```

### 5.4 DSP Pblock tuning (if timing fails through dot_product_engine)

1. Open nextpnr-xilinx GUI and inspect placement of `dot_product_engine` cells.
2. Identify whether DSP slices are spread across multiple columns (causes long routing wires).
3. Tighten the Pblock to force placement into a single DSP column:

   ```tcl
   # Tighten: single column, rows Y0-Y9 only
   resize_pblock [get_pblocks pblock_dpe] \
       -add {SLICE_X64Y0:SLICE_X71Y24 DSP48_X3Y0:DSP48_X3Y9}
   ```

4. Re-run P&R. If DSP placement is already tight and timing still fails, verify
   pipeline depth with `rtl_engineer` — the `bfloat16_mul` output register and
   two-stage `fp32_acc` must both be present.

5. If WNS is between −0.2 ns and 0 ns after Pblock tuning, try nextpnr seed sweep:

   ```sh
   for seed in 1 2 3 4 5; do
     nextpnr-xilinx --chipdb /path/to/xray/xc7k325t.bin \
       --xdc syn/constraints.xdc \
       --json syn/lliu.json \
       --write syn/lliu_routed_seed${seed}.json \
       --fasm syn/lliu_seed${seed}.fasm \
       --seed ${seed} \
       2>&1 | grep -E "Max frequency|Slack" | tee -a syn/reports/timing_seeds.txt
   done
   ```

   Use the seed that produces the best (most positive) WNS.

### 5.5 CAM comparison tree (if timing fails through symbol_filter)

The 64×64-bit parallel equality tree in `symbol_filter` may have a deep LUT cascade
after flattening. If nextpnr reports a failing path through `symbol_filter`:

1. Check the critical path start/end points in `syn/reports/timing.txt`.
2. If the path is `stock → match_vec → watchlist_hit_comb → watchlist_hit_reg`:
   - The registered output on `watchlist_hit` should absorb this — verify the FF
     register is present in `lliu_synth.v` (grep for `watchlist_hit`).
   - If Yosys has merged the output register back into combinational logic, add
     `(* dont_touch = "true" *)` on the `watchlist_hit` register in RTL.
   - Escalate to `rtl_engineer` if RTL change needed.

### 5.6 Fall back to 250 MHz (if 300 MHz does not close after tuning)

Change the MMCM `clk_300` output to 250 MHz in `constraints.xdc`:

```tcl
# Change clk_300 → clk_250 (250 MHz fallback)
# Replace the existing create_generated_clock for clk_300:
create_generated_clock -name clk_300 \
    -source [get_ports sys_clk_p] \
    -multiply_by 5 -divide_by 4 \
    [get_pins u_mmcm/CLKOUT0]
```

The signal name `clk_300` is kept for naming consistency in the constraints file;
the actual frequency is now 250 MHz. Add a comment noting the fallback.

Re-run P&R:

```sh
nextpnr-xilinx \
  --chipdb /path/to/xray/xc7k325t.bin \
  --xdc syn/constraints.xdc \
  --json syn/lliu.json \
  --write syn/lliu_routed.json \
  --fasm syn/lliu.fasm \
  2>&1 | tee syn/reports/timing.txt
```

If 250 MHz still fails, report the critical path to `architect` before making any
further constraint changes. Do not reduce the clock below 250 MHz without approval.

---

## Step 6 — Verify timing closure

After P&R produces WNS ≥ 0 on all clocked paths:

```sh
# Confirm no negative slack paths remain
grep -c "negative slack" syn/reports/timing.txt   # must return 0

# Record the achieved frequency
grep "Max frequency" syn/reports/timing.txt
```

Save final timing report to `syn/reports/timing.txt`. Format the header:

```
LLIU KC705 — Timing Report
Target:   xc7k325tffg900-2
Clock:    clk_300 (300 MHz) / clk_250 fallback
WNS:      <value> ns
Achieved: <value> MHz
Date:     <YYYY-MM-DD>
```

---

## Step 7 — Bitstream generation (optional)

Only proceed if a physical KC705 board is available for bring-up.

```sh
# Step 7a: assemble frames from FASM
fasm2frames \
  --part xc7k325tffg900-2 \
  syn/lliu.fasm > syn/lliu.frames

# Step 7b: convert frames to bitstream
xc7frames2bit \
  --part-file /path/to/xray/xc7k325tffg900-2.yaml \
  --input-file syn/lliu.frames \
  --output-file syn/lliu.bit

echo "Bitstream written: syn/lliu.bit"
ls -lh syn/lliu.bit
```

---

## Step 8 — Utilization summary

After successful P&R, capture the final utilization summary to `syn/reports/utilization.txt`.
Confirm all resources are within the xc7k325t budget:

| Resource | Available (xc7k325t) | Target budget | Check |
|----------|----------------------|---------------|-------|
| LUTs | 203,800 | < 150,000 (~74%) | `grep "Number of LUTs" ...` |
| FFs | 407,600 | < 250,000 (~61%) | — |
| DSP48E1 | 840 | expected ~8–16 | > 0 required |
| RAMB36E1 | 445 | expected 2–4 | > 0 required |
| RAMB18E1 | 890 | expected 0–4 | — |
| BUFGCTRL | 32 | ≤ 4 used | clk_156, clk_300, optionally clk_125 + spare |
| GTX transceivers | 16 | exactly 1 used | SFP+ cage J3 |
| IOBs | varies | ≤ 20 used | sys_clk, mgt_refclk, cpu_reset |

Flag any resource category above 80% utilization as a risk and note it in
`syn/reports/utilization.txt`.

---

## Step 9 — Clean up and commit

After timing closes and reports are written:

```sh
# Verify expected output files exist
ls -lh syn/lliu.json syn/lliu_synth.v syn/lliu_routed.json \
       syn/lliu.fasm syn/reports/utilization.txt syn/reports/timing.txt

# Remove per-seed scratch files (keep only the winning routed netlist)
rm -f syn/lliu_routed_seed*.json syn/lliu_seed*.fasm
```

Commit only `syn/` files. Never commit `rtl/`, `tb/`, or `scripts/` modifications.

---

## Escalation Rules

| Situation | Action |
|-----------|--------|
| RTL has latches | Stop synthesis. Escalate to `rtl_engineer`. |
| Z DSP48E1 inferred | Escalate to `rtl_engineer` to verify `bfloat16_mul` / `fp32_acc` DSP pragmas. |
| Spec-conflicting constraint needed | Stop. Escalate to `architect`. |
| Timing does not close at 250 MHz | Report critical path. Escalate to `architect`. Do not reduce clock below 250 MHz unilaterally. |
| Forencich IP file missing | Escalate to `architect` to confirm submodule state. |

---

## Completion Checklist

| Step | Item | Status |
|------|------|--------|
| 1 | Pre-synthesis checklist: all 6 items pass | ⬜ |
| 2 | `syn/synth.ys` written | ⬜ |
| 3 | `syn/constraints.xdc` written (clocks, pins, Pblock, CDC exceptions) | ⬜ |
| 4 | Synthesis passes: zero latches, DSP/BRAM inferred, `lliu.json` generated | ⬜ |
| 4 | `syn/reports/utilization.txt` written | ⬜ |
| 5 | P&R completes: WNS ≥ 0 on all `clk_300` paths | ⬜ |
| 5 | (If applicable) DSP Pblock tuned or seed sweep applied | ⬜ |
| 5 | (If applicable) Fallback to 250 MHz approved and applied | ⬜ |
| 6 | `syn/reports/timing.txt` written with achieved frequency | ⬜ |
| 7 | (Optional) Bitstream `syn/lliu.bit` generated for board bring-up | ⬜ |
| 8 | Utilization: all resources within budget, no category > 80% | ⬜ |
| 9 | `syn/` committed; no files outside `syn/` modified | ⬜ |

> Prerequisite: RTL plan (RTL_PLAN_kintex-7.md) Step 6 (lint clean) must be complete
> before Step 1 of this backend plan can pass.
