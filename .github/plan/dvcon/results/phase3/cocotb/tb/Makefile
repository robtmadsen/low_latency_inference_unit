SIM       ?= verilator
TOPLEVEL_LANG ?= verilog

VERILOG_SOURCES = \
    $(abspath ../rtl/lliu_pkg.sv) \
    $(abspath ../rtl/bfloat16_mul.sv) \
    $(abspath ../rtl/fp32_acc.sv) \
    $(abspath ../rtl/weight_mem.sv) \
    $(abspath ../rtl/dot_product_engine.sv) \
    $(abspath ../rtl/output_buffer.sv) \
    $(abspath ../rtl/lliu_core.sv) \
    $(abspath lliu_core_wrapper.sv)

TOPLEVEL = lliu_core_wrapper
MODULE   = test_lliu_core

EXTRA_ARGS += --coverage-line --coverage-toggle
EXTRA_ARGS += -Wno-fatal
EXTRA_ARGS += -DVERILATOR_SIM

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: test coverage

test: sim coverage

COVERAGE_DAT := $(shell find . -path '*/coverage.dat' 2>/dev/null | head -1)

coverage:
	@mkdir -p ../reports
	@# Find coverage.dat wherever verilator put it
	$(eval COV_FILE := $(shell find . -name 'coverage.dat' 2>/dev/null | head -1))
	@if [ -n "$(COV_FILE)" ]; then \
	    verilator_coverage --annotate-all --annotate coverage_ann $(COV_FILE) 2>/dev/null; \
	    python3 gen_coverage.py; \
	else \
	    echo "ERROR: coverage.dat not found"; exit 1; \
	fi
