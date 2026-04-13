// kc705_init_seq.sv — KC705 board bring-up virtual sequence
//
// Composes the full KC705 initialisation sequence:
//   1. Assert cpu_reset for 10 clk cycles, then deassert + 6 cycle settle
//   2. Skip GTX lock poll (always in Verilator sim — kc705_sim_mode=1)
//   3. Load inference weights via AXI4-Lite (weight_load_seq)
//   4. Load symbol-filter watchlist via AXI4-Lite (inline CAM writes)
//
// Usage (from a test's run_phase):
//
//   kc705_init_seq init_seq;
//   init_seq = kc705_init_seq::type_id::create("init_seq");
//   // Optionally override defaults
//   init_seq.watchlist.push_back(kc705_init_seq::stock_to_bits64("AAPL    "));
//   init_seq.start(m_env.m_axil_agent.m_sequencer);  // runs body()
//
// Deriving the kc705_vif handle:
//   init_seq.kc705_vif must be populated before start() is called.
//   The test class typically does:
//     uvm_config_db #(virtual kc705_ctrl_if)::get(this,"","kc705_vif",init_seq.kc705_vif)
//
// Spec ref: UVM_PLAN_kintex-7.md §2c / MAS §2

class kc705_init_seq extends uvm_sequence #(axi4_lite_transaction);
    `uvm_object_utils(kc705_init_seq)

    // ── AXI4-Lite addresses (per lliu_top_v2 inline register map) ──
    // Weight region: addr[11:10]=2'b10 = base 0x800
    //   (used by weight_load_seq; defined there, not here)
    //
    // CAM watchlist registers (symbol_filter):
    //   0x038 → cam_idx_hi_r[1:0]  (upper 2 bits of 10-bit index, write first)
    //   0x014 → cam_idx_lo_r[7:0]  (lower 8 bits of 10-bit index)
    //   0x01C → cam_dat_hi_r[31:0] (key[63:32])
    //   0x018 → cam_dat_lo_r[31:0] (key[31:0])
    //   0x020 → write bit[0]=1 to strobe cam_wr_valid; bit[1]=cam_wr_en_bit
    localparam bit [31:0] REG_CAM_IDX_LO = 32'h014;
    localparam bit [31:0] REG_CAM_DAT_LO = 32'h018;
    localparam bit [31:0] REG_CAM_DAT_HI = 32'h01C;
    localparam bit [31:0] REG_CAM_CTRL   = 32'h020;
    localparam bit [31:0] REG_CAM_IDX_HI = 32'h038;

    // ── Configuration knobs (set before start()) ───────────────────
    // BF16 weights — one per feature vector element (4 × 1.0 by default)
    bit [15:0] weights[];

    // Watchlist — 64-bit big-endian ticker keys
    // e.g. "AAPL    " → 0x4141504C20202020
    // Use stock_to_bits64() helper or pre-compute.
    bit [63:0] watchlist[$];

    // ── Virtual interface handle ────────────────────────────────────
    virtual kc705_ctrl_if kc705_vif;

    // ── Constants ──────────────────────────────────────────────────
    localparam bit [15:0] BF16_ONE = 16'h3F80;   // 1.0 in bfloat16

    function new(string name = "kc705_init_seq");
        super.new(name);
        // Sensible defaults
        weights = new[4];
        foreach (weights[i]) weights[i] = BF16_ONE;
    endfunction

    // Pack an 8-character ASCII symbol into a 64-bit big-endian integer.
    // char[0] → bits[63:56], char[7] → bits[7:0].
    static function bit [63:0] stock_to_bits64(string sym);
        bit [63:0] v = 64'h2020202020202020;  // default: 8 spaces
        for (int i = 0; i < 8 && i < sym.len(); i++)
            v[63 - i*8 -: 8] = sym[i];
        return v;
    endfunction

    // ── body ────────────────────────────────────────────────────────
    task body();
        // ─────────────────────────────────────────────────────────
        // 1. Reset cycle management via kc705_ctrl_if
        // ─────────────────────────────────────────────────────────
        if (kc705_vif != null) begin
            kc705_vif.driver_cb.cpu_reset <= 1'b1;
            repeat (10) @(kc705_vif.driver_cb);
            kc705_vif.driver_cb.cpu_reset <= 1'b0;
            repeat (6)  @(kc705_vif.driver_cb);
            `uvm_info("KC705_INIT", "cpu_reset deasserted — DUT coming out of reset", UVM_LOW)
        end else begin
            `uvm_warning("KC705_INIT",
                "kc705_vif is null - cpu_reset not driven; ensure tb_top or test manages reset")
        end

        // ─────────────────────────────────────────────────────────
        // 2. GTX lock poll — always skip in simulation (sim_mode=1)
        // ─────────────────────────────────────────────────────────
        begin
            bit sim_mode = 1'b1;   // always true for Verilator
            void'(uvm_config_db #(bit)::get(null, "", "kc705_sim_mode", sim_mode));
            if (!sim_mode)
                `uvm_fatal("KC705_INIT",
                    "Non-sim GTX lock poll not implemented — run with kc705_sim_mode=1")
            `uvm_info("KC705_INIT", "GTX lock poll skipped (sim_mode=1)", UVM_MEDIUM)
        end

        // ─────────────────────────────────────────────────────────
        // 3. Load inference weights (uses weight_load_seq)
        // ─────────────────────────────────────────────────────────
        begin
            weight_load_seq wt_seq;
            wt_seq = weight_load_seq::type_id::create("kc705_weights");
            wt_seq.weights = new[weights.size()](weights);
            wt_seq.start(m_sequencer);
            `uvm_info("KC705_INIT",
                $sformatf("Loaded %0d weight(s)", weights.size()), UVM_MEDIUM)
        end

        // ─────────────────────────────────────────────────────────
        // 4. Load symbol-filter watchlist via AXI4-Lite CAM writes
        //    Register sequence per lliu_top_v2 inline register map:
        //      1. Write REG_CAM_IDX_HI = index[9:8]  (upper 2 bits)
        //      2. Write REG_CAM_IDX_LO = index[7:0]  (lower 8 bits)
        //      3. Write REG_CAM_DAT_HI = key[63:32]
        //      4. Write REG_CAM_DAT_LO = key[31:0]
        //      5. Write REG_CAM_CTRL   = 32'h3  (bit0=wr_valid, bit1=en_bit)
        // ─────────────────────────────────────────────────────────
        if (watchlist.size() > 0) begin
            if (watchlist.size() > 64)
                `uvm_fatal("KC705_INIT", "watchlist > 64 entries (max 64 per symbol_filter)")

            foreach (watchlist[i]) begin
                bit [63:0] key;
                axi4_lite_transaction tx;

                key = watchlist[i];

                // 1. Upper index bits (only needed if index > 255; always write for correctness)
                tx = axi4_lite_transaction::type_id::create("cam_idx_hi");
                start_item(tx);
                tx.is_write = 1'b1;
                tx.addr     = REG_CAM_IDX_HI;
                tx.data     = 32'(i[9:8]);
                tx.wstrb    = 4'hF;
                finish_item(tx);

                // 2. Lower index bits
                tx = axi4_lite_transaction::type_id::create("cam_idx_lo");
                start_item(tx);
                tx.is_write = 1'b1;
                tx.addr     = REG_CAM_IDX_LO;
                tx.data     = 32'(i[7:0]);
                tx.wstrb    = 4'hF;
                finish_item(tx);

                // 3. Key high 32 bits
                tx = axi4_lite_transaction::type_id::create("cam_dat_hi");
                start_item(tx);
                tx.is_write = 1'b1;
                tx.addr     = REG_CAM_DAT_HI;
                tx.data     = key[63:32];
                tx.wstrb    = 4'hF;
                finish_item(tx);

                // 4. Key low 32 bits
                tx = axi4_lite_transaction::type_id::create("cam_dat_lo");
                start_item(tx);
                tx.is_write = 1'b1;
                tx.addr     = REG_CAM_DAT_LO;
                tx.data     = key[31:0];
                tx.wstrb    = 4'hF;
                finish_item(tx);

                // 5. Strobe write: bit[0]=cam_wr_valid=1, bit[1]=cam_wr_en_bit=1
                tx = axi4_lite_transaction::type_id::create("cam_ctrl");
                start_item(tx);
                tx.is_write = 1'b1;
                tx.addr     = REG_CAM_CTRL;
                tx.data     = 32'h3;
                tx.wstrb    = 4'hF;
                finish_item(tx);

                `uvm_info("KC705_INIT",
                    $sformatf("  CAM[%0d] = 0x%016h", i, key), UVM_HIGH)
            end
            `uvm_info("KC705_INIT",
                $sformatf("Loaded %0d CAM watchlist entr%s",
                    watchlist.size(), watchlist.size() == 1 ? "y" : "ies"),
                UVM_MEDIUM)
        end

        `uvm_info("KC705_INIT", "=== KC705 init complete ===", UVM_LOW)
    endtask

endclass
