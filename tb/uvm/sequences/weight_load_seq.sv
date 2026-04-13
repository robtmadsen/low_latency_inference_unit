// weight_load_seq.sv — Sequence to load weights via AXI4-Lite
//
// Writes bfloat16 weights into the weight memory through the register map:
//   addr[11:10] = 2'b10 → weight region
//   addr[9:7]   = core select (0 for core 0)
//   addr[6:2]   = weight address index
//   write data[15:0] = bfloat16 weight value
//
// Example: core 0, weight i → addr = 12'h800 | (i << 2)

class weight_load_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(weight_load_seq)

    // Weight values to load (bfloat16 packed in lower 16 bits of 32-bit word)
    bit [15:0] weights[];

    function new(string name = "weight_load_seq");
        super.new(name);
    endfunction

    task body();
        axi4_lite_transaction tx;

        `uvm_info("WGT_LOAD", $sformatf("Loading %0d weights", weights.size()), UVM_MEDIUM)

        foreach (weights[i]) begin
            // Single write: addr[11:10]=2'b10 (weight region),
            //               addr[9:7]=3'b000 (core 0), addr[6:2]=waddr
            // data[15:0] = bfloat16 weight value
            tx = axi4_lite_transaction::type_id::create("tx");
            start_item(tx);
            tx.is_write = 1;
            tx.addr     = 32'h800 | (i << 2);   // core 0, waddr = i
            tx.data     = {16'b0, weights[i]};
            tx.wstrb    = 4'hF;
            finish_item(tx);

            `uvm_info("WGT_LOAD", $sformatf("  [%0d] addr=0x%03h val=0x%04h", i, 32'h800 | (i << 2), weights[i]), UVM_HIGH)
        end

        `uvm_info("WGT_LOAD", "Weight load complete", UVM_MEDIUM)
    endtask
endclass
