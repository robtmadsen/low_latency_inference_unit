## Makefile — UVM testbench for itch_field_extract under Verilator
##
## Targets:
##   all   (default): compile the simulation binary
##   test           : run all UVM tests, generate coverage and reports
##   clean          : remove build artefacts

TB_DIR      := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
RTL_DIR     := $(TB_DIR)/../rtl
REPORTS_DIR := $(TB_DIR)/../reports
UVM_HOME    ?= /home/azureuser/uvm-core/src

VERILATOR := verilator

# Verilator flags. We compile UVM with UVM_NO_DPI to skip the DPI components
# that aren't supported under Verilator.
VFLAGS := \
    --binary \
    --timing \
    -sv \
    -j 0 \
    --x-assign 0 \
    --x-initial 0 \
    -CFLAGS "-O0 -fno-inline-functions -fno-inline-small-functions" \
    -LDFLAGS "-O0" \
    --coverage-line \
    -Wno-fatal \
    -Wno-WIDTH \
    -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC \
    -Wno-WIDTHCONCAT \
    -Wno-CASEINCOMPLETE \
    -Wno-CASEX \
    -Wno-LATCH \
    -Wno-UNUSED \
    -Wno-UNUSEDSIGNAL \
    -Wno-UNUSEDPARAM \
    -Wno-PINMISSING \
    -Wno-DECLFILENAME \
    -Wno-IMPLICIT \
    -Wno-IMPORTSTAR \
    -Wno-COMBDLY \
    -Wno-INITIALDLY \
    -Wno-NULLPORT \
    -Wno-MULTIDRIVEN \
    -Wno-PROCASSWIRE \
    -Wno-CONSTRAINTIGN \
    -Wno-VARHIDDEN \
    -Wno-MISINDENT \
    -Wno-ZERODLY \
    +incdir+$(UVM_HOME) \
    +incdir+$(UVM_HOME)/dpi \
    +define+UVM_NO_DPI \
    --top-module tb_top \
    -o Vtb_top

SOURCES := \
    $(UVM_HOME)/uvm_pkg.sv \
    $(RTL_DIR)/lliu_pkg.sv \
    $(RTL_DIR)/itch_field_extract.sv \
    $(TB_DIR)/itch_if.sv \
    $(TB_DIR)/itch_tb_pkg.sv \
    $(TB_DIR)/tb_top.sv

BUILD_DIR := $(TB_DIR)/obj_dir
EXE       := $(BUILD_DIR)/Vtb_top

TESTS := test_buy test_sell test_non_add_order test_reset test_back_to_back test_msg_valid_low

.PHONY: all build test clean

all: build

build: $(EXE)

$(EXE): $(SOURCES)
	@cd $(TB_DIR) && $(VERILATOR) $(VFLAGS) $(SOURCES)

test: build
	@mkdir -p $(REPORTS_DIR)
	@rm -f $(TB_DIR)/coverage.dat $(TB_DIR)/cov_*.dat
	@cd $(TB_DIR) && \
	pass=0; fail=0; failed_list=""; \
	for t in $(TESTS); do \
	    echo "=== Running $$t ==="; \
	    rm -f coverage.dat; \
	    ./obj_dir/Vtb_top +UVM_TESTNAME=$$t +UVM_NO_RELNOTES +UVM_VERBOSITY=UVM_LOW > test_$$t.log 2>&1; \
	    rc=$$?; \
	    if [ -f coverage.dat ]; then mv coverage.dat cov_$$t.dat; fi; \
	    if [ $$rc -eq 0 ] && grep -q "TEST PASSED" test_$$t.log && ! grep -q "TEST FAILED" test_$$t.log; then \
	        echo "  -> PASS"; pass=$$((pass+1)); \
	    else \
	        echo "  -> FAIL (rc=$$rc)"; \
	        tail -40 test_$$t.log; \
	        fail=$$((fail+1)); failed_list="$$failed_list $$t"; \
	    fi; \
	done; \
	echo ""; \
	echo "Total: $$((pass+fail))  Pass: $$pass  Fail: $$fail"; \
	if [ -n "$$failed_list" ]; then echo "Failed:$$failed_list"; fi; \
	echo "--- Generating coverage report ---"; \
	if ls cov_*.dat >/dev/null 2>&1; then \
	    verilator_coverage --write merged.dat cov_*.dat >/dev/null 2>&1 || true; \
	    verilator_coverage --write-info coverage.info merged.dat >/dev/null 2>&1 || true; \
	    rm -rf $(REPORTS_DIR)/cov_annot; \
	    verilator_coverage --annotate $(REPORTS_DIR)/cov_annot --annotate-all merged.dat >/dev/null 2>&1 || true; \
	    python3 $(TB_DIR)/cov_summary.py $(TB_DIR)/coverage.info $(REPORTS_DIR)/cov_annot itch_field_extract.sv $(REPORTS_DIR)/coverage.txt; \
	else \
	    echo "No coverage data produced" > $(REPORTS_DIR)/coverage.txt; \
	fi; \
	cat $(REPORTS_DIR)/coverage.txt; \
	[ $$fail -eq 0 ]

clean:
	rm -rf $(BUILD_DIR) $(TB_DIR)/coverage.dat $(TB_DIR)/cov_*.dat $(TB_DIR)/merged.dat $(TB_DIR)/test_*.log
