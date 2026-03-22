SIM = verilator
TOPLEVEL_LANG = verilog

# RTL source directory
RTL_DIR = $(PWD)/../../rtl

# RTL sources — package first, then modules
VERILOG_SOURCES = $(RTL_DIR)/lliu_pkg.sv

# Add sources based on TOPLEVEL
ifeq ($(TOPLEVEL),bfloat16_mul)
    VERILOG_SOURCES += $(RTL_DIR)/bfloat16_mul.sv
else ifeq ($(TOPLEVEL),fp32_acc)
    VERILOG_SOURCES += $(RTL_DIR)/fp32_acc.sv
else ifeq ($(TOPLEVEL),dot_product_engine)
    VERILOG_SOURCES += $(RTL_DIR)/bfloat16_mul.sv
    VERILOG_SOURCES += $(RTL_DIR)/fp32_acc.sv
    VERILOG_SOURCES += $(RTL_DIR)/dot_product_engine.sv
else ifeq ($(TOPLEVEL),itch_parser)
    VERILOG_SOURCES += $(RTL_DIR)/itch_field_extract.sv
    VERILOG_SOURCES += $(RTL_DIR)/itch_parser.sv
else ifeq ($(TOPLEVEL),lliu_top)
    VERILOG_SOURCES += $(shell find $(RTL_DIR) -name '*.sv' ! -name 'lliu_pkg.sv')
endif

# Test module lives in tests/
MODULE = tests.$(TEST_MODULE)

# Verilator extra args
EXTRA_ARGS += --trace
EXTRA_ARGS += -Wno-IMPORTSTAR -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

# cocotb Makefile.sim
include $(shell cocotb-config --makefiles)/Makefile.sim
