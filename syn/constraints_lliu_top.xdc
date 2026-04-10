# syn/constraints_lliu_top.xdc
# ─────────────────────────────────────────────────────────────────────────────
# Timing constraints for lliu_top_v2 synthesis/P&R on xc7k160tffg676-2.
#
# Clock target:  312.5 MHz (3.200 ns period) — MAS §6 (v2.0).
# I/O delays:    False-path on all AXI I/O (no board pin assignments yet).
#
# Pin LOC / IOSTANDARD assignments are omitted intentionally.
# A board-specific XDC must be appended before write_bitstream is called.
# ─────────────────────────────────────────────────────────────────────────────

# Primary clock — lliu_top_v2 uses a single-ended 'clk' input
create_clock -name sys_clk -period 3.200 [get_ports clk]

# I/O timing — false paths for all non-clock I/O so Vivado does not flag
# unconstrained ports during resource-estimation runs without pin assignments.
# v2 new ports: m_axis_* (OUCH output), m_axis_tready (OUCH backpressure),
#               collision_count_out[31:0], tx_overflow_out.
set_false_path -from [get_ports {rst s_axis_* m_axis_tready s_axil_*}]
set_false_path -to   [get_ports {m_axis_tdata* m_axis_tkeep* m_axis_tvalid \
                                  m_axis_tlast s_axis_tready s_axil_* \
                                  collision_count_out* tx_overflow_out}]

# ─────────────────────────────────────────────────────────────────────────────
# PBLOCK: 8× lliu_core — one clock region per core (MAS §2.2)
#
# Strategy: 2-column × 4-row grid using the two left-most clock-region
# columns.  Each core occupies one full clock region so its DSP48E1 MAC
# array, associated LUTs, and FFs share the same routing fabric.
#
# Layout (left column = cores 0–3, right column = cores 4–7):
#   CLOCKREGION_X0Y3  CLOCKREGION_X1Y3   ← top
#   CLOCKREGION_X0Y2  CLOCKREGION_X1Y2
#   CLOCKREGION_X0Y1  CLOCKREGION_X1Y1
#   CLOCKREGION_X0Y0  CLOCKREGION_X1Y0   ← bottom
#
# order_book BRAMs: unconstrained for Run 1 — Vivado will place them in
# columns adjacent to the inference Pblocks; refine after first P&R.
# ptp_core, risk_check, ouch_engine: unconstrained for Run 1.
#
# NOTE: After Run 1 inspect syn/reports/utilization.txt and the placement
# viewer to verify that no core exceeds its clock region boundary.  If
# Vivado reports Pblock overflow, widen the region to the next adjacent
# clock region before Run 2.
# ─────────────────────────────────────────────────────────────────────────────

create_pblock pblock_core0
add_cells_to_pblock [get_pblocks pblock_core0] \
    [get_cells -hierarchical -filter {NAME =~ gen_cores[0].u_core/*}]
resize_pblock [get_pblocks pblock_core0] -add {CLOCKREGION_X0Y0:CLOCKREGION_X0Y0}

create_pblock pblock_core1
add_cells_to_pblock [get_pblocks pblock_core1] \
    [get_cells -hierarchical -filter {NAME =~ gen_cores[1].u_core/*}]
resize_pblock [get_pblocks pblock_core1] -add {CLOCKREGION_X0Y1:CLOCKREGION_X0Y1}

create_pblock pblock_core2
add_cells_to_pblock [get_pblocks pblock_core2] \
    [get_cells -hierarchical -filter {NAME =~ gen_cores[2].u_core/*}]
resize_pblock [get_pblocks pblock_core2] -add {CLOCKREGION_X0Y2:CLOCKREGION_X0Y2}

create_pblock pblock_core3
add_cells_to_pblock [get_pblocks pblock_core3] \
    [get_cells -hierarchical -filter {NAME =~ gen_cores[3].u_core/*}]
resize_pblock [get_pblocks pblock_core3] -add {CLOCKREGION_X0Y3:CLOCKREGION_X0Y3}

create_pblock pblock_core4
add_cells_to_pblock [get_pblocks pblock_core4] \
    [get_cells -hierarchical -filter {NAME =~ gen_cores[4].u_core/*}]
resize_pblock [get_pblocks pblock_core4] -add {CLOCKREGION_X1Y0:CLOCKREGION_X1Y0}

create_pblock pblock_core5
add_cells_to_pblock [get_pblocks pblock_core5] \
    [get_cells -hierarchical -filter {NAME =~ gen_cores[5].u_core/*}]
resize_pblock [get_pblocks pblock_core5] -add {CLOCKREGION_X1Y1:CLOCKREGION_X1Y1}

create_pblock pblock_core6
add_cells_to_pblock [get_pblocks pblock_core6] \
    [get_cells -hierarchical -filter {NAME =~ gen_cores[6].u_core/*}]
resize_pblock [get_pblocks pblock_core6] -add {CLOCKREGION_X1Y2:CLOCKREGION_X1Y2}

create_pblock pblock_core7
add_cells_to_pblock [get_pblocks pblock_core7] \
    [get_cells -hierarchical -filter {NAME =~ gen_cores[7].u_core/*}]
resize_pblock [get_pblocks pblock_core7] -add {CLOCKREGION_X1Y3:CLOCKREGION_X1Y3}
