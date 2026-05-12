/* Stubs for UVM HDL backdoor access – not supported in Verilator */
#include "svdpi.h"

int uvm_hdl_check_path(const char* path) { return 0; }
int uvm_hdl_deposit(const char* path, const svLogicVecVal* value, int size) { return 0; }
int uvm_hdl_release(const char* path, int size) { return 0; }
int uvm_hdl_read(const char* path, svLogicVecVal* value, int size) { return 0; }
