# syn/vivado_synth.tcl
# --------------------
# Vivado ML Standard — synthesis only for LLIU v2.0 targeting xc7k160tffg676-2.
#
# Writes syn/lliu_synth.dcp which vivado_par.tcl picks up for P&R.
# Run from repository root:
#   vivado -mode batch -source syn/vivado_synth.tcl \
#          2>&1 | tee syn/reports/vivado_synth.log

set PART xc7k160tffg676-2

# ── Read sources ───────────────────────────────────────────────────────────
read_verilog -sv rtl/lliu_pkg.sv

# order_book.sv is excluded — synthesized OOC via vivado_ooc_orderbook.tcl.
# Read a black-box stub so Vivado can elaborate the hierarchy.
# The real netlist is imported after synth_design via read_checkpoint -cell.
read_verilog -sv syn/order_book_stub.sv

read_verilog -sv {
  rtl/bfloat16_mul.sv
  rtl/fp32_acc.sv
  rtl/dot_product_engine.sv
  rtl/weight_mem.sv
  rtl/output_buffer.sv
  rtl/lliu_core.sv
  rtl/itch_parser_v2.sv
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
read_xdc syn/constraints_lliu_top.xdc

# ── Synthesis ──────────────────────────────────────────────────────────────
# Thread policy: 4 threads reduces memory contention on BRAM-heavy designs.
# Override with VIVADO_SYNTH_THREADS if needed for profiling.
set synth_threads 4
if {[info exists ::env(VIVADO_SYNTH_THREADS)] && [string is integer -strict $::env(VIVADO_SYNTH_THREADS)] && $::env(VIVADO_SYNTH_THREADS) > 0} {
  set synth_threads $::env(VIVADO_SYNTH_THREADS)
}
set_param general.maxThreads $synth_threads
puts "INFO: VIVADO_SYNTH_THREADS=$synth_threads"

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

# -flatten_hierarchy full: fastest option — no hierarchy reconstruction pass.
# Per-module resource counts come from the OOC checkpoints instead.
# order_book is excluded from sources, so Vivado creates a black box for u_ob.
synth_design -top lliu_top_v2 -part ${PART} \
  -flatten_hierarchy full \
  -directive RuntimeOptimized

# ── Import OOC order_book netlist ──────────────────────────────────────────
# Populates the u_ob black box with the pre-synthesized order_book netlist.
read_checkpoint -cell [get_cells u_ob] syn/order_book_ooc.dcp

# ── Post-synthesis reports ─────────────────────────────────────────────────
report_utilization -file syn/reports/utilization_synth.txt

# ── Save synthesis checkpoint ──────────────────────────────────────────────
# P&R script opens this checkpoint — no need to re-read RTL or XDC.
write_checkpoint -force syn/lliu_synth.dcp

puts "INFO: Synthesis complete. Checkpoint written to syn/lliu_synth.dcp"
