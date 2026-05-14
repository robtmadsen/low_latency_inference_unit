SHELL := /bin/bash

RTL_DIR   := ../rtl
STUB_DIR  := stubs
RPT_DIR   := ../reports
UVM_HOME  ?= /home/azureuser/uvm-core/src

RTL_SRCS  := $(RTL_DIR)/lliu_pkg.sv \
             $(RTL_DIR)/bfloat16_mul.sv \
             $(RTL_DIR)/fp32_acc.sv \
             $(RTL_DIR)/weight_mem.sv \
             $(RTL_DIR)/dot_product_engine.sv \
             $(RTL_DIR)/output_buffer.sv \
             $(RTL_DIR)/lliu_core.sv \
             $(RTL_DIR)/itch_parser_v2.sv \
             $(RTL_DIR)/itch_field_extract.sv \
             $(RTL_DIR)/moldupp64_strip.sv \
             $(RTL_DIR)/eth_axis_rx_wrap.sv \
             $(RTL_DIR)/symbol_filter.sv \
             $(RTL_DIR)/order_book.sv \
             $(RTL_DIR)/feature_extractor_v2.sv \
             $(RTL_DIR)/strategy_arbiter.sv \
             $(RTL_DIR)/risk_check.sv \
             $(RTL_DIR)/ouch_engine.sv \
             $(RTL_DIR)/ptp_core.sv \
             $(RTL_DIR)/timestamp_tap.sv \
             $(RTL_DIR)/latency_histogram.sv \
             $(RTL_DIR)/snapshot_mux.sv \
             $(RTL_DIR)/pcie_dma_engine.sv \
             $(RTL_DIR)/axi4_lite_slave.sv \
             $(RTL_DIR)/lliu_top_v2.sv \
             $(RTL_DIR)/kc705_top.sv

STUB_SRCS := $(STUB_DIR)/axis_async_fifo.sv \
             $(STUB_DIR)/eth_axis_rx.sv \
             $(STUB_DIR)/udp_complete_64.sv

TB_SRCS   := tb_top.sv

VERILATOR := verilator
VFLAGS    := --binary \
             --timing \
             -j 0 \
             --coverage-line \
             +define+KINTEX7_SIM_GTX_BYPASS \
             --x-initial unique \
             --x-assign unique \
             -Wno-UNUSEDSIGNAL \
             -Wno-UNDRIVEN \
             -Wno-UNUSEDPARAM \
             -Wno-WIDTHEXPAND \
             -Wno-WIDTHTRUNC \
             -Wno-CASEINCOMPLETE \
             -Wno-UNSIGNED \
             -Wno-IMPORTSTAR \
             -Wno-BLKSEQ \
             -Wno-PINMISSING \
             -Wno-MULTIDRIVEN \
             -Wno-INITIALDLY \
             -Wno-SYNCASYNCNET \
             -Wno-MULTITOP \
             -Wno-PINCONNECTEMPTY \
             -Wno-TIMESCALEMOD \
             -Wno-EOFNEWLINE \
             --top-module tb_top \
             --Mdir obj_dir

SIM_BIN   := obj_dir/Vtb_top

.PHONY: all build test clean coverage

all: build

build:
	@echo "=== Building with Verilator ==="
	$(VERILATOR) $(VFLAGS) $(RTL_SRCS) $(STUB_SRCS) $(TB_SRCS) 2>&1

test: build
	@echo "=== Running simulation ==="
	@mkdir -p $(RPT_DIR)
	$(SIM_BIN) +verilator+coverage+file+$(RPT_DIR)/coverage.dat 2>&1 | tee $(RPT_DIR)/sim.log
	@echo "=== Generating coverage report ==="
	verilator_coverage --annotate $(RPT_DIR)/annotate $(RPT_DIR)/coverage.dat 2>&1 || true
	verilator_coverage --write-info $(RPT_DIR)/coverage.info $(RPT_DIR)/coverage.dat 2>&1 || true
	@echo "=== Coverage summary ===" | tee $(RPT_DIR)/coverage.txt
	verilator_coverage $(RPT_DIR)/coverage.dat 2>&1 | tee -a $(RPT_DIR)/coverage.txt || true
	@echo "=== Done ==="

coverage: test
	@echo "Coverage report written to $(RPT_DIR)/coverage.txt"

clean:
	rm -rf obj_dir $(RPT_DIR)/coverage.dat $(RPT_DIR)/annotate $(RPT_DIR)/sim.log
