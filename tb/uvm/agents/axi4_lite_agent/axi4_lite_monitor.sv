// axi4_lite_monitor.sv — AXI4-Lite UVM monitor (passive)
//
// Captures both write and read transactions from the bus.
// Writes: captured when B handshake completes.
// Reads:  captured when R handshake completes.

class axi4_lite_monitor extends uvm_monitor;
    `uvm_component_utils(axi4_lite_monitor)

    virtual axi4_lite_if vif;

    uvm_analysis_port #(axi4_lite_transaction) ap;

    function new(string name = "axi4_lite_monitor", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        ap = new("ap", this);
        if (!uvm_config_db#(virtual axi4_lite_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found for axi4_lite_monitor")
    endfunction

    task run_phase(uvm_phase phase);
        @(negedge vif.rst);

        fork
            monitor_writes();
            monitor_reads();
        join
    endtask

    // Capture write transactions: track AW+W addresses/data, emit on B handshake
    task monitor_writes();
        bit [31:0] wr_addr;
        bit [31:0] wr_data;
        bit [3:0]  wr_strb;
        bit got_aw, got_w;

        forever begin
            got_aw = 0;
            got_w  = 0;

            // Collect AW and W (may arrive in any order or simultaneously)
            while (!got_aw || !got_w) begin
                @(vif.monitor_cb);
                if (!got_aw && vif.monitor_cb.awvalid && vif.monitor_cb.awready) begin
                    wr_addr = {24'b0, vif.monitor_cb.awaddr};
                    got_aw = 1;
                end
                if (!got_w && vif.monitor_cb.wvalid && vif.monitor_cb.wready) begin
                    wr_data = vif.monitor_cb.wdata;
                    wr_strb = vif.monitor_cb.wstrb;
                    got_w = 1;
                end
            end

            // Wait for B handshake
            while (!(vif.monitor_cb.bvalid && vif.monitor_cb.bready))
                @(vif.monitor_cb);

            begin
                axi4_lite_transaction tx = axi4_lite_transaction::type_id::create("wr_tx");
                tx.addr     = wr_addr;
                tx.data     = wr_data;
                tx.wstrb    = wr_strb;
                tx.is_write = 1;
                tx.resp     = vif.monitor_cb.bresp;
                `uvm_info("AXIL_MON", tx.convert2string(), UVM_HIGH)
                ap.write(tx);
            end
        end
    endtask

    // Capture read transactions: AR address, then R data
    task monitor_reads();
        bit [31:0] rd_addr;

        forever begin
            // Wait for AR handshake
            @(vif.monitor_cb);
            while (!(vif.monitor_cb.arvalid && vif.monitor_cb.arready))
                @(vif.monitor_cb);
            rd_addr = {24'b0, vif.monitor_cb.araddr};

            // Wait for R handshake
            while (!(vif.monitor_cb.rvalid && vif.monitor_cb.rready))
                @(vif.monitor_cb);

            begin
                axi4_lite_transaction tx = axi4_lite_transaction::type_id::create("rd_tx");
                tx.addr     = rd_addr;
                tx.is_write = 0;
                tx.rdata    = vif.monitor_cb.rdata;
                tx.resp     = vif.monitor_cb.rresp;
                `uvm_info("AXIL_MON", tx.convert2string(), UVM_HIGH)
                ap.write(tx);
            end
        end
    endtask
endclass
