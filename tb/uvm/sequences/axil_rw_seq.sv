// axil_rw_seq.sv — Utility sequences for AXI4-Lite register access
//
// Provides simple write and read sequences for use by tests.

// Single AXI4-Lite write
class axil_write_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(axil_write_seq)

    bit [31:0] addr;
    bit [31:0] data;

    function new(string name = "axil_write_seq");
        super.new(name);
    endfunction

    task body();
        axi4_lite_transaction tx = axi4_lite_transaction::type_id::create("tx");
        start_item(tx);
        tx.is_write = 1;
        tx.addr     = addr;
        tx.data     = data;
        tx.wstrb    = 4'hF;
        finish_item(tx);
    endtask
endclass

// Single AXI4-Lite read (result in rdata field)
class axil_read_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(axil_read_seq)

    bit [31:0] addr;
    bit [31:0] rdata;

    function new(string name = "axil_read_seq");
        super.new(name);
    endfunction

    task body();
        axi4_lite_transaction tx = axi4_lite_transaction::type_id::create("tx");
        start_item(tx);
        tx.is_write = 0;
        tx.addr     = addr;
        finish_item(tx);
        rdata = tx.rdata;
    endtask
endclass

// Poll STATUS register until result_ready=1 and busy=0
class axil_poll_status_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(axil_poll_status_seq)

    localparam bit [31:0] REG_STATUS = 32'h04;

    int max_polls = 200;
    bit timed_out = 0;

    function new(string name = "axil_poll_status_seq");
        super.new(name);
    endfunction

    task body();
        axi4_lite_transaction tx;

        for (int i = 0; i < max_polls; i++) begin
            tx = axi4_lite_transaction::type_id::create("tx");
            start_item(tx);
            tx.is_write = 0;
            tx.addr     = REG_STATUS;
            finish_item(tx);

            // STATUS[0] = result_ready, STATUS[1] = busy
            if (tx.rdata[0] && !tx.rdata[1]) begin
                timed_out = 0;
                return;
            end
        end

        timed_out = 1;
    endtask
endclass
