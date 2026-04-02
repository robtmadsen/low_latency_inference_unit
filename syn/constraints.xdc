# syn/constraints.xdc
# -------------------
# Timing constraints, CDC exceptions, and Pblock floorplan for LLIU on the
# Xilinx Kintex-7 (xc7k160tffg676-2), targeting Vivado ML Standard (free tier).
#
# Timing target: 300 MHz (clk_300)
# Fallback:      250 MHz (update create_generated_clock for clk_300 if needed — see Step 5.7)
#
# I/O PIN ASSIGNMENTS (section 4) are derived from the original KC705 board
# (xc7k325tffg900-2) as a reference template.  They WILL NOT match a non-KC705
# XC7K160T board.  Update all PACKAGE_PIN values in section 4 to match the
# actual target board schematic before running Vivado P&R.

# ═══════════════════════════════════════════════════════════════════
# 1. Primary clocks
# ═══════════════════════════════════════════════════════════════════

# 200 MHz system oscillator (LVDS differential input, KC705 pin AD12)
create_clock -name sys_clk -period 5.000 [get_ports sys_clk_p]

# 156.25 MHz MGT reference clock (SFP+ cage, IBUFDS_GTE2 output)
create_clock -name mgt_refclk -period 6.400 [get_ports mgt_refclk_p]

# ═══════════════════════════════════════════════════════════════════
# 2. Generated clocks (MMCM outputs)
# ═══════════════════════════════════════════════════════════════════

# clk_300: 300 MHz application hot path  (primary performance target)
# MMCM: VCO = 200 × 3 / 2 = 300 MHz (within 600–1200 MHz range)
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
# Derived from the GTX transceiver RXOUTCLK.
# The exact net name depends on eth_mac_phy_10g instantiation in kc705_top.
create_generated_clock -name clk_156 \
    -source [get_ports mgt_refclk_p] \
    -divide_by 1 \
    [get_pins u_mac_phy/u_phy/u_gt/RXOUTCLK]

# ═══════════════════════════════════════════════════════════════════
# 3. Clock domain crossing exceptions
# ═══════════════════════════════════════════════════════════════════
#
# Scoped false_paths cover only paths THROUGH the axis_async_fifo cell
# hierarchy (gray-code pointer synchronisers).  This avoids silently
# exempting any future unsynchronised signal added between the domains.
# All clk_156-internal and clk_300-internal paths remain fully timed.
#
# NOTE: The axis_async_fifo s_almost_full output is in the WRITE domain
# (clk_156) and connects only to eth_axis_rx_wrap (also clk_156).
# No false_path is needed for that signal.

set_false_path \
    -from [get_clocks clk_156] \
    -to   [get_clocks clk_300] \
    -through [get_cells -hierarchical -filter {NAME =~ *axis_async_fifo*}]

set_false_path \
    -from [get_clocks clk_300] \
    -to   [get_clocks clk_156] \
    -through [get_cells -hierarchical -filter {NAME =~ *axis_async_fifo*}]

# moldupp64_strip → 300 MHz domain: seq_num / msg_count are stable CDC
# registers sampled by the 300 MHz domain only after a domain-crossing
# handshake.  Allow one setup margin at the receiving FF.
# Vivado honours -through on set_false_path; the scoped false_paths above
# cover this. If needed, replace with a blanket set_false_path and document
# the fallback in syn/reports/warnings.txt.
set_max_delay 3.333 -datapath_only \
    -from [get_cells -hierarchical -filter {NAME =~ *moldupp64_strip*seq_num*}] \
    -to   [get_clocks clk_300]

# ═══════════════════════════════════════════════════════════════════
# 4. I/O pin assignments (KC705 reference — UPDATE FOR TARGET BOARD)
# ═══════════════════════════════════════════════════════════════════
# *** These pins are from the KC705 (xc7k325t) reference design.   ***
# *** They must be replaced with the correct pins for your actual   ***
# *** XC7K160T board before running Vivado implementation.         ***

# ── SFP+ cage J3 (10GbE) ─────────────────────────────────────────
set_property PACKAGE_PIN H2   [get_ports sfp_tx_p]
set_property PACKAGE_PIN H1   [get_ports sfp_tx_n]
set_property PACKAGE_PIN G4   [get_ports sfp_rx_p]
set_property PACKAGE_PIN G3   [get_ports sfp_rx_n]

# ── MGT reference clock (156.25 MHz, SFP cage) ───────────────────
set_property PACKAGE_PIN C8   [get_ports mgt_refclk_p]
set_property PACKAGE_PIN C7   [get_ports mgt_refclk_n]

# ── 200 MHz system oscillator ─────────────────────────────────────
set_property PACKAGE_PIN AD12 [get_ports sys_clk_p]
set_property PACKAGE_PIN AD11 [get_ports sys_clk_n]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_p]
set_property IOSTANDARD DIFF_SSTL15 [get_ports sys_clk_n]

# ── CPU_RESET button (active-high, LVCMOS15) ─────────────────────
set_property PACKAGE_PIN AB7  [get_ports cpu_reset]
set_property IOSTANDARD LVCMOS15 [get_ports cpu_reset]

# ═══════════════════════════════════════════════════════════════════
# 5. Floorplan Pblocks
# ═══════════════════════════════════════════════════════════════════

# ── dot_product_engine DSP Pblock ────────────────────────────────
# Co-locates all DSP48E1 slices for dot_product_engine with adjacent
# LUT/FF resources to minimize wire length through the DSP columns.
# Target: DSP column X3 (centre-right of die), rows Y0–Y19.
# Adjust site ranges after inspecting the first P&R result.
create_pblock pblock_dpe
add_cells_to_pblock [get_pblocks pblock_dpe] \
    [get_cells -hierarchical -filter {NAME =~ *dot_product_engine*}]
resize_pblock [get_pblocks pblock_dpe] \
    -add {SLICE_X60Y0:SLICE_X79Y49 DSP48_X3Y0:DSP48_X3Y19}

# ── weight_mem BRAM Pblock ────────────────────────────────────────
# Keep weight_mem BRAMs close to the DSP column to minimize feature
# vector routing distance.
create_pblock pblock_wmem
add_cells_to_pblock [get_pblocks pblock_wmem] \
    [get_cells -hierarchical -filter {NAME =~ *weight_mem*}]
resize_pblock [get_pblocks pblock_wmem] \
    -add {RAMB36_X4Y0:RAMB36_X4Y9}

# ═══════════════════════════════════════════════════════════════════
# 6. Reset synchroniser multicycle exceptions
# ═══════════════════════════════════════════════════════════════════
#
# Only the FIRST capture flop (ff1_reg) gets the 2-cycle setup
# relaxation.  FF2's output drives downstream reset logic and must
# meet single-cycle timing.
#
# WARNING: Do NOT apply -from [get_cells *sync_reset*] without a stage
# filter — that would silently relax FF2 output paths too.
set_multicycle_path -setup 2 -from \
    [get_cells -hierarchical -filter {NAME =~ *sync_reset*/ff1_reg*}]
set_multicycle_path -hold  1 -from \
    [get_cells -hierarchical -filter {NAME =~ *sync_reset*/ff1_reg*}]
