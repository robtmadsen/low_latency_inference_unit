// risk_check_seq_item.sv — UVM sequence item for risk_check agent
//
// Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.6
//
// Carries one proposed-order stimulus (input) and the risk_check response
// (output, populated by monitor after the 2-cycle DUT pipeline).

class risk_check_seq_item extends uvm_sequence_item;
    `uvm_object_utils(risk_check_seq_item)

    // ── Stimulus fields (driver writes) ───────────────────────────
    rand logic [31:0] proposed_price;    // ITCH price × 10^-4 dollars
    rand logic [23:0] proposed_shares;   // order quantity
    rand logic [8:0]  sym_id;            // symbol index 0–499
    rand logic [31:0] bbo_mid;           // BBO mid from order_book
    rand logic [15:0] band_bps;          // price-band width (basis points)
    rand logic [23:0] max_qty;           // fat-finger limit
    rand logic        kill_sw_force;     // manual kill (CTRL bit[2])
    rand logic        tx_overflow;       // TX backpressure kill trigger

    // ── Response fields (monitor populates) ───────────────────────
    logic        risk_pass;
    logic        risk_blocked;
    logic        kill_sw_active;
    logic [31:0] violation_count_price;
    logic [31:0] violation_count_qty;
    logic [31:0] violation_count_pos;

    // ── Default constraints ───────────────────────────────────────
    // bbo_mid: $10.00–$999.99 (units: 10^-4 dollars, so ×10000)
    constraint c_bbo_mid_range { bbo_mid inside {[100_000 : 9_999_900]}; }
    // Default band: 10 bp = ±0.10% (tight, realistic)
    constraint c_band_bps      { band_bps == 16'd10; }
    // Default fat-finger limit: 1,000 shares
    constraint c_max_qty       { max_qty == 24'd1000; }
    // Kill-switch and overflow off by default; override in specific sequences
    constraint c_kill_sw_off   { kill_sw_force == 1'b0; tx_overflow == 1'b0; }
    // symbol index within the 500-entry universe
    constraint c_sym_id_range  { sym_id < 9'd500; }
    // price and shares can be anything (zero catches protocol edge cases)
    constraint c_price_nz      { proposed_price  > 32'h0; }
    constraint c_shares_nz     { proposed_shares > 24'h0; }

    function new(string name = "risk_check_seq_item");
        super.new(name);
    endfunction

    function string convert2string();
        return $sformatf(
            "RC_ITEM: price=%0d shares=%0d sym=%0d bbo_mid=%0d band=%0d max_qty=%0d kill_sw=%0b tx_ovf=%0b | pass=%0b blocked=%0b kill_active=%0b",
            proposed_price, proposed_shares, sym_id, bbo_mid,
            band_bps, max_qty, kill_sw_force, tx_overflow,
            risk_pass, risk_blocked, kill_sw_active);
    endfunction

endclass
