`ifndef UVM_COMPAT_MACROS
`define UVM_COMPAT_MACROS

`define uvm_info(ID, MSG, VERB) \
    $display("[UVM_INFO] (%0t) %s: %s", $time, ID, MSG);

`define uvm_warning(ID, MSG) \
    $display("[UVM_WARNING] (%0t) %s: %s", $time, ID, MSG);

`define uvm_error(ID, MSG) \
    $display("[UVM_ERROR] (%0t) %s: %s", $time, ID, MSG);

`define uvm_fatal(ID, MSG) \
    begin \
        $display("[UVM_FATAL] (%0t) %s: %s", $time, ID, MSG); \
        $fatal(1, MSG); \
    end

`define uvm_component_utils(T)
`define uvm_object_utils(T)

`endif

package uvm_pkg;

    typedef enum int {
        UVM_NONE   = 0,
        UVM_LOW    = 100,
        UVM_MEDIUM = 200,
        UVM_HIGH   = 300,
        UVM_FULL   = 400,
        UVM_DEBUG  = 500
    } uvm_verbosity;

    class uvm_object;
        string m_name;
        function new(string name = "");
            m_name = name;
        endfunction
        virtual function string get_name();
            return m_name;
        endfunction
    endclass

    class uvm_sequence_item extends uvm_object;
        function new(string name = "");
            super.new(name);
        endfunction
    endclass

    class uvm_component extends uvm_object;
        uvm_component m_parent;
        function new(string name = "", uvm_component parent = null);
            super.new(name);
            m_parent = parent;
        endfunction
        virtual function void build_phase();
        endfunction
        virtual function void connect_phase();
        endfunction
        virtual task run_phase();
        endtask
        virtual function void report_phase();
        endfunction
    endclass

    class uvm_test extends uvm_component;
        function new(string name = "", uvm_component parent = null);
            super.new(name, parent);
        endfunction
    endclass

    class uvm_env extends uvm_component;
        function new(string name = "", uvm_component parent = null);
            super.new(name, parent);
        endfunction
    endclass

endpackage
