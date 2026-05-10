# syn/vivado_ooc_orderbook.tcl
# -----------------------------
# Out-of-context synthesis of order_book for LLIU v2.0.
#
# The 32K×128b ref_mem BRAM array (128× RAMB36) causes multi-hour
# Technology Mapping stalls when synthesized inline.  Synthesizing it
# OOC isolates the BRAM mapping work and lets the top-level synth
# import a pre-built netlist via read_checkpoint -cell.
#
# Usage (run from repository root on EC2):
#   /opt/Xilinx/2025.2/Vivado/bin/vivado -mode batch \
#       -source syn/vivado_ooc_orderbook.tcl \
#       2>&1 | tee syn/reports/vivado_ooc_orderbook.log

set PART xc7k160tffg676-2

# ── Read sources ───────────────────────────────────────────────────────────
# Package first — order_book imports OB_NUM_SYMBOLS, OB_LEVELS,
# OB_REF_TABLE_BITS, and message-type constants from lliu_pkg.
read_verilog -sv rtl/lliu_pkg.sv
read_verilog -sv rtl/order_book.sv

# ── Clock constraint for OOC ──────────────────────────────────────────────
# Must match the top-level clock period (3.200 ns = 312.5 MHz).
# read_xdc is required in non-project mode (create_clock can't be called
# before elaboration).
read_xdc syn/constraints_ooc_orderbook.xdc

# ── OOC synthesis ─────────────────────────────────────────────────────────
# Thread count: 4 threads is sufficient for a single-module OOC run.
set synth_threads 4
if {[info exists ::env(VIVADO_SYNTH_THREADS)] && [string is integer -strict $::env(VIVADO_SYNTH_THREADS)] && $::env(VIVADO_SYNTH_THREADS) > 0} {
  set synth_threads $::env(VIVADO_SYNTH_THREADS)
}
set_param general.maxThreads $synth_threads
puts "INFO: OOC synth threads=$synth_threads"

synth_design -top order_book -part ${PART} \
  -mode out_of_context \
  -flatten_hierarchy full \
  -directive RuntimeOptimized

# ── Reports ───────────────────────────────────────────────────────────────
file mkdir syn/reports
report_utilization -file syn/reports/utilization_ooc_orderbook.txt

# ── Checkpoint ────────────────────────────────────────────────────────────
write_checkpoint -force syn/order_book_ooc.dcp
puts "INFO: OOC order_book synthesis complete → syn/order_book_ooc.dcp"
