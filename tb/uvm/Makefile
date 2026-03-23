# UVM Testbench Makefile for Low-Latency Inference Unit
#
# Targets:
#   make SIM=verilator compile — Compile with Verilator (open-source, CI-friendly)
#   make SIM=verilator run TEST=<test_name>
#   make SIM=vcs       compile — Compile with VCS (full SVA + constrained-random)
#   make SIM=vcs       run TEST=<test_name>
#   make SIM=questa    compile — Compile with Questa
#   make SIM=questa    run TEST=<test_name>
#
# Verilator 5.0+ supports SystemVerilog classes, virtual methods, and dynamic
# memory — sufficient for UVM testbenches. Set UVM_HOME to the Accellera UVM
# source tree (e.g. export UVM_HOME=/path/to/uvm-1.2/src).

# ---- Directories ----
TB_DIR     := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
PROJ_ROOT  := $(abspath $(TB_DIR)/../..)
RTL_DIR    := $(PROJ_ROOT)/rtl
DATA_DIR   := $(PROJ_ROOT)/data

# ---- Simulator selection ----
SIM       ?= verilator
TEST      ?= lliu_base_test
SEED      ?= random
VERBOSITY ?= UVM_MEDIUM

# ---- RTL source files (compile order matters: package first) ----
RTL_PKG   := $(RTL_DIR)/lliu_pkg.sv
RTL_SRC   := $(filter-out $(RTL_PKG), $(wildcard $(RTL_DIR)/*.sv))

# ---- UVM testbench files ----
TB_IFS    := $(TB_DIR)/axi4_stream_if.sv \
             $(TB_DIR)/axi4_lite_if.sv

TB_PKGS   := $(TB_DIR)/agents/axi4_stream_agent/axi4_stream_agent_pkg.sv \
             $(TB_DIR)/agents/axi4_lite_agent/axi4_lite_agent_pkg.sv \
             $(TB_DIR)/env/lliu_env_pkg.sv \
             $(TB_DIR)/sequences/lliu_seq_pkg.sv \
             $(TB_DIR)/tests/lliu_test_pkg.sv

TB_TOP    := $(TB_DIR)/tb_top.sv

# ---- SVA assertion bind modules ----
TB_SVA    := $(wildcard $(TB_DIR)/sva/*.sv)

# ---- DPI-C golden model ----
DPI_SRC   := $(TB_DIR)/golden_model/dpi_bridge.c
GM_PY     := $(TB_DIR)/golden_model/golden_model.py

# ---- Python configuration (for DPI-C) ----
PYTHON    ?= python3
PY_VER    := $(shell $(PYTHON) -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
PY_PREFIX := $(shell $(PYTHON) -c "import sys; print(sys.prefix)")
PY_CFLAGS := $(shell $(PYTHON)-config --cflags 2>/dev/null || echo "-I$(PY_PREFIX)/include/python$(PY_VER)")
PY_LDFLAGS:= $(shell $(PYTHON)-config --ldflags --embed 2>/dev/null || echo "-L$(PY_PREFIX)/lib -lpython$(PY_VER)")

# ---- Build directory ----
BUILD_DIR := $(TB_DIR)/sim_build/$(SIM)

# ---- All SV sources in compile order ----
ALL_SV    := $(RTL_PKG) $(RTL_SRC) $(TB_IFS) $(TB_PKGS) $(TB_SVA) $(TB_TOP)

# ==============================================================================
# VCS
# ==============================================================================
ifeq ($(SIM),vcs)

VCS       ?= vcs
VCS_FLAGS := -full64 -sverilog -ntb_opts uvm-1.2 \
             -timescale=1ns/1ps \
             +define+UVM_NO_DPI \
             -CFLAGS "$(PY_CFLAGS)" \
             -LDFLAGS "$(PY_LDFLAGS)" \
             +incdir+$(RTL_DIR) +incdir+$(TB_DIR) \
             -l $(BUILD_DIR)/compile.log

.PHONY: compile run clean help

compile: $(BUILD_DIR)
	$(VCS) $(VCS_FLAGS) $(ALL_SV) $(DPI_SRC) \
	    -o $(BUILD_DIR)/simv 2>&1 | tee $(BUILD_DIR)/compile.log

run: compile
	cd $(BUILD_DIR) && ./simv \
	    +UVM_TESTNAME=$(TEST) \
	    +UVM_VERBOSITY=$(VERBOSITY) \
	    +ntb_random_seed=$(SEED) \
	    +DATA_DIR=$(DATA_DIR) \
	    +GOLDEN_MODEL=$(GM_PY) \
	    -l $(TEST).log 2>&1 | tee $(TEST).log

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ==============================================================================
# Questa / ModelSim
# ==============================================================================
else ifeq ($(SIM),questa)

VLOG      ?= vlog
VSIM      ?= vsim
VLOG_FLAGS := -sv +incdir+$(RTL_DIR) +incdir+$(TB_DIR) \
              -timescale 1ns/1ps

.PHONY: compile run clean help

compile: $(BUILD_DIR)
	cd $(BUILD_DIR) && vlib work && \
	$(VLOG) $(VLOG_FLAGS) +define+UVM_NO_DPI $(ALL_SV) $(DPI_SRC) \
	    2>&1 | tee compile.log

run: compile
	cd $(BUILD_DIR) && $(VSIM) -c tb_top \
	    +UVM_TESTNAME=$(TEST) \
	    +UVM_VERBOSITY=$(VERBOSITY) \
	    +DATA_DIR=$(DATA_DIR) \
	    +GOLDEN_MODEL=$(GM_PY) \
	    -do "run -all; quit -f" \
	    -l $(TEST).log 2>&1 | tee $(TEST).log

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ==============================================================================
# Verilator (open-source, CI-friendly)
# ==============================================================================
else ifeq ($(SIM),verilator)

VERILATOR  ?= verilator
UVM_HOME   ?= $(error UVM_HOME is not set. Point it to the Accellera UVM source tree, e.g. /path/to/uvm-1.2/src)

# Verilator flags for UVM class-based testbench
VL_FLAGS   := --binary --timing --trace -sv \
              -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM \
              -Wno-UNUSEDSIGNAL -Wno-IMPORTSTAR -Wno-CONSTRAINTIGN \
              -Wno-MISINDENT -Wno-CASEINCOMPLETE \
              --timescale 1ns/1ps \
              +incdir+$(RTL_DIR) +incdir+$(TB_DIR) \
              +incdir+$(UVM_HOME) \
              +define+UVM_NO_DPI \
              -j 0 \
              -o simv

UVM_PKG    := $(UVM_HOME)/uvm_pkg.sv

# All SV sources in compile order: RTL, interfaces, packages, tb_top.
VL_SV      := $(RTL_PKG) $(RTL_SRC) $(TB_IFS) $(TB_PKGS) $(TB_SVA) $(TB_TOP)

.PHONY: compile run clean help

compile: $(BUILD_DIR)
	$(VERILATOR) $(VL_FLAGS) \
	    $(UVM_PKG) $(VL_SV) \
	    --Mdir $(BUILD_DIR) \
	    2>&1 | tee $(BUILD_DIR)/compile.log

run: compile
	$(BUILD_DIR)/simv \
	    +UVM_TESTNAME=$(TEST) \
	    +UVM_VERBOSITY=$(VERBOSITY) \
	    +DATA_DIR=$(DATA_DIR) \
	    +GOLDEN_MODEL=$(GM_PY) \
	    2>&1 | tee $(BUILD_DIR)/$(TEST).log

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

# ==============================================================================
# Unsupported simulator
# ==============================================================================
else

.PHONY: compile run
compile run:
	@echo "ERROR: SIM=$(SIM) is not supported."
	@echo "Supported simulators: verilator, vcs, questa"
	@exit 1

endif

# ==============================================================================
# Common targets
# ==============================================================================
.PHONY: clean help

clean:
	rm -rf $(TB_DIR)/sim_build

help:
	@echo "UVM Testbench for Low-Latency Inference Unit"
	@echo ""
	@echo "Usage:"
	@echo "  make SIM=verilator compile            Compile with Verilator (default)"
	@echo "  make SIM=verilator run TEST=<name>    Run test (default: lliu_base_test)"
	@echo "  make SIM=vcs       compile            Compile with VCS"
	@echo "  make SIM=vcs       run TEST=<name>    Run test"
	@echo "  make SIM=questa    compile            Compile with Questa"
	@echo "  make SIM=questa    run TEST=<name>    Run test"
	@echo "  make clean                            Remove build artifacts"
	@echo ""
	@echo "Available tests:"
	@echo "  lliu_base_test     — Base test (no stimulus, sanity check)"
	@echo "  lliu_smoke_test    — Single Add Order end-to-end"
	@echo "  lliu_replay_test   — Real NASDAQ ITCH data replay"
	@echo ""
	@echo "Options:"
	@echo "  SIM=<sim>             verilator (default), vcs, questa"
	@echo "  UVM_HOME=<path>       Path to UVM source (required for Verilator)"
	@echo "  SEED=<int|random>     Random seed (default: random)"
	@echo "  VERBOSITY=<level>     UVM_NONE|UVM_LOW|UVM_MEDIUM|UVM_HIGH|UVM_FULL"
	@echo ""
	@echo "Note: Verilator 5.0+ supports SV classes for UVM."
	@echo "      VCS/Questa additionally support full SVA and constrained-random."
