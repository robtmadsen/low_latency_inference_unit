.PHONY: all compile test clean

UVM_HOME ?= /home/azureuser/uvm-core/src
VERILATOR = verilator
REPORT_DIR = ../reports

RTL_DIR = ../rtl
RTL_SRCS = \
    $(RTL_DIR)/lliu_pkg.sv \
    $(RTL_DIR)/bfloat16_mul.sv \
    $(RTL_DIR)/fp32_acc.sv \
    $(RTL_DIR)/weight_mem.sv \
    $(RTL_DIR)/dot_product_engine.sv \
    $(RTL_DIR)/output_buffer.sv \
    $(RTL_DIR)/lliu_core.sv

TB_SRCS = \
    lliu_core_if.sv \
    lliu_core_tb_pkg.sv \
    tb_top.sv

DPI_SRCS = uvm_dpi_verilator.cpp

VFLAGS = --binary --timing -j 0 \
    +incdir+$(UVM_HOME) \
    --top-module tb_top \
    --coverage-line \
    -CFLAGS "-I$(UVM_HOME)/dpi" \
    -Wno-fatal -Wno-lint -Wno-style

all: compile

compile: obj_dir/Vtb_top

obj_dir/Vtb_top: $(RTL_SRCS) $(TB_SRCS) Makefile
	$(VERILATOR) $(VFLAGS) \
	    $(UVM_HOME)/uvm_pkg.sv \
	    $(RTL_SRCS) $(TB_SRCS) \
	    $(DPI_SRCS)

test: compile
	@mkdir -p $(REPORT_DIR)
	./obj_dir/Vtb_top +UVM_TESTNAME=lliu_core_base_test +UVM_VERBOSITY=UVM_LOW
	@verilator_coverage --annotate-all --annotate $(REPORT_DIR)/annotate coverage.dat 2>/dev/null || true
	@python3 gen_coverage.py

clean:
	rm -rf obj_dir coverage.dat $(REPORT_DIR)
