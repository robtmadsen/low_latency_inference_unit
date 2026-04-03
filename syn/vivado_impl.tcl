# syn/vivado_impl.tcl
# -------------------
# Vivado ML Standard — synthesis, place-and-route, and bitstream generation
# for LLIU targeting xc7k160tffg676-2.
#
# Synthesis target: lliu_top (LLIU inference core, AXI4-S + AXI4-Lite ports).
# kc705_top (board wrapper with Ethernet MAC/PHY) is excluded — it requires
# Xilinx I/O primitives and MMCM instantiation that are board-specific and
# cause constant-propagation sweeps of the core logic during synthesis.
#
# Usage (run from repository root):
#   vivado -mode batch -source syn/vivado_impl.tcl
#   Example:
#     vivado -mode batch -source syn/vivado_impl.tcl \
#            2>&1 | tee syn/reports/vivado.log

set PART xc7k160tffg676-2

# ── Read sources ───────────────────────────────────────────────────────────
# Package first — defines types used by all LLIU modules.
read_verilog -sv rtl/lliu_pkg.sv

# LLIU inference core — all submodules + top
read_verilog -sv {
  rtl/bfloat16_mul.sv
  rtl/fp32_acc.sv
  rtl/dot_product_engine.sv
  rtl/itch_parser.sv
  rtl/itch_field_extract.sv
  rtl/feature_extractor.sv
  rtl/weight_mem.sv
  rtl/axi4_lite_slave.sv
  rtl/output_buffer.sv
  rtl/moldupp64_strip.sv
  rtl/symbol_filter.sv
  rtl/lliu_top.sv
}

# ── Constraints ────────────────────────────────────────────────────────────
# Use the lliu_top-specific constraints file (300 MHz clock, false-path I/Os).
# constraints.xdc targets kc705_top hierarchy and is kept for reference only.
read_xdc syn/constraints_lliu_top.xdc

# ── Synthesis ──────────────────────────────────────────────────────────────
# -flatten_hierarchy full: flatten for P&R; hierarchy preserved in reports.
# DSP48E1 and carry-chain inference left on (no -no_dsp / -no_lc).
synth_design -top lliu_top -part ${PART} -flatten_hierarchy full

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

# ── Save routed checkpoint ─────────────────────────────────────────────────
# Allows bitstream regeneration without re-running P&R.
write_checkpoint -force syn/lliu_routed.dcp

# ── Reports ────────────────────────────────────────────────────────────────
report_utilization   -file syn/reports/utilization.txt
report_timing_summary -file syn/reports/timing.txt -check_timing_verbose

# ── Bitstream ──────────────────────────────────────────────────────────────
# Pin assignments in syn/constraints.xdc section 4 must match the target
# board schematic before this step is run.
write_bitstream -force syn/lliu.bit
