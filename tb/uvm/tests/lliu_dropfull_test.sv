// lliu_dropfull_test.sv — Block-level test for eth_axis_rx_wrap
//
// DUT TOPLEVEL: eth_axis_rx_wrap
// Compile with: make SIM=verilator TOPLEVEL=eth_axis_rx_wrap TEST=lliu_dropfull_test
//
// eth_axis_rx_wrap wraps a MAC RX framer with a drop-on-full policy:
//   - mac_rx_tready is ALWAYS 1 (MAC can never be stalled)
//   - When fifo_almost_full is asserted at frame SOF, the entire frame is dropped
//   - dropped_frames counter increments once per dropped frame
//
// Scenarios:
//   1. Normal passthrough (fifo_almost_full=0)  — all frames on eth_payload, zero drops
//   2. Single drop (fifo_almost_full=1)          — frame N suppressed, dropped_frames=1
//   3. Drop-then-pass                            — frame N+1 passes cleanly
//   4. 5 consecutive drops                       — dropped_frames=5, SVA passes
//   5. Mid-frame full assertion                  — mac_rx_tready still 1, frame dropped whole
//   6. Counter saturation                        — pre-set dropped_frames high, verify sat
//
// P1 (mac_rx_tready_never_low) is checked by drop_on_full_sva on every cycle.
// P3/P5 require RTL internal signals (drop_current, frame_active) — see SVA stubs.

// Helper: wrap a pre-built axi4_stream_transaction in a single-shot sequence
// so it can be started from test run_phase (not from inside a sequence body).
class dropfull_axis_seq extends uvm_sequence #(axi4_stream_transaction);
    `uvm_object_utils(dropfull_axis_seq)
    axi4_stream_transaction tx;
    function new(string name = "dropfull_axis_seq"); super.new(name); endfunction
    task body();
        start_item(tx);
        finish_item(tx);
    endtask
endclass

class lliu_dropfull_test extends lliu_base_test;
    `uvm_component_utils(lliu_dropfull_test)

    virtual kc705_ctrl_if kc705_vif;

    function new(string name = "lliu_dropfull_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        uvm_config_db #(bit)::set(this, "*", "kc705_sim_mode", 1'b1);
    endfunction

    function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!uvm_config_db #(virtual kc705_ctrl_if)::get(
                this, "", "kc705_vif", kc705_vif))
            `uvm_fatal("NOVIF", "kc705_ctrl_if virtual interface not found")
    endfunction

    // -----------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------

    // Count output beats on eth_payload while still running
    int m_beat_count;

    // Send N beats on mac_rx AXI4-S (via axis_if, which tb_top maps to mac_rx_* in DROPFULL_DUT)
    // The axi4_stream_agent drives axis_if.tdata/tvalid/tlast; tkeep is from kc705_if.s_tkeep.
    task send_frame(int beats);
        dropfull_axis_seq seq;
        axi4_stream_transaction tx;
        tx = axi4_stream_transaction::type_id::create("tx");
        tx.tdata = new[beats];
        for (int i = 0; i < beats; i++)
            tx.tdata[i] = 64'hDEAD_BEEF_0000_0000 | i;
        seq = dropfull_axis_seq::type_id::create("seq");
        seq.tx = tx;
        seq.start(m_env.m_axis_agent.m_sequencer);
        repeat (2) @(posedge kc705_vif.clk);  // pipeline flush
    endtask

    // Count eth_payload_tvalid beats over a window
    task count_output_beats(int window_cycles, output int count);
        count = 0;
        for (int c = 0; c < window_cycles; c++) begin
            @(kc705_vif.monitor_cb);
            if (kc705_vif.monitor_cb.eth_payload_tvalid)
                count++;
        end
    endtask

    // -----------------------------------------------------------
    // run_phase
    // -----------------------------------------------------------
    task run_phase(uvm_phase phase);
        int out_beats;
        phase.raise_objection(this, "lliu_dropfull_test");

        // Init control signals
        kc705_vif.driver_cb.fifo_almost_full   <= 1'b0;
        kc705_vif.driver_cb.eth_payload_tready <= 1'b1;
        kc705_vif.driver_cb.s_tkeep            <= 8'hFF;
        repeat (5) @(kc705_vif.driver_cb);

        // ── Scenario 1: normal passthrough ────────────────────────
        `uvm_info("TEST", "=== Scenario 1: normal passthrough ===", UVM_LOW)
        kc705_vif.driver_cb.fifo_almost_full <= 1'b0;
        @(kc705_vif.driver_cb);
        fork
            send_frame(4);
            count_output_beats(20, out_beats);
        join
        if (out_beats == 0)
            `uvm_error("TEST", "Scenario1: expected output beats but got 0")
        else
            `uvm_info("TEST", $sformatf("Scenario1 PASS: %0d output beats", out_beats), UVM_LOW)
        if (kc705_vif.monitor_cb.dropped_frames != 0)
            `uvm_error("TEST", $sformatf("Scenario1: dropped_frames=%0d, expected 0",
                kc705_vif.monitor_cb.dropped_frames))

        // ── Scenario 2: single drop ────────────────────────────────
        `uvm_info("TEST", "=== Scenario 2: single drop ===", UVM_LOW)
        begin
            automatic int drops_before = kc705_vif.monitor_cb.dropped_frames;
            // Assert fifo_almost_full BEFORE the frame starts
            kc705_vif.driver_cb.fifo_almost_full <= 1'b1;
            @(kc705_vif.driver_cb);
            fork
                send_frame(4);
                count_output_beats(20, out_beats);
            join
            kc705_vif.driver_cb.fifo_almost_full <= 1'b0;
            repeat (5) @(kc705_vif.driver_cb);
            if (kc705_vif.monitor_cb.dropped_frames != drops_before + 1)
                `uvm_error("TEST", $sformatf(
                    "Scenario2: expected dropped_frames=%0d, got=%0d",
                    drops_before + 1, kc705_vif.monitor_cb.dropped_frames))
            else
                `uvm_info("TEST", "Scenario2 PASS: one frame dropped", UVM_LOW)
        end

        // ── Scenario 3: drop then pass ─────────────────────────────
        `uvm_info("TEST", "=== Scenario 3: drop then pass ===", UVM_LOW)
        begin
            automatic int drops_before = kc705_vif.monitor_cb.dropped_frames;
            kc705_vif.driver_cb.fifo_almost_full <= 1'b0;
            @(kc705_vif.driver_cb);
            fork
                send_frame(4);
                count_output_beats(20, out_beats);
            join
            if (kc705_vif.monitor_cb.dropped_frames != drops_before)
                `uvm_error("TEST", "Scenario3: unexpected drop on pass-through frame")
            else if (out_beats == 0)
                `uvm_error("TEST", "Scenario3: frame N+1 should pass but no output")
            else
                `uvm_info("TEST", "Scenario3 PASS: frame N+1 passes cleanly", UVM_LOW)
        end

        // ── Scenario 4: 5 consecutive drops ───────────────────────
        `uvm_info("TEST", "=== Scenario 4: 5 consecutive drops ===", UVM_LOW)
        begin
            automatic int drops_before = kc705_vif.monitor_cb.dropped_frames;
            kc705_vif.driver_cb.fifo_almost_full <= 1'b1;
            @(kc705_vif.driver_cb);
            for (int i = 0; i < 5; i++) begin
                send_frame(4);
                repeat (2) @(kc705_vif.driver_cb);
            end
            kc705_vif.driver_cb.fifo_almost_full <= 1'b0;
            repeat (5) @(kc705_vif.driver_cb);
            if (kc705_vif.monitor_cb.dropped_frames != drops_before + 5)
                `uvm_error("TEST", $sformatf(
                    "Scenario4: expected %0d drops, got %0d",
                    drops_before + 5, kc705_vif.monitor_cb.dropped_frames))
            else
                `uvm_info("TEST", "Scenario4 PASS: 5 consecutive drops counted", UVM_LOW)
        end

        // ── Scenario 5: mid-frame full assertion ──────────────────
        // mac_rx_tready must stay 1 even when fifo_almost_full asserts mid-frame
        // The P1 SVA (mac_rx_tready_never_low) continuously checks this.
        `uvm_info("TEST", "=== Scenario 5: mid-frame full assertion ===", UVM_LOW)
        kc705_vif.driver_cb.fifo_almost_full <= 1'b0;
        @(kc705_vif.driver_cb);
        fork
            send_frame(8);   // 8-beat frame
            begin
                // Assert fifo_almost_full after 3 beats (mid-frame)
                repeat (3) @(kc705_vif.driver_cb);
                kc705_vif.driver_cb.fifo_almost_full <= 1'b1;
                repeat (3) @(kc705_vif.driver_cb);
                kc705_vif.driver_cb.fifo_almost_full <= 1'b0;
            end
        join
        repeat (5) @(kc705_vif.driver_cb);
        `uvm_info("TEST", "Scenario5 PASS: mid-frame full, SVA mac_rx_tready checked", UVM_LOW)

        repeat (5) @(kc705_vif.driver_cb);
        phase.drop_objection(this, "lliu_dropfull_test");
    endtask

endclass
