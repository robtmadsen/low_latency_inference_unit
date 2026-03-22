// axi4_lite_transaction.sv — AXI4-Lite sequence item
//
// Represents a single AXI4-Lite read or write transaction.

class axi4_lite_transaction extends uvm_sequence_item;
    `uvm_object_utils(axi4_lite_transaction)

    rand bit [31:0] addr;
    rand bit [31:0] data;
    rand bit [3:0]  wstrb;
    bit             is_write;   // 1 = write, 0 = read

    // Response (captured by driver after transaction completes)
    bit [1:0]       resp;
    bit [31:0]      rdata;      // populated for reads

    constraint c_aligned_addr {
        addr[1:0] == 2'b00;    // word-aligned
    }

    constraint c_default_wstrb {
        wstrb == 4'hF;         // full-word writes
    }

    function new(string name = "axi4_lite_transaction");
        super.new(name);
    endfunction

    function void do_copy(uvm_object rhs);
        axi4_lite_transaction tx;
        super.do_copy(rhs);
        if (!$cast(tx, rhs))
            `uvm_fatal("CAST", "Failed to cast rhs in do_copy")
        addr     = tx.addr;
        data     = tx.data;
        wstrb    = tx.wstrb;
        is_write = tx.is_write;
        resp     = tx.resp;
        rdata    = tx.rdata;
    endfunction

    function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        axi4_lite_transaction tx;
        if (!$cast(tx, rhs)) return 0;
        return (addr == tx.addr) && (data == tx.data) &&
               (is_write == tx.is_write);
    endfunction

    function string convert2string();
        if (is_write)
            return $sformatf("AXI4-Lite WR: addr=0x%02h data=0x%08h wstrb=0x%01h resp=%0d",
                             addr, data, wstrb, resp);
        else
            return $sformatf("AXI4-Lite RD: addr=0x%02h rdata=0x%08h resp=%0d",
                             addr, rdata, resp);
    endfunction
endclass
