# Makefile for HFT SoC UVM Testbench (Verilator 5.046)
SHELL := /bin/bash

UVM_HOME    ?= /home/azureuser/uvm-core/src
RTL_DIR     := ../rtl
TB_DIR      := .
REPORT_DIR  := ../reports
OBJ_DIR     := obj_dir

VERILATOR   := verilator

RTL_SRCS := \
    $(RTL_DIR)/lliu_pkg.sv \
    $(RTL_DIR)/ptp_core.sv \
    $(RTL_DIR)/timestamp_tap.sv \
    $(RTL_DIR)/bfloat16_mul.sv \
    $(RTL_DIR)/fp32_acc.sv \
    $(RTL_DIR)/weight_mem.sv \
    $(RTL_DIR)/dot_product_engine.sv \
    $(RTL_DIR)/output_buffer.sv \
    $(RTL_DIR)/lliu_core.sv \
    $(RTL_DIR)/feature_extractor_v2.sv \
    $(RTL_DIR)/itch_parser_v2.sv \
    $(RTL_DIR)/itch_field_extract.sv \
    $(RTL_DIR)/symbol_filter.sv \
    $(RTL_DIR)/order_book.sv \
    $(RTL_DIR)/strategy_arbiter.sv \
    $(RTL_DIR)/risk_check.sv \
    $(RTL_DIR)/ouch_engine.sv \
    $(RTL_DIR)/latency_histogram.sv \
    $(RTL_DIR)/snapshot_mux.sv \
    $(RTL_DIR)/axi4_lite_slave.sv \
    $(RTL_DIR)/lliu_top_v2.sv \
    $(RTL_DIR)/eth_axis_rx_wrap.sv \
    $(RTL_DIR)/moldupp64_strip.sv \
    $(RTL_DIR)/pcie_dma_engine.sv \
    $(RTL_DIR)/kc705_top.sv

STUB_SRCS := \
    $(TB_DIR)/eth_axis_rx.sv \
    $(TB_DIR)/udp_complete_64.sv \
    $(TB_DIR)/axis_async_fifo.sv

TB_SRCS := \
    $(TB_DIR)/tb_top.sv

VFLAGS := \
    --binary \
    --timing \
    --coverage \
    -DKINTEX7_SIM_GTX_BYPASS \
    +define+UVM_NO_DPI \
    +define+UVM_REGEX_NO_DPI \
    +define+UVM_NO_RELNOTES \
    +incdir+$(UVM_HOME) \
    -CFLAGS "-std=c++17 -DVL_TIME_CONTEXT" \
    -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC \
    -Wno-UNUSEDSIGNAL \
    -Wno-UNUSEDPARAM \
    -Wno-UNDRIVEN \
    -Wno-PINCONNECTEMPTY \
    -Wno-IMPORTSTAR \
    -Wno-ENUMVALUE \
    -Wno-CASEINCOMPLETE \
    -Wno-UNSIGNED \
    -Wno-CMPCONST \
    -Wno-MULTIDRIVEN \
    -Wno-BLKANDNBLK \
    -Wno-SYNCASYNCNET \
    -Wno-UNOPTFLAT \
    -Wno-INITIALDLY \
    -Wno-TIMESCALEMOD \
    -Wno-MULTITOP \
    -Wno-DEFOVERRIDE \
    --top-module tb_top \
    --x-initial unique \
    --x-assign unique \
    -j $(shell nproc)

.PHONY: all build test clean

all: build

build:
	@mkdir -p $(OBJ_DIR) $(REPORT_DIR)
	$(VERILATOR) $(VFLAGS) \
	    $(UVM_HOME)/uvm_pkg.sv \
	    $(RTL_SRCS) \
	    $(STUB_SRCS) \
	    $(TB_SRCS) \
	    -o Vtb_top 2>&1 | tee $(REPORT_DIR)/build.log
	@echo "Build complete"

test: build
	@mkdir -p $(REPORT_DIR)
	cd $(OBJ_DIR) && ./Vtb_top +UVM_TESTNAME=hft_base_test +UVM_VERBOSITY=UVM_MEDIUM 2>&1 | tee ../$(REPORT_DIR)/sim.log
	@echo "=== Extracting coverage ==="
	@if [ -d $(OBJ_DIR)/coverage.dat ] || [ -f $(OBJ_DIR)/coverage.dat ]; then \
	    verilator_coverage --annotate-min 1 --annotate $(REPORT_DIR)/annotate $(OBJ_DIR)/coverage.dat 2>&1 | tee $(REPORT_DIR)/coverage.txt; \
	elif ls $(OBJ_DIR)/*.dat 2>/dev/null; then \
	    verilator_coverage --annotate-min 1 --annotate $(REPORT_DIR)/annotate $$(ls $(OBJ_DIR)/*.dat | head -1) 2>&1 | tee $(REPORT_DIR)/coverage.txt; \
	else \
	    echo "No coverage data found" > $(REPORT_DIR)/coverage.txt; \
	fi
	@python3 $(TB_DIR)/calc_rtl_cov.py $(REPORT_DIR)/annotate >> $(REPORT_DIR)/coverage.txt 2>&1
	@echo "Test complete. See $(REPORT_DIR)/sim.log"

clean:
	rm -rf $(OBJ_DIR) $(REPORT_DIR)/annotate
