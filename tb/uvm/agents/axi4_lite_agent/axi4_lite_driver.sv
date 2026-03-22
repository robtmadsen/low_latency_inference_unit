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

        // Wait for reset deassertion
        @(negedge vif.rst);
        @(posedge vif.clk);

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
    task drive_write(axi4_lite_transaction tx);
        bit aw_done, w_done;

        // Present AW and W channels simultaneously
        vif.driver_cb.awaddr  <= tx.addr[7:0];
        vif.driver_cb.awvalid <= 1'b1;
        vif.driver_cb.wdata   <= tx.data;
        vif.driver_cb.wstrb   <= tx.wstrb;
        vif.driver_cb.wvalid  <= 1'b1;

        aw_done = 0;
        w_done  = 0;

        // Wait for both AW and W handshakes
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
        do begin
            @(vif.driver_cb);
        end while (!vif.driver_cb.bvalid);

        tx.resp = vif.driver_cb.bresp;
        vif.driver_cb.bready <= 1'b0;

        `uvm_info("AXIL_DRV", tx.convert2string(), UVM_HIGH)
    endtask

    // Drive AR, wait for R response
    task drive_read(axi4_lite_transaction tx);
        // Present AR channel
        vif.driver_cb.araddr  <= tx.addr[7:0];
        vif.driver_cb.arvalid <= 1'b1;

        // Wait for AR handshake
        do begin
            @(vif.driver_cb);
        end while (!vif.driver_cb.arready);
        vif.driver_cb.arvalid <= 1'b0;

        // Collect R response
        vif.driver_cb.rready <= 1'b1;
        do begin
            @(vif.driver_cb);
        end while (!vif.driver_cb.rvalid);

        tx.rdata = vif.driver_cb.rdata;
        tx.resp  = vif.driver_cb.rresp;
        vif.driver_cb.rready <= 1'b0;

        `uvm_info("AXIL_DRV", tx.convert2string(), UVM_HIGH)
    endtask
endclass
