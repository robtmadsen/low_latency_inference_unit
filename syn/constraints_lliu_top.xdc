# syn/constraints_lliu_top.xdc
# ─────────────────────────────────────────────────────────────────────────────
# Timing constraints for lliu_top synthesis/P&R on xc7k160tffg676-2.
#
# Clock target:  300 MHz (3.333 ns period) — matches SPEC.md performance target.
# I/O delays:    Conservative 0.5 ns input / 0.5 ns output (placeholder).
#
# Pin LOC / IOSTANDARD assignments are omitted intentionally.
# A board-specific XDC must be appended before write_bitstream is called.
# ─────────────────────────────────────────────────────────────────────────────

# Primary clock — lliu_top uses a single-ended 'clk' input (not LVDS diff pair)
create_clock -name sys_clk -period 3.333 [get_ports clk]

# I/O timing — placeholder false paths for all non-clock inputs/outputs so that
# Vivado does not report unconstrained I/O as timing violations during resource-
# estimation runs without board pin assignments.
set_false_path -from [get_ports {rst s_axis_* s_axil_*}]
set_false_path -to   [get_ports {dp_result dp_result_valid s_axis_tready s_axil_*}]

# ─────────────────────────────────────────────────────────────────────────────
# PBLOCK: compact fp32_acc placement to reduce inter-stage routing delay
#
# Run 4 critical path (WNS -2.307 ns): fp32_acc Stage A1 → Stage B
#   Source: aligned_small_r_reg[8]  SLICE_X9Y125
#   Dest:   partial_sum_r_reg[19]   SLICE_X6Y130
#   Route delay: 4.229 ns (74 % of total) — two high-fanout signals
#   (sum_man_b1 fo=27, sel0[6] fo=41) spread across X6-X13 Y118-Y134.
#
# Constrain all fp32_acc cells to SLICE_X0Y100:SLICE_X17Y149 (a compact
# 18×50 region).  The observed footprint is only X6-X13 Y118-Y134; this
# region gives ~2× headroom so Vivado can satisfy all legal placements
# while keeping fanout routing short.
# ─────────────────────────────────────────────────────────────────────────────
create_pblock pblock_fp32acc
add_cells_to_pblock [get_pblocks pblock_fp32acc] \
    [get_cells -hierarchical -filter {NAME =~ u_dp_engine/u_acc/*}]
resize_pblock [get_pblocks pblock_fp32acc] \
    -add {SLICE_X0Y100:SLICE_X17Y149}
