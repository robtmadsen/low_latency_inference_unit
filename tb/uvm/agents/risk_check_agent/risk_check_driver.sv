// risk_check_driver.sv — UVM driver for risk_check standalone DUT
//
// Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.6
//
// For each sequence item:
//   1. Apply config registers (band_bps, max_qty, bbo_mid, kill_sw_force,
//      tx_overflow) one cycle before the score_valid pulse.
//   2. Pulse score_valid for exactly one clock cycle.
//   3. Hold score_valid low; wait 2 cycles for the DUT pipeline to settle
//      (MAS §4.6: risk_check pipeline = 2 cycles).
//   4. Release item_done so the monitor can capture the output.
//
// Virtual interface key: "rc_vif"

class risk_check_driver extends uvm_driver #(risk_check_seq_item);
    `uvm_component_utils(risk_check_driver)

    virtual risk_check_if vif;

    function new(string name = "risk_check_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db #(virtual risk_check_if)::get(
                this, "", "rc_vif", vif))
            `uvm_fatal("NOVIF",
                "risk_check_driver: risk_check_if not found in UVM config DB (key: rc_vif)")
    endfunction

    task run_phase(uvm_phase phase);
        risk_check_seq_item req;

        // Drive DUT inputs to idle before reset deasserts
        vif.driver_cb.score_valid      <= 1'b0;
        vif.driver_cb.proposed_price   <= 32'h0;
        vif.driver_cb.proposed_shares  <= 24'h0;
        vif.driver_cb.sym_id           <= 9'h0;
        vif.driver_cb.bbo_mid          <= 32'h0;
        vif.driver_cb.band_bps         <= 16'd10;
        vif.driver_cb.max_qty          <= 24'd1000;
        vif.driver_cb.kill_sw_force    <= 1'b0;
        vif.driver_cb.tx_overflow      <= 1'b0;

        // Wait for reset deassertion
        do @(vif.driver_cb); while (vif.rst);
        repeat (2) @(vif.driver_cb);

        forever begin
            seq_item_port.get_next_item(req);
            drive_item(req);
            seq_item_port.item_done();
        end
    endtask

    // ── drive_item ────────────────────────────────────────────────
    // Applies config and fires a one-cycle score_valid pulse.
    // Waits the 2-cycle pipeline before returning so the monitor
    // samples valid output.
    task drive_item(risk_check_seq_item req);
        // Cycle N-1: load config registers and data fields
        @(vif.driver_cb);
        vif.driver_cb.band_bps        <= req.band_bps;
        vif.driver_cb.max_qty         <= req.max_qty;
        vif.driver_cb.bbo_mid         <= req.bbo_mid;
        vif.driver_cb.kill_sw_force   <= req.kill_sw_force;
        vif.driver_cb.tx_overflow     <= req.tx_overflow;
        vif.driver_cb.proposed_price  <= req.proposed_price;
        vif.driver_cb.proposed_shares <= req.proposed_shares;
        vif.driver_cb.sym_id          <= req.sym_id;

        // Cycle N: assert score_valid for one cycle
        @(vif.driver_cb);
        vif.driver_cb.score_valid <= 1'b1;

        // Cycle N+1: deassert; DUT latches on the rising edge of N
        @(vif.driver_cb);
        vif.driver_cb.score_valid <= 1'b0;

        // Cycles N+2, N+3: pipeline drain (2-cycle DUT latency per MAS §4.6)
        repeat (2) @(vif.driver_cb);

        // De-assert kill-switch triggers between transactions
        vif.driver_cb.kill_sw_force <= 1'b0;
        vif.driver_cb.tx_overflow   <= 1'b0;
    endtask

endclass
