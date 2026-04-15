// risk_check_if.sv — SystemVerilog interface for risk_check standalone DUT
//
// DUT target: risk_check (TOPLEVEL=risk_check — block-level standalone test)
// Spec ref:   .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.6
//
// Wraps the full risk_check port list:
//
// Inputs (driven by risk_check_driver):
//   score_valid           — 1-cycle pulse: proposed order from strategy_arbiter
//   proposed_price[31:0]  — ITCH price field (10^-4 dollars)
//   proposed_shares[23:0] — order quantity
//   sym_id[8:0]           — symbol index (0–499, 500-entry universe)
//   bbo_mid[31:0]         — BBO mid price from order_book: (bid + ask) / 2
//   band_bps[15:0]        — price-band width in basis points (AXI4-Lite config)
//   max_qty[23:0]         — fat-finger max quantity (AXI4-Lite config)
//   kill_sw_force         — manual kill switch set (CTRL register bit[2])
//   tx_overflow           — TX backpressure kill trigger (from ouch_engine)
//
// Outputs (sampled by risk_check_monitor, 2 cycles after score_valid):
//   risk_pass             — 1-cycle pulse: order cleared all checks
//   risk_blocked          — 1-cycle pulse: order blocked by ≥ 1 check
//   kill_sw_active        — current kill-switch state (combinational gate)
//   violation_count_price[31:0] — price-band violation counter (AXI4-Lite readable)
//   violation_count_qty[31:0]   — fat-finger violation counter
//   violation_count_pos[31:0]   — position-limit violation counter

`timescale 1ns/1ps

interface risk_check_if (
    input logic clk,
    input logic rst
);

    // ── Input bus ─────────────────────────────────────────────────
    logic        score_valid;
    logic [31:0] proposed_price;
    logic [23:0] proposed_shares;
    logic [8:0]  sym_id;
    logic [31:0] bbo_mid;
    logic [15:0] band_bps;
    logic [23:0] max_qty;
    logic        kill_sw_force;
    logic        tx_overflow;

    // ── Output bus ────────────────────────────────────────────────
    logic        risk_pass;
    logic        risk_blocked;
    logic        kill_sw_active;
    logic [31:0] violation_count_price;
    logic [31:0] violation_count_qty;
    logic [31:0] violation_count_pos;

    // ── Driver clocking block (test → DUT) ───────────────────────
    clocking driver_cb @(posedge clk);
        default input #1step output #0;
        output score_valid;
        output proposed_price;
        output proposed_shares;
        output sym_id;
        output bbo_mid;
        output band_bps;
        output max_qty;
        output kill_sw_force;
        output tx_overflow;
    endclocking

    // ── Monitor clocking block (DUT → test) ──────────────────────
    clocking monitor_cb @(posedge clk);
        default input #1step;
        // Outputs to sample
        input risk_pass;
        input risk_blocked;
        input kill_sw_active;
        input violation_count_price;
        input violation_count_qty;
        input violation_count_pos;
        // Snapshot inputs for logging (read back from DUT input bus)
        input score_valid;
        input proposed_price;
        input proposed_shares;
        input sym_id;
        input bbo_mid;
    endclocking

endinterface
