// axi4_stream_monitor.sv — AXI4-Stream UVM monitor (passive)
//
// Samples tdata on every valid handshake (tvalid & tready).
// Accumulates beats until tlast, then writes complete transaction to analysis port.

class axi4_stream_monitor extends uvm_monitor;
    `uvm_component_utils(axi4_stream_monitor)

    virtual axi4_stream_if vif;

    uvm_analysis_port #(axi4_stream_transaction) ap;

    function new(string name = "axi4_stream_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db#(virtual axi4_stream_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found for axi4_stream_monitor")
    endfunction

    task run_phase(uvm_phase phase);
        // Wait for reset deassertion (Verilator-safe: poll on monitor_cb ticks)
        do @(vif.monitor_cb); while (vif.rst);

        forever begin
            collect_transaction();
        end
    endtask

    task collect_transaction();
        axi4_stream_transaction tx;
        bit [63:0] beats[$];

        // Accumulate beats until tlast
        forever begin
            @(vif.monitor_cb);
            if (vif.monitor_cb.tvalid && vif.monitor_cb.tready) begin
                beats.push_back(vif.monitor_cb.tdata);
                if (vif.monitor_cb.tlast) break;
            end
        end

        // Build transaction
        tx = axi4_stream_transaction::type_id::create("tx");
        tx.tdata = new[beats.size()];
        foreach (beats[i])
            tx.tdata[i] = beats[i];

        `uvm_info("AXIS_MON", tx.convert2string(), UVM_HIGH)
        ap.write(tx);
    endtask
endclass
