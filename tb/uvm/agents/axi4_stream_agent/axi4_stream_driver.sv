// axi4_stream_driver.sv — AXI4-Stream UVM driver
//
// Drives AXI4-Stream transactions onto the bus.
// Respects tready handshake: tdata/tvalid held until tready sampled.

class axi4_stream_driver extends uvm_driver #(axi4_stream_transaction);
    `uvm_component_utils(axi4_stream_driver)

    virtual axi4_stream_if vif;

    function new(string name = "axi4_stream_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!uvm_config_db#(virtual axi4_stream_if)::get(this, "", "vif", vif))
            `uvm_fatal("NOVIF", "Virtual interface not found for axi4_stream_driver")
    endfunction

    task run_phase(uvm_phase phase);
        axi4_stream_transaction tx;

        // Initialize bus to idle
        vif.driver_cb.tdata  <= '0;
        vif.driver_cb.tvalid <= 1'b0;
        vif.driver_cb.tlast  <= 1'b0;

        // Wait for reset deassertion
        @(negedge vif.rst);
        @(posedge vif.clk);

        forever begin
            seq_item_port.get_next_item(tx);
            drive_transaction(tx);
            seq_item_port.item_done();
        end
    endtask

    task drive_transaction(axi4_stream_transaction tx);
        foreach (tx.tdata[i]) begin
            vif.driver_cb.tdata  <= tx.tdata[i];
            vif.driver_cb.tvalid <= 1'b1;
            vif.driver_cb.tlast  <= (i == tx.tdata.size() - 1) ? 1'b1 : 1'b0;

            // Wait for handshake (tvalid & tready)
            do begin
                @(vif.driver_cb);
            end while (!vif.driver_cb.tready);
        end

        // Deassert after final beat accepted
        @(vif.driver_cb);
        vif.driver_cb.tdata  <= '0;
        vif.driver_cb.tvalid <= 1'b0;
        vif.driver_cb.tlast  <= 1'b0;
    endtask
endclass
