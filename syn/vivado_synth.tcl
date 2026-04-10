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
read_xdc syn/constraints_lliu_top.xdc

# ── Synthesis ──────────────────────────────────────────────────────────────
# Cap threads to 4 to keep peak memory within the 32 GB instance limit.
set_param general.maxThreads 4

# Redirect .Xil temp files to /dev/shm to prevent root disk exhaustion.
set ::env(XILINX_LOCALAPPDATA) /dev/shm

# -flatten_hierarchy rebuilt: synthesizes flat internally (fast, no cross-boundary
# sweep), then reconstructs module hierarchy in utilization reports.
# This is strictly faster than -flatten_hierarchy none at this design size
# because "none" triggers an expensive cross-boundary analysis pass that
# has caused multi-hour hangs. "rebuilt" preserves per-module resource counts.
# -no_srlopt: disables shift-register extraction, a secondary slow step on
# designs with large BRAM arrays (order_book). Safe to disable — SRL inference
# is not needed; all delay lines are explicit always_ff.
synth_design -top lliu_top_v2 -part ${PART} \
  -flatten_hierarchy rebuilt \
  -directive RuntimeOptimized \
  -no_srlopt

# ── Post-synthesis reports ─────────────────────────────────────────────────
report_utilization -file syn/reports/utilization_synth.txt

# ── Save synthesis checkpoint ──────────────────────────────────────────────
# P&R script opens this checkpoint — no need to re-read RTL or XDC.
write_checkpoint -force syn/lliu_synth.dcp

puts "INFO: Synthesis complete. Checkpoint written to syn/lliu_synth.dcp"
