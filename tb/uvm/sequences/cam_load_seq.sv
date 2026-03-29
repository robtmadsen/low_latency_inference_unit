// cam_load_seq.sv — AXI4-Lite sequence to load entries into symbol_filter CAM
//
// For kc705_top context: drives the AXI4-Lite slave's CAM write registers.
// Address encoding (from RTL plan, §kc705_top register map):
//   addr[7:2] = cam_index  (6-bit entry index, 0–63)
//   addr[1]   = valid_bit  (1 = enabled, 0 = invalidate)
//   addr[0]   = reserved 0
// Higher 32 bits of the 64-bit CAM key are written at offset 0;
// lower 32 bits trigger the actual write (two separate 32-bit writes).
//
// NOTE: This sequence operates via AXI4-Lite only (for kc705_top tests).
// For symbol_filter block-level tests (SYMFILTER_DUT), the test class
// drives cam_wr_* ports directly via kc705_ctrl_if — cam_load_seq is not
// used in that context.

class cam_load_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(cam_load_seq)

    // ---------------------------------------------------------------
    // AXI4-Lite CAM register base address (per kc705_top register map)
    // ---------------------------------------------------------------
    localparam bit [31:0] CAM_WR_BASE = 32'h80;   // 0x80–0xFF reserved for CAM

    function new(string name = "cam_load_seq");
        super.new(name);
    endfunction

    // ---------------------------------------------------------------
    // Tasks
    // ---------------------------------------------------------------

    // Write one 64-bit CAM entry (two 32-bit AXI4-Lite writes: high then low)
    task load_entry(int unsigned index, bit [63:0] key);
        bit [31:0] addr_base;
        axi4_lite_transaction tx;

        if (index > 63)
            `uvm_fatal("CAM_LOAD", $sformatf("cam_index %0d out of range (max 63)", index))

        // addr[7:2] = index, addr[1] = 1 (enabled), addr[0] = 0
        addr_base = CAM_WR_BASE | ((index & 6'h3F) << 2) | 32'h2;

        // Write high 32 bits of key first (addr_base + 0)
        tx = axi4_lite_transaction::type_id::create("tx_hi");
        start_item(tx);
        tx.is_write = 1'b1;
        tx.addr     = addr_base;
        tx.data     = key[63:32];
        finish_item(tx);

        // Write low 32 bits of key (addr_base + 4) — triggers DUT latch
        tx = axi4_lite_transaction::type_id::create("tx_lo");
        start_item(tx);
        tx.is_write = 1'b1;
        tx.addr     = addr_base + 4;
        tx.data     = key[31:0];
        finish_item(tx);

        `uvm_info("CAM_LOAD",
            $sformatf("  [%0d] key=0x%016h enabled", index, key),
            UVM_HIGH)
    endtask

    // Invalidate one CAM entry (set enabled bit to 0)
    task invalidate_entry(int unsigned index);
        bit [31:0] addr_base;
        axi4_lite_transaction tx;

        // addr[7:2] = index, addr[1] = 0 (disabled)
        addr_base = CAM_WR_BASE | ((index & 6'h3F) << 2);

        tx = axi4_lite_transaction::type_id::create("tx_inv");
        start_item(tx);
        tx.is_write = 1'b1;
        tx.addr     = addr_base;
        tx.data     = 32'h0;
        finish_item(tx);

        `uvm_info("CAM_LOAD",
            $sformatf("  [%0d] invalidated", index),
            UVM_HIGH)
    endtask

    // Bulk-load from a queue of 64-bit keys (index 0 … N-1)
    task load_watchlist(bit [63:0] tickers[$]);
        if (tickers.size() > 64)
            `uvm_fatal("CAM_LOAD", "load_watchlist: too many entries (max 64)")
        foreach (tickers[i])
            load_entry(i, tickers[i]);
    endtask

    // Invalidate all 64 entries
    task clear_all();
        for (int i = 0; i < 64; i++)
            invalidate_entry(i);
    endtask

    // body is intentionally empty — callers use the tasks directly
    task body();
        `uvm_info("CAM_LOAD", "cam_load_seq body called (use tasks directly)", UVM_DEBUG)
    endtask

endclass
