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
    [get_cells -hierarchical -filter {NAME =~ *gen_cores\[0\].u_core/*}]
resize_pblock [get_pblocks pblock_core0] -add {CLOCKREGION_X0Y0:CLOCKREGION_X0Y0}

create_pblock pblock_core1
add_cells_to_pblock [get_pblocks pblock_core1] \
    [get_cells -hierarchical -filter {NAME =~ *gen_cores\[1\].u_core/*}]
resize_pblock [get_pblocks pblock_core1] -add {CLOCKREGION_X0Y1:CLOCKREGION_X0Y1}

create_pblock pblock_core2
add_cells_to_pblock [get_pblocks pblock_core2] \
    [get_cells -hierarchical -filter {NAME =~ *gen_cores\[2\].u_core/*}]
resize_pblock [get_pblocks pblock_core2] -add {CLOCKREGION_X0Y2:CLOCKREGION_X0Y2}

create_pblock pblock_core3
add_cells_to_pblock [get_pblocks pblock_core3] \
    [get_cells -hierarchical -filter {NAME =~ *gen_cores\[3\].u_core/*}]
resize_pblock [get_pblocks pblock_core3] -add {CLOCKREGION_X0Y3:CLOCKREGION_X0Y3}

create_pblock pblock_core4
add_cells_to_pblock [get_pblocks pblock_core4] \
    [get_cells -hierarchical -filter {NAME =~ *gen_cores\[4\].u_core/*}]
resize_pblock [get_pblocks pblock_core4] -add {CLOCKREGION_X1Y0:CLOCKREGION_X1Y0}

create_pblock pblock_core5
add_cells_to_pblock [get_pblocks pblock_core5] \
    [get_cells -hierarchical -filter {NAME =~ *gen_cores\[5\].u_core/*}]
resize_pblock [get_pblocks pblock_core5] -add {CLOCKREGION_X1Y1:CLOCKREGION_X1Y1}

# Run 58: pblock_core7 declared before pblock_core6 to avoid the
# "child before parent" Vivado warning (core7 spans X1Y2:X1Y3 which
# contains core6's X1Y2 region).
create_pblock pblock_core7
add_cells_to_pblock [get_pblocks pblock_core7] \
    [get_cells -hierarchical -filter {NAME =~ *gen_cores\[7\].u_core/*}]
# Run 56: expanded from X1Y3 alone — gen_cores[7] cells placed at Y103-Y105
# (CLOCKREGION_X1Y2) in Run 55, indicating pblock overflow into the adjacent
# region.  Expanding to X1Y2:X1Y3 lets Vivado place all core-7 cells
# (including fp32_acc Stage A0.5 + Stage A1 arithmetic) within the region.
resize_pblock [get_pblocks pblock_core7] -add {CLOCKREGION_X1Y2:CLOCKREGION_X1Y3}

create_pblock pblock_core6
add_cells_to_pblock [get_pblocks pblock_core6] \
    [get_cells -hierarchical -filter {NAME =~ *gen_cores\[6\].u_core/*}]
resize_pblock [get_pblocks pblock_core6] -add {CLOCKREGION_X1Y2:CLOCKREGION_X1Y2}

# ─────────────────────────────────────────────────────────────────────────────
# FALSE PATH: ref_mem BRAM port-B write-through to S_PROCESS registers.
#
# order_book ref_mem is inferred as BRAM (Simple Dual-Port, WRITE_FIRST mode).
# The BRAM B-port write clock (CLKBWRCLK) can create combinational
# write-through paths to signals computed from ref_rd_data in S_PROCESS
# (ref_match_r, ref_empty_r, op_ref_price, op_ref_shares, new_sh_r, etc.).
#
# These write-through paths are structurally impossible in operation:
# the FSM guarantees that S_UPDATE (where ref_wr_en=1) and S_PROCESS
# (where ref_rd_data-derived signals are computed) are never concurrent.
# ─────────────────────────────────────────────────────────────────────────────
set_false_path -from [get_pins -hierarchical -filter {NAME =~ *u_ob/ref_mem_reg*/CLKBWRCLK}]

# ─────────────────────────────────────────────────────────────────────────────
# PBLOCK: u_parser + u_sym_filter — collocated to reduce route delay.
#
# Run 32 fix: u_parser/stock_reg[5] drives 64 CAM comparators in u_sym_filter
# with fan-out = 64.  When parser and sym_filter are placed in different clock
# regions, the cross-region route delay on the 64-bit stock bus pushes the
# combinational path (stock_reg → 64-entry compare → OR → lookup_match_q_reg)
# past the 3.200 ns budget (WNS −0.175 ns in Run 31).
# Placing both modules in the same clock region (CLOCKREGION_X2Y0) keeps the
# high-fanout stock nets within a single fabric tile, reducing route delay by
# ~0.2–0.4 ns and eliminating the violation without adding pipeline latency.
# ─────────────────────────────────────────────────────────────────────────────
create_pblock pblock_parser_filter
add_cells_to_pblock [get_pblocks pblock_parser_filter] \
    [get_cells -hierarchical -filter {NAME =~ *u_parser/*}]
add_cells_to_pblock [get_pblocks pblock_parser_filter] \
    [get_cells -hierarchical -filter {NAME =~ *u_sym_filter/*}]
resize_pblock [get_pblocks pblock_parser_filter] -add {CLOCKREGION_X2Y0:CLOCKREGION_X2Y0}

# NOTE: pblock_ob (order_book) was attempted in Run 56 with CLOCKREGION_X2Y1:X2Y2
# but that range is invalid on xc7k160tffg676-2 (column X2 has only row Y0).
# The order_book path is fixed by RTL in Run 57 (book_entry_r intermediate register).

