# syn/vivado_impl.tcl
# -------------------
# Vivado ML Standard — synthesis, place-and-route, and bitstream generation
# for LLIU targeting xc7k160tffg676-2.
#
# Usage (run from repository root):
#   vivado -mode batch -source syn/vivado_impl.tcl \
#          -tclargs <VERILOG_ETHERNET_DIR>
#   Example:
#     vivado -mode batch -source syn/vivado_impl.tcl \
#            -tclargs ./lib/verilog-ethernet \
#            2>&1 | tee syn/reports/vivado.log

set VERILOG_ETHERNET_DIR [lindex $argv 0]
set PART xc7k160tffg676-2

# ── Read sources ───────────────────────────────────────────────────────────
# Package first — defines types used by all LLIU modules.
read_verilog -sv rtl/lliu_pkg.sv

# LLIU compute core and top-level
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
  rtl/eth_axis_rx_wrap.sv
  rtl/kc705_top.sv
}

# Forencich verilog-ethernet network stack (all .v files)
read_verilog [glob ${VERILOG_ETHERNET_DIR}/rtl/*.v]

# ── Constraints ────────────────────────────────────────────────────────────
# Clock definitions, CDC false_paths, DSP/BRAM Pblocks, I/O pin assignments.
# Update section 4 (I/O pin assignments) for the actual target board before
# generating a bitstream.
read_xdc syn/constraints.xdc

# ── Synthesis ──────────────────────────────────────────────────────────────
# -flatten_hierarchy full: flatten for P&R; hierarchy preserved in reports.
# DSP48E1 and carry-chain inference left on (no -no_dsp / -no_lc).
synth_design -top kc705_top -part ${PART} -flatten_hierarchy full

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
