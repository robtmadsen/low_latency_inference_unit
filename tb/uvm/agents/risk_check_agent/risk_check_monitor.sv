// risk_check_monitor.sv — UVM monitor for risk_check standalone DUT
//
// Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.6
//
// Watches the risk_check_if monitor_cb for a score_valid pulse, then
// waits exactly 2 cycles (MAS §4.6 pipeline latency) and captures:
//   risk_pass, risk_blocked, kill_sw_active, violation_count_*
//
// Broadcasts one risk_check_seq_item per transaction on the analysis port.
// The seq_item contains both the observed input snapshot and the DUT response.
//
// Virtual interface key: "rc_vif"

class risk_check_monitor extends uvm_monitor;
    `uvm_component_utils(risk_check_monitor)

    virtual risk_check_if vif;

    uvm_analysis_port #(risk_check_seq_item) ap;

    function new(string name = "risk_check_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db #(virtual risk_check_if)::get(
                this, "", "rc_vif", vif))
            `uvm_fatal("NOVIF",
                "risk_check_monitor: risk_check_if not found in UVM config DB (key: rc_vif)")
    endfunction

    task run_phase(uvm_phase phase);
        // Wait for reset deassertion
        do @(vif.monitor_cb); while (vif.rst);

        forever begin
            @(vif.monitor_cb);

            if (vif.monitor_cb.score_valid) begin
                risk_check_seq_item tx;

                // Snapshot input fields on the cycle score_valid is observed
                tx = risk_check_seq_item::type_id::create("tx");
                tx.proposed_price  = vif.monitor_cb.proposed_price;
                tx.proposed_shares = vif.monitor_cb.proposed_shares;
                tx.sym_id          = vif.monitor_cb.sym_id;
                tx.bbo_mid         = vif.monitor_cb.bbo_mid;

                // Wait for the 2-cycle DUT pipeline (MAS §4.6)
                repeat (2) @(vif.monitor_cb);

                // Capture DUT outputs
                tx.risk_pass             = vif.monitor_cb.risk_pass;
                tx.risk_blocked          = vif.monitor_cb.risk_blocked;
                tx.kill_sw_active        = vif.monitor_cb.kill_sw_active;
                tx.violation_count_price = vif.monitor_cb.violation_count_price;
                tx.violation_count_qty   = vif.monitor_cb.violation_count_qty;
                tx.violation_count_pos   = vif.monitor_cb.violation_count_pos;

                `uvm_info("RC_MON", tx.convert2string(), UVM_MEDIUM)
                ap.write(tx);
            end
        end
    endtask

endclass
