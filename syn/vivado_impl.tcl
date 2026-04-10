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
  rtl/lliu_top_v2.sv
}

# ── Constraints ────────────────────────────────────────────────────────────
# Use the lliu_top-specific constraints file (300 MHz clock, false-path I/Os).
# constraints.xdc targets kc705_top hierarchy and is kept for reference only.
read_xdc syn/constraints_lliu_top.xdc

# ── Synthesis ──────────────────────────────────────────────────────────────
# Cap threads to 4 to keep peak memory within the 32 GB instance limit.
# With 7 threads Vivado peaked at 24.3 GB + 5.7 GB workers = OOM.
# 4 threads limits workers to ~3.3 GB, total < 22 GB.
set_param general.maxThreads 4

# Redirect .Xil temp files to /dev/shm (32 GB RAM-backed tmpfs, separate
# from the root filesystem) to prevent root disk exhaustion across runs.
set ::env(XILINX_LOCALAPPDATA) /dev/shm

# -flatten_hierarchy none: keeps module hierarchy intact.
# -directive RuntimeOptimized: explicitly skips cross-boundary and area
# optimisation passes that caused an 8+ hour hang on r5.2xlarge.
# Pblock cell filters (gen_cores[k].u_core/*) still resolve correctly.
# DSP48E1 and carry-chain inference left on (no -no_dsp / -no_lc).
synth_design -top lliu_top_v2 -part ${PART} -flatten_hierarchy none -directive RuntimeOptimized

# Post-synthesis utilization snapshot (before opt/place changes cell counts)
report_utilization -file syn/reports/utilization_synth.txt

# ── Implementation ─────────────────────────────────────────────────────────
opt_design

place_design
# Checkpoint after placement — recoverable if routing is interrupted.
write_checkpoint -force syn/lliu_placed.dcp

# Aggressive physical optimisation pass — targets routing-critical paths
# through the DSP columns and the symbol_filter CAM comparison tree.
phys_opt_design -directive AggressiveExplore
write_checkpoint -force syn/lliu_physopt.dcp

route_design

# Post-route physical optimisation — replicates high-fanout drivers and
# inserts hold buffers on paths that remain marginal after routing.
# Needed to close the fo=24 leading-zero encoder net in feature_extractor Stage 2b.
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation

# ── Save routed checkpoint ─────────────────────────────────────────────────
# Allows bitstream regeneration without re-running P&R.
write_checkpoint -force syn/lliu_routed.dcp

# ── Reports ────────────────────────────────────────────────────────────────
report_utilization   -file syn/reports/utilization.txt
report_timing_summary -file syn/reports/timing.txt -check_timing_verbose

# CDC check — any CRITICAL or HIGH crossing is a hard stop (MAS §6.1).
report_cdc -verbose -file syn/reports/cdc.txt

# ── Bitstream ──────────────────────────────────────────────────────────────
# Board-level pin assignments (constraints.xdc §4) must be appended before
# running this step against physical hardware.
write_bitstream -force syn/lliu.bit
