// lliu_order_book_test.sv — Order book Phase 1 fuzz stress test
//
// DUT TOPLEVEL: order_book
// Compile with: make SIM=verilator TOPLEVEL=order_book TEST=lliu_order_book_test
//
// Standalone test: creates order_book_agent directly (no env wrapper).
// The agent drives 1000 random ITCH messages (Add/Delete/Cancel/Replace/Execute)
// covering price/size boundary values and edge sym_ids.
//
// Pass criteria:
//   - No UVM_ERROR or UVM_FATAL messages
//   - Simulation completes without timeout
//   - collision_count is readable (exercised internally by the sequence)

class lliu_order_book_test extends uvm_test;
    `uvm_component_utils(lliu_order_book_test)

    order_book_agent m_ob_agent;

    function new(string name = "lliu_order_book_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_ob_agent = order_book_agent::type_id::create("m_ob_agent", this);
    endfunction

    task run_phase(uvm_phase phase);
        order_book_stress_seq seq;

        phase.raise_objection(this);

        seq = order_book_stress_seq::type_id::create("stress_seq");
        seq.num_ops = 1000;  // fixed count for deterministic regression budget

        seq.start(m_ob_agent.m_sequencer);

        // Allow DUT FSM to drain the last operation (~300 cycles @ 300 MHz)
        #1000ns;

        phase.drop_objection(this);
        `uvm_info("OB_TEST", "Order book stress test PASSED", UVM_NONE)
    endtask

    function void report_phase(uvm_phase phase);
        if (uvm_report_server::get_server().get_severity_count(UVM_ERROR) > 0 ||
            uvm_report_server::get_server().get_severity_count(UVM_FATAL) > 0)
            `uvm_error("TEST", "** TEST FAILED **")
        else
            `uvm_info("TEST", "** TEST PASSED **", UVM_NONE)
    endfunction
endclass
