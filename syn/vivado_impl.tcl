# syn/vivado_impl.tcl
# -------------------
# Vivado ML Standard — synthesis, place-and-route, and bitstream generation
# for LLIU v2.0 targeting xc7k160tffg676-2.
#
# Synthesis target: lliu_top_v2 (v2.0 inference+trading pipeline).
# kc705_top (board wrapper with GTX MAC/PHY, IBUFDS, MMCM) is excluded —
# Xilinx board primitives cause constant-propagation sweeps of core logic.
# Clock: 312.5 MHz (3.200 ns) per MAS §6.
#
# Usage (run from repository root):
#   vivado -mode batch -source syn/vivado_impl.tcl
#   Example:
#     vivado -mode batch -source syn/vivado_impl.tcl \
#            2>&1 | tee syn/reports/vivado.log

set PART xc7k160tffg676-2

# ── Read sources ───────────────────────────────────────────────────────────
# Package first — defines parameters/types used by all LLIU modules.
read_verilog -sv rtl/lliu_pkg.sv

# LLIU v2.0 compute core — all submodules + top
# Order: leaves before parents (Vivado is not order-sensitive but this is
# easier to audit against the lint command).
read_verilog -sv {
  rtl/bfloat16_mul.sv
  rtl/fp32_acc.sv
  rtl/dot_product_engine.sv
  rtl/weight_mem.sv
  rtl/output_buffer.sv
  rtl/lliu_core.sv
  rtl/itch_parser_v2.sv
  rtl/order_book.sv
  rtl/symbol_filter.sv
  rtl/feature_extractor_v2.sv
  rtl/strategy_arbiter.sv
  rtl/risk_check.sv
  rtl/ouch_engine.sv
  rtl/ptp_core.sv
  rtl/timestamp_tap.sv
  rtl/latency_histogram.sv
  rtl/snapshot_mux.sv
  rtl/lliu_top_v2.sv
}

# ── Constraints ────────────────────────────────────────────────────────────
# Use the lliu_top-specific constraints file (300 MHz clock, false-path I/Os).
# constraints.xdc targets kc705_top hierarchy and is kept for reference only.
read_xdc syn/constraints_lliu_top.xdc

# ── Synthesis ──────────────────────────────────────────────────────────────
# Thread policy defaults for m7i.8xlarge.
# - Synthesis default: 8 threads (override: VIVADO_SYNTH_THREADS)
# - Implementation default: 12 threads (override: VIVADO_IMPL_THREADS)
set synth_threads 8
if {[info exists ::env(VIVADO_SYNTH_THREADS)] && [string is integer -strict $::env(VIVADO_SYNTH_THREADS)] && $::env(VIVADO_SYNTH_THREADS) > 0} {
  set synth_threads $::env(VIVADO_SYNTH_THREADS)
}
set impl_threads 12
if {[info exists ::env(VIVADO_IMPL_THREADS)] && [string is integer -strict $::env(VIVADO_IMPL_THREADS)] && $::env(VIVADO_IMPL_THREADS) > 0} {
  set impl_threads $::env(VIVADO_IMPL_THREADS)
}
set_param general.maxThreads $synth_threads
puts "INFO: VIVADO_SYNTH_THREADS=$synth_threads"
puts "INFO: VIVADO_IMPL_THREADS=$impl_threads"

# Keep Vivado scratch data on disk-backed storage by default.
# Override with VIVADO_LOCALAPPDATA when needed.
set localappdata ""
if {[info exists ::env(VIVADO_LOCALAPPDATA)] && $::env(VIVADO_LOCALAPPDATA) ne ""} {
  set localappdata $::env(VIVADO_LOCALAPPDATA)
} else {
  set home_dir "/tmp"
  if {[info exists ::env(HOME)] && $::env(HOME) ne ""} {
    set home_dir $::env(HOME)
  }
  set localappdata "$home_dir/.Xilinx/localappdata"
}
if {[catch {file mkdir $localappdata}]} {
  set localappdata "/tmp/xilinx_localappdata"
  file mkdir $localappdata
}
set ::env(XILINX_LOCALAPPDATA) $localappdata
puts "INFO: XILINX_LOCALAPPDATA=$::env(XILINX_LOCALAPPDATA)"

# -flatten_hierarchy none: preserve all module boundaries so that Cross
# Boundary optimises each module independently.  order_book contains 16×1000
# distributed-RAM cells; with -flatten_hierarchy full these flood a single
# flat netlist and stall the area optimiser for 2+ hours.  Keeping hierarchy
# intact lets the optimiser handle order_book's LUTRAMs in isolation.
# -directive RuntimeOptimized: reduced-effort passes (faster wall time).
# DSP48E1 and carry-chain inference left on (no -no_dsp / -no_lc).
synth_design -top lliu_top_v2 -part ${PART} -flatten_hierarchy none -directive RuntimeOptimized

# Post-synthesis utilization snapshot (before opt/place changes cell counts)
report_utilization -file syn/reports/utilization_synth.txt

# Implementation stages can use a slightly higher thread count on m7i.8xlarge.
set_param general.maxThreads $impl_threads

# ── Run 50 guard: prevent opt_design relay DSP on band_product_h ───────────
# opt_design sees fo=18 on the DSP PREG output (band_product_h_reg/P) and
# inserts a relay DSP using the C-port register (CREG=1).  The CREG setup arc
# is -1.208 ns; at 312.5 MHz this causes WNS -0.174 ns (Runs 46–49).
# RTL DONT_TOUCH attributes failed: they lock the PREG cell and block all
# opt_design passes for the entire module (1588 EPs in Run 49).
# Solution: mark only the OUTPUT NETS DONT_TOUCH post-synthesis, before
# opt_design.  This prevents relay insertion on these specific nets while
# leaving opt_design free to optimize all other paths in the design.
set bph_nets [get_nets -hierarchical -filter {NAME =~ *u_risk*band_product_h*}]
if {[llength $bph_nets] > 0} {
    set_property DONT_TOUCH true $bph_nets
    puts "INFO: Run50 - DONT_TOUCH applied to [llength $bph_nets] band_product_h nets; relay DSP blocked"
} else {
    puts "WARNING: Run50 - No band_product_h nets matched; relay DSP may be inserted"
}

# ── Run 63 note: band_thresh_r relay DSP removed at synthesis level ────────
# Run 62 DONT_TOUCH confirmed relay is synthesis-created: matched 100 nets
# but WNS unchanged (-0.168 ns). RTL fix in Run 63: changed band_thresh_r
# from use_dsp="yes" to use_dsp="no" → no longer DSP infrastructure, no relay.
# DONT_TOUCH guard removed; it was locking the relay nets and preventing
# opt_design from removing them.

# ── Run 62/63 guard: prevent opt_design relay DSP on msg_pxvol_s05 ────────
# msg_pxvol_s05 DSP PREG output (fo=18) → msg_pxvol_s075_reg CREG relay
# (DSP48_X5Y*, Setup_dsp48e1_CLK_C = -1.208 ns) → WNS -0.124 ns (Run 61).
# Same mechanism as band_thresh_r; DONT_TOUCH on P-output nets blocks relay.
set pxvol_nets [get_nets -hierarchical -filter {NAME =~ *u_feat_ext*msg_pxvol_s05*}]
if {[llength $pxvol_nets] > 0} {
    set_property DONT_TOUCH true $pxvol_nets
    puts "INFO: Run62 - DONT_TOUCH applied to [llength $pxvol_nets] msg_pxvol_s05 nets; relay DSP blocked"
} else {
    puts "WARNING: Run62 - No msg_pxvol_s05 nets matched"
}

# ── Run 65: weight_mem core2 sub-pblock ──────────────────────────────────
# Post-Route 64: weight_mem rd_data FDRE lands at SLICE_X46Y98 and routes
# 0.535 ns (fo=1) UPWARD 2 rows to DPE bfloat16_mul LUT at SLICE_X45Y100.
# Adjacent-slice routes are normally 0.10–0.15 ns; 0.535 ns indicates upward-
# routing congestion through the clock-region boundary near Y99/Y100.
# Additionally the FDRE at Y98 has SCD=4.353 ns vs the DSP at Y~80 with
# DCD route=1.160 ns, giving -0.232 ns adverse clock skew.
# Fix: constrain weight_mem in core2 to SLICE_X30Y103:SLICE_X65Y119 (upper
# half of CLOCKREGION_X0Y2).  The FDRE moves from Y98→Y103+ and routes
# DOWNWARD to LUT (Y100), avoiding the congested upward crossing.
# Estimated route improvement: ~0.43 ns.  Clock skew penalty: ~0.07 ns.
# Net gain: ~+0.36 ns — closes the 2-EP / -0.011 ns violation.
set wm2_cells [get_cells -hierarchical -filter {NAME =~ gen_cores[2].u_core/u_weight_mem/*}]
if {[llength $wm2_cells] > 0} {
    create_pblock pblock_wm_core2
    add_cells_to_pblock [get_pblocks pblock_wm_core2] $wm2_cells
    resize_pblock [get_pblocks pblock_wm_core2] -add {SLICE_X30Y103:SLICE_X65Y119}
    puts "INFO: Run65 - pblock_wm_core2 active: SLICE_X30Y103:SLICE_X65Y119 ([llength $wm2_cells] cells)"
} else {
    puts "WARNING: Run65 - No gen_cores[2].u_core/u_weight_mem cells matched"
}

# ── Implementation ─────────────────────────────────────────────────────────
opt_design

place_design
# Checkpoint after placement — recoverable if routing is interrupted.
write_checkpoint -force syn/lliu_placed.dcp

# Aggressive physical optimisation pass — targets routing-critical paths
# through the DSP columns and the symbol_filter CAM comparison tree.
phys_opt_design -directive AggressiveExplore
write_checkpoint -force syn/lliu_physopt.dcp

# Targeted pre-route replication of fo=54 DPE FSM state[1] nets.
# The state[1] net fans out to 54 endpoints per DPE instance (8 total); the
# resulting 0.557 ns routing hop on the state→man_product_r_reg/A[7] path
# caused a 10 ps setup violation in Run 57.  -force_replication_on_nets is
# only supported pre-route (between place_design and route_design).
phys_opt_design -force_replication_on_nets [get_nets -hierarchical -filter {NAME =~ *u_dpe/state[1]}]

route_design

# Post-route physical optimisation — replicates high-fanout drivers and
# inserts hold buffers on paths that remain marginal after routing.
# Needed to close the fo=24 leading-zero encoder net in feature_extractor Stage 2b.
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation

# Run 65: extra closing pass for any residual EPs after weight_mem pblock move
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation

# ── Save routed checkpoint ─────────────────────────────────────────────────
# Allows bitstream regeneration without re-running P&R.
write_checkpoint -force syn/lliu_routed.dcp

# ── Reports ────────────────────────────────────────────────────────────────
report_utilization   -file syn/reports/utilization.txt
report_timing_summary -file syn/reports/timing.txt -check_timing_verbose
report_timing -nworst 20 -sort_by slack -path_type summary -file syn/reports/timing_nworst20.txt

# CDC check — any CRITICAL or HIGH crossing is a hard stop (MAS §6.1).
report_cdc -verbose -file syn/reports/cdc.txt

# ── Bitstream ──────────────────────────────────────────────────────────────
# Board-level pin assignments (constraints.xdc §4) must be appended before
# running this step against physical hardware.
# Suppress DRC violations for unassigned I/O standards and locations — this
# design targets synthesis/P&R closure verification only; physical pin
# assignments are in a separate board-specific XDC.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
write_bitstream -force syn/lliu.bit
