SIM = verilator
TOPLEVEL_LANG = verilog

VERILOG_SOURCES = $(CURDIR)/../rtl/lliu_pkg.sv $(CURDIR)/../rtl/itch_field_extract.sv

TOPLEVEL = itch_field_extract
MODULE = test_itch_field_extract

COMPILE_ARGS += --coverage
COMPILE_ARGS += -Wno-IMPORTSTAR

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: test
test:
	rm -f results.xml
	$(MAKE) results.xml
	@mkdir -p ../reports
	python3 gen_coverage_report.py
