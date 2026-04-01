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

    // ── AXI4-Lite addresses (per kc705_top / axi4_lite_slave register map) ──
    // These match weight_load_seq and must stay consistent with the RTL.
    localparam bit [31:0] REG_WGT_ADDR = 32'h08;
    localparam bit [31:0] REG_WGT_DATA = 32'h0C;
    localparam bit [31:0] CAM_WR_BASE  = 32'h80;   // bits[7:2]=index, bit[1]=en

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
        //    Register layout (cam_load_seq convention):
        //      addr = CAM_WR_BASE | (index << 2) | 2'b10  (enabled)
        //      write high 32 bits of key at addr+0
        //      write low  32 bits of key at addr+4 (triggers DUT latch)
        // ─────────────────────────────────────────────────────────
        if (watchlist.size() > 0) begin
            if (watchlist.size() > 64)
                `uvm_fatal("KC705_INIT", "watchlist > 64 entries (max 64 per symbol_filter)")

            foreach (watchlist[i]) begin
                bit [31:0] addr_base;
                bit [63:0] key;
                axi4_lite_transaction tx;

                key       = watchlist[i];
                addr_base = CAM_WR_BASE | (32'(i) << 2) | 32'h2;

                // Write high 32 bits of key
                tx = axi4_lite_transaction::type_id::create("cam_hi");
                start_item(tx);
                tx.is_write = 1'b1;
                tx.addr     = addr_base;
                tx.data     = key[63:32];
                tx.wstrb    = 4'hF;
                finish_item(tx);

                // Write low 32 bits — triggers DUT CAM latch
                tx = axi4_lite_transaction::type_id::create("cam_lo");
                start_item(tx);
                tx.is_write = 1'b1;
                tx.addr     = addr_base + 4;
                tx.data     = key[31:0];
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
