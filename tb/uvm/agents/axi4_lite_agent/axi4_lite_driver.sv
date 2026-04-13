// axi4_lite_driver.sv — AXI4-Lite UVM driver
//
// Drives write and read transactions onto the AXI4-Lite bus.
// Write: AW + W simultaneously, then wait for B response.
// Read:  AR, then wait for R response.

class axi4_lite_driver extends uvm_driver #(axi4_lite_transaction);
    `uvm_component_utils(axi4_lite_driver)

    virtual axi4_lite_if vif;

    function new(string name = "axi4_lite_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual axi4_lite_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found for axi4_lite_driver")
    endfunction

    task run_phase(uvm_phase phase);
        axi4_lite_transaction tx;

        // Initialize bus to idle
        reset_bus();

        // Wait for reset deassertion (poll on clock edges — Verilator-safe)
        do @(vif.driver_cb); while (vif.rst);
        `uvm_info("AXIL_DRV", "Reset deasserted — entering driver loop", UVM_LOW)
        @(vif.driver_cb);  // one extra cycle for clocking-block output settling

        forever begin
            seq_item_port.get_next_item(tx);
            if (tx.is_write)
                drive_write(tx);
            else
                drive_read(tx);
            seq_item_port.item_done();
        end
    endtask

    task reset_bus();
        vif.driver_cb.awaddr  <= '0;
        vif.driver_cb.awvalid <= 1'b0;
        vif.driver_cb.wdata   <= '0;
        vif.driver_cb.wstrb   <= '0;
        vif.driver_cb.wvalid  <= 1'b0;
        vif.driver_cb.bready  <= 1'b0;
        vif.driver_cb.araddr  <= '0;
        vif.driver_cb.arvalid <= 1'b0;
        vif.driver_cb.rready  <= 1'b0;
    endtask

    // Drive AW + W simultaneously, wait for both handshakes, then collect B
    //
    // Note on output #0 clocking-block timing (same issue as drive_read):
    // get_next_item() may resume on a stale posedge trigger. The first
    // @(driver_cb) after driving awvalid/wvalid fires immediately with
    // isTriggered()=false, so the CB outputs have NOT propagated to the wire
    // yet and the DUT sees awvalid=0 at that posedge. Using repeat(2) ensures
    // the signals are stable on the wire before the handshake check loop
    // samples awready/wready.
    task drive_write(axi4_lite_transaction tx);
        bit aw_done, w_done;

        // Present AW and W channels simultaneously
        vif.driver_cb.awaddr  <= tx.addr;
        vif.driver_cb.awvalid <= 1'b1;
        vif.driver_cb.wdata   <= tx.data;
        vif.driver_cb.wstrb   <= tx.wstrb;
        vif.driver_cb.wvalid  <= 1'b1;

        aw_done = 0;
        w_done  = 0;

        // Wait two clock edges: 1st may be stale (isTriggered=false, outputs
        // not yet on wire); 2nd is a fresh posedge where awvalid/wvalid are
        // stable and the DUT has had a full cycle to capture them.
        repeat(2) @(vif.driver_cb);

        // Check if handshakes already completed on the settling cycles
        if (!aw_done && vif.driver_cb.awready) begin
            aw_done = 1;
            vif.driver_cb.awvalid <= 1'b0;
        end
        if (!w_done && vif.driver_cb.wready) begin
            w_done = 1;
            vif.driver_cb.wvalid <= 1'b0;
        end

        // Wait for any remaining handshakes
        while (!aw_done || !w_done) begin
            @(vif.driver_cb);
            if (!aw_done && vif.driver_cb.awready) begin
                aw_done = 1;
                vif.driver_cb.awvalid <= 1'b0;
            end
            if (!w_done && vif.driver_cb.wready) begin
                w_done = 1;
                vif.driver_cb.wvalid <= 1'b0;
            end
        end

        // Collect B response
        vif.driver_cb.bready <= 1'b1;
        `uvm_info("AXIL_DRV", $sformatf("AW+W done — waiting for bvalid (addr=0x%0h)", tx.addr), UVM_LOW)
        do begin
            @(vif.driver_cb);
        end while (!vif.driver_cb.bvalid);

        tx.resp = vif.driver_cb.bresp;
        vif.driver_cb.bready <= 1'b0;

        `uvm_info("AXIL_DRV", tx.convert2string(), UVM_HIGH)
    endtask

    // Drive AR, wait for R response.
    // Note on output #0 clocking-block timing: outputs propagate to the wire
    // only when driver_cb.isTriggered() (posedge eval_step Observable region),
    // which is AFTER the DUT Active region. To ensure the DUT sees arvalid=1
    // at its next Active region, arvalid must be driven in the previous
    // Reactive region with isTriggered()=true at that time.
    //
    // If the driver wakes on a stale posedge trigger (from get_next_item
    // completing mid-cycle), the first @(driver_cb) fires immediately but
    // isTriggered()=false (cleared by clearTriggeredEvents). Using repeat(2)
    // guarantees the second @(driver_cb) fires on a fresh posedge with
    // isTriggered()=true, so arvalid propagates to the wire correctly.
    task drive_read(axi4_lite_transaction tx);
        repeat(2) @(vif.driver_cb);     // 1st may be stale; 2nd is fresh posedge

        vif.driver_cb.araddr  <= tx.addr[7:0];
        vif.driver_cb.arvalid <= 1'b1;
        vif.driver_cb.rready  <= 1'b1;

        // Wait until arready (DUT accepts AR) or rvalid (DUT already responding)
        do begin
            @(vif.driver_cb);
        end while (!vif.driver_cb.arready && !vif.driver_cb.rvalid);

        vif.driver_cb.arvalid <= 1'b0;

        if (!vif.driver_cb.rvalid) begin
            do begin
                @(vif.driver_cb);
            end while (!vif.driver_cb.rvalid);
        end

        tx.rdata = vif.driver_cb.rdata;
        tx.resp  = vif.driver_cb.rresp;
        @(vif.driver_cb);
        vif.driver_cb.rready <= 1'b0;

        `uvm_info("AXIL_DRV", tx.convert2string(), UVM_HIGH)
    endtask
endclass
