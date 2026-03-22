// axi4_lite_sequencer.sv — AXI4-Lite UVM sequencer

class axi4_lite_sequencer extends uvm_sequencer #(axi4_lite_transaction);
    `uvm_component_utils(axi4_lite_sequencer)

    function new(string name = "axi4_lite_sequencer", uvm_component parent = null);
        super.new(name, parent);
    endfunction
endclass
