// lliu_base_test.sv — Base UVM test for LLIU
//
// Builds the environment, applies default configuration.
// All test-specific tests extend this class.

class lliu_base_test extends uvm_test;
    `uvm_component_utils(lliu_base_test)

    lliu_env m_env;

    function new(string name = "lliu_base_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        m_env = lliu_env::type_id::create("m_env", this);
    endfunction

    task run_phase(uvm_phase phase);
        phase.raise_objection(this, "lliu_base_test timeout guard");

        // Default timeout — derived tests override run_phase with actual stimulus
        #100us;

        phase.drop_objection(this, "lliu_base_test timeout guard");
    endtask

    function void report_phase(uvm_phase phase);
        uvm_report_server srv = uvm_report_server::get_server();
        if (srv.get_severity_count(UVM_FATAL) + srv.get_severity_count(UVM_ERROR) > 0)
            `uvm_error("TEST", "** TEST FAILED **")
        else
            `uvm_info("TEST", "** TEST PASSED **", UVM_NONE)
    endfunction
endclass
