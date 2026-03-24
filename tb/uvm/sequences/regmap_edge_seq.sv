// regmap_edge_seq.sv — AXI4-Lite register map edge-case sequence
//
// Targets uncovered lines in axi4_lite_slave.sv:
//   - CTRL register write (start + soft_reset bits)
//   - Write to unmapped / read-only address (default write case)
//   - Read from unmapped address (default read → 0xDEAD_BEEF)
//   - Exercises aw_captured / w_captured handshake logic

class regmap_edge_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(regmap_edge_seq)

    localparam bit [31:0] REG_CTRL     = 32'h00;
    localparam bit [31:0] REG_STATUS   = 32'h04;
    localparam bit [31:0] REG_WGT_ADDR = 32'h08;
    localparam bit [31:0] REG_WGT_DATA = 32'h0C;
    localparam bit [31:0] REG_RESULT   = 32'h10;
    localparam bit [31:0] REG_UNMAPPED = 32'h20;

    function new(string name = "regmap_edge_seq");
        super.new(name);
    endfunction

    task body();
        `uvm_info("REGMAP_EDGE", "Starting register-map edge-case sequence", UVM_LOW)

        // ---- 1. Write CTRL with start bit ----
        do_write(REG_CTRL, 32'h0000_0001, "CTRL start");

        // ---- 2. Write CTRL with soft_reset bit ----
        do_write(REG_CTRL, 32'h0000_0002, "CTRL soft_reset");

        // ---- 3. Write CTRL with both bits ----
        do_write(REG_CTRL, 32'h0000_0003, "CTRL start+soft_reset");

        // ---- 4. Write to unmapped address (should hit default case) ----
        do_write(REG_UNMAPPED, 32'hCAFE_BABE, "unmapped write");

        // ---- 5. Write to read-only STATUS register (should hit default) ----
        do_write(REG_STATUS, 32'hFFFF_FFFF, "STATUS write (read-only)");

        // ---- 6. Write to read-only RESULT register (should hit default) ----
        do_write(REG_RESULT, 32'h1234_5678, "RESULT write (read-only)");

        // ---- 7. Read from unmapped address (should return 0xDEAD_BEEF) ----
        do_read(REG_UNMAPPED, "unmapped read");

        // ---- 8. Read CTRL address (unmapped for reads → DEAD_BEEF) ----
        do_read(REG_CTRL, "CTRL read");

        // ---- 9. Read WGT_ADDR (unmapped for reads) ----
        do_read(REG_WGT_ADDR, "WGT_ADDR read");

        // ---- 10. Read WGT_DATA (unmapped for reads) ----
        do_read(REG_WGT_DATA, "WGT_DATA read");

        // ---- 11. Back-to-back writes with no gap ----
        do_write(REG_WGT_ADDR, 32'h0000_0000, "b2b write 1");
        do_write(REG_WGT_DATA, 32'h0000_3F80, "b2b write 2");
        do_write(REG_WGT_ADDR, 32'h0000_0001, "b2b write 3");
        do_write(REG_WGT_DATA, 32'h0000_3F00, "b2b write 4");

        `uvm_info("REGMAP_EDGE", "Register-map edge-case sequence complete", UVM_LOW)
    endtask

    task do_write(bit [31:0] addr, bit [31:0] data, string tag);
        axi4_lite_transaction tx = axi4_lite_transaction::type_id::create("tx");
        start_item(tx);
        tx.is_write = 1;
        tx.addr     = addr;
        tx.data     = data;
        tx.wstrb    = 4'hF;
        finish_item(tx);
        `uvm_info("REGMAP_EDGE", $sformatf("  write %s: addr=0x%02h data=0x%08h", tag, addr, data), UVM_HIGH)
    endtask

    task do_read(bit [31:0] addr, string tag);
        axi4_lite_transaction tx = axi4_lite_transaction::type_id::create("tx");
        start_item(tx);
        tx.is_write = 0;
        tx.addr     = addr;
        finish_item(tx);
        `uvm_info("REGMAP_EDGE", $sformatf("  read  %s: addr=0x%02h rdata=0x%08h", tag, addr, tx.rdata), UVM_HIGH)
    endtask
endclass
