# Cocotb + Verilator testbench for itch_field_extract.
#
# Usage:
#   make            -> compile + run all tests + emit coverage report
#   make test       -> alias for default
#   make clean      -> remove sim_build/ and the generated coverage report
#
# All make/sim invocations should be wrapped with `timeout 300` by the caller
# (per task instructions) so a hung simulator cannot stall the session.

# Make sure cocotb-config (installed under ~/.local/bin via pip --user) is
# discoverable even when invoked without the user's interactive PATH. We
# both inline-prepend it for $(shell ...) calls below and export it for the
# child verilator process and the included cocotb makefiles.
LOCAL_BIN := $(HOME)/.local/bin
PATH := $(LOCAL_BIN):$(PATH)
export PATH

SIM            ?= verilator
TOPLEVEL_LANG  ?= verilog

# Repo paths
TB_DIR    := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))
REPO_ROOT := $(abspath $(TB_DIR)/..)
RTL_DIR   := $(REPO_ROOT)/rtl
REPORT_DIR := $(REPO_ROOT)/reports

VERILOG_SOURCES := \
    $(RTL_DIR)/lliu_pkg.sv \
    $(RTL_DIR)/itch_field_extract.sv

TOPLEVEL := itch_field_extract
MODULE   := test_itch_field_extract

# Verilator flags:
#   --coverage      enable line/toggle/branch coverage collection
#   --trace         VCD waves (handy when debugging a failure)
EXTRA_ARGS += --coverage --trace -Wall -Wno-DECLFILENAME -Wno-UNUSEDPARAM

# Make python find the local reference_model / scoreboard modules.
export PYTHONPATH := $(TB_DIR):$(PYTHONPATH)

# Verilator writes coverage.dat to the current working directory of the
# simulator process. cocotb invokes the simulator from $(TB_DIR), so the
# raw coverage data lands in $(TB_DIR)/coverage.dat (NOT inside sim_build/).
COVERAGE_DAT := $(TB_DIR)/coverage.dat

COCOTB_MAKEFILES := $(shell PATH="$(LOCAL_BIN):$$PATH" cocotb-config --makefiles)
include $(COCOTB_MAKEFILES)/Makefile.sim

# After the simulation runs, post-process coverage.dat into reports/coverage.txt.
.PHONY: coverage_report
coverage_report:
	@mkdir -p $(REPORT_DIR)
	@if [ -f $(COVERAGE_DAT) ]; then \
		rm -rf $(REPORT_DIR)/coverage_annotate; \
		verilator_coverage --annotate $(REPORT_DIR)/coverage_annotate \
		    --annotate-all $(COVERAGE_DAT) > $(REPORT_DIR)/coverage_summary.txt 2>&1 || true; \
		python3 $(TB_DIR)/gen_coverage_report.py \
		    $(COVERAGE_DAT) \
		    $(REPORT_DIR)/coverage_annotate \
		    $(REPORT_DIR)/coverage.txt; \
	else \
		echo "ERROR: coverage.dat not found at $(COVERAGE_DAT)" \
		     > $(REPORT_DIR)/coverage.txt; \
		exit 1; \
	fi

# Emit the coverage report after every simulation run.
all: coverage_report

# Convenience alias used by the task instructions: `make -C tb test`.
.PHONY: test
test: all

# Clean wider than the cocotb default so we don't carry stale state.
clean::
	@rm -rf sim_build $(COVERAGE_DAT) dump.vcd \
	        $(REPORT_DIR)/coverage.txt $(REPORT_DIR)/coverage_annotate \
	        $(REPORT_DIR)/coverage_summary.txt
