module uvm_test_compile;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  initial begin
    `uvm_info("TEST", "Hello UVM", UVM_LOW)
    $finish;
  end
endmodule
