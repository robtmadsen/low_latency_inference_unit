# syn/vivado_par.tcl
# ------------------
# Vivado ML Standard — place-and-route and bitstream for LLIU v2.0.
#
# Requires syn/lliu_synth.dcp produced by vivado_synth.tcl.
# Run from repository root:
#   vivado -mode batch -source syn/vivado_par.tcl \
#          2>&1 | tee syn/reports/vivado_par.log
#
# Directive ladder (fastest → highest quality):
#   opt_design:   RuntimeOptimized → Explore → ExploreWithRemap
#   place_design: RuntimeOptimized → AltSpreadLogic → SpreadLogic
#   phys_opt:     AggressiveExplore (keep — needed for DSP column timing)
#   route_design: default → NoTimingRelaxation (only on second pass)
#
# Start with RuntimeOptimized for opt+place to get timing numbers quickly.
# If WNS < 0 after first pass, escalate directives before re-running.

# ── Open synthesis checkpoint ──────────────────────────────────────────────
# Constraints are embedded in the DCP — no read_xdc needed.
open_checkpoint syn/lliu_synth.dcp

# ── Implementation settings ────────────────────────────────────────────────
# Keep thread cap consistent with synthesis run.
set_param general.maxThreads 4

set ::env(XILINX_LOCALAPPDATA) /dev/shm

# ── Implementation ─────────────────────────────────────────────────────────
# RuntimeOptimized skips the cross-boundary/area sweep that caused an 8+ hour
# hang in the combined vivado_impl.tcl run. Escalate to Explore only if WNS
# after first pass is worse than −0.3 ns.
opt_design -directive RuntimeOptimized
write_checkpoint -force syn/lliu_opted.dcp

# RuntimeOptimized placer is 2–3× faster than the default for this design size.
# If placement quality is insufficient (WNS < −0.5 ns), try AltSpreadLogic.
place_design -directive RuntimeOptimized
# Checkpoint after placement — recoverable if routing is interrupted.
write_checkpoint -force syn/lliu_placed.dcp

# Physical optimisation — targets routing-critical paths through the DSP
# columns and the symbol_filter CAM comparison tree (MAS §2.2).
phys_opt_design -directive AggressiveExplore
write_checkpoint -force syn/lliu_physopt.dcp

# First routing pass without NoTimingRelaxation to avoid runaway hold-fix
# iterations; add -directive NoTimingRelaxation only if WNS is marginal.
route_design

# Post-route physical optimisation — replicates high-fanout drivers and
# inserts hold buffers on paths marginal after routing.
phys_opt_design -directive AggressiveExplore
route_design -directive NoTimingRelaxation

# ── Save routed checkpoint ─────────────────────────────────────────────────
write_checkpoint -force syn/lliu_routed.dcp

# ── Reports ────────────────────────────────────────────────────────────────
report_utilization    -file syn/reports/utilization.txt
report_timing_summary -file syn/reports/timing.txt -check_timing_verbose

# CDC check — any CRITICAL or HIGH crossing is a hard stop (MAS §6.1).
report_cdc -verbose   -file syn/reports/cdc.txt

# ── Bitstream ──────────────────────────────────────────────────────────────
write_bitstream -force syn/lliu.bit

puts "INFO: P&R complete. Routed checkpoint: syn/lliu_routed.dcp  Bitstream: syn/lliu.bit"
