// axi4_stream_transaction.sv — AXI4-Stream sequence item
//
// Represents a complete AXI4-Stream transaction (one or more beats).
// Each beat carries 64-bit data; tlast marks the final beat.

class axi4_stream_transaction extends uvm_sequence_item;
    `uvm_object_utils(axi4_stream_transaction)

    // Transaction data — dynamic array of 64-bit beats
    rand bit [63:0] tdata[];

    // Constraints
    constraint c_reasonable_len {
        tdata.size() inside {[1:64]};
    }

    function new(string name = "axi4_stream_transaction");
        super.new(name);
    endfunction

    function void do_copy(uvm_object rhs);
        axi4_stream_transaction tx;
        super.do_copy(rhs);
        if (!$cast(tx, rhs))
            `uvm_fatal("CAST", "Failed to cast rhs in do_copy")
        tdata = new[tx.tdata.size()](tx.tdata);
    endfunction

    function bit do_compare(uvm_object rhs, uvm_comparer comparer);
        axi4_stream_transaction tx;
        if (!$cast(tx, rhs))
            return 0;
        if (tdata.size() != tx.tdata.size())
            return 0;
        foreach (tdata[i])
            if (tdata[i] !== tx.tdata[i]) return 0;
        return 1;
    endfunction

    function string convert2string();
        string s;
        s = $sformatf("AXI4-Stream TX: %0d beats", tdata.size());
        foreach (tdata[i])
            s = {s, $sformatf("\n  beat[%0d] = 0x%016h", i, tdata[i])};
        return s;
    endfunction
endclass
