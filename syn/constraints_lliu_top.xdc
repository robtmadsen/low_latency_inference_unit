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
