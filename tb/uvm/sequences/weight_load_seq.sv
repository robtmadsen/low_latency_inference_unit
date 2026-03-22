// weight_load_seq.sv — Sequence to load weights via AXI4-Lite
//
// Writes bfloat16 weights into the weight memory through the register map:
//   WGT_ADDR (0x08) — set target address
//   WGT_DATA (0x0C) — write data (triggers wr_en)

class weight_load_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(weight_load_seq)

    // Register addresses (matching axi4_lite_slave register map)
    localparam bit [31:0] REG_WGT_ADDR = 32'h08;
    localparam bit [31:0] REG_WGT_DATA = 32'h0C;

    // Weight values to load (bfloat16 packed in lower 16 bits of 32-bit word)
    bit [15:0] weights[];

    function new(string name = "weight_load_seq");
        super.new(name);
    endfunction

    task body();
        axi4_lite_transaction tx;

        `uvm_info("WGT_LOAD", $sformatf("Loading %0d weights", weights.size()), UVM_MEDIUM)

        foreach (weights[i]) begin
            // Write weight address
            tx = axi4_lite_transaction::type_id::create("tx");
            start_item(tx);
            tx.is_write = 1;
            tx.addr     = REG_WGT_ADDR;
            tx.data     = i;
            tx.wstrb    = 4'hF;
            finish_item(tx);

            // Write weight data (triggers wr_en in RTL)
            tx = axi4_lite_transaction::type_id::create("tx");
            start_item(tx);
            tx.is_write = 1;
            tx.addr     = REG_WGT_DATA;
            tx.data     = {16'b0, weights[i]};
            tx.wstrb    = 4'hF;
            finish_item(tx);

            `uvm_info("WGT_LOAD", $sformatf("  [%0d] = 0x%04h", i, weights[i]), UVM_HIGH)
        end

        `uvm_info("WGT_LOAD", "Weight load complete", UVM_MEDIUM)
    endtask
endclass
