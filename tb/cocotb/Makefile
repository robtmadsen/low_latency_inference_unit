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
else ifeq ($(TOPLEVEL),feature_extractor)
    VERILOG_SOURCES += $(RTL_DIR)/feature_extractor.sv
else ifeq ($(TOPLEVEL),axi4_lite_slave)
    VERILOG_SOURCES += $(RTL_DIR)/axi4_lite_slave.sv
else ifeq ($(TOPLEVEL),lliu_top)
    VERILOG_SOURCES += $(shell find $(RTL_DIR) -name '*.sv' ! -name 'lliu_pkg.sv')
else ifeq ($(TOPLEVEL),moldupp64_strip)
    VERILOG_SOURCES += $(RTL_DIR)/moldupp64_strip.sv
else ifeq ($(TOPLEVEL),symbol_filter)
    VERILOG_SOURCES += $(RTL_DIR)/symbol_filter.sv
else ifeq ($(TOPLEVEL),itch_parser_v2)
    VERILOG_SOURCES += $(RTL_DIR)/itch_parser_v2.sv
else ifeq ($(TOPLEVEL),order_book)
    VERILOG_SOURCES += $(RTL_DIR)/order_book.sv
    EXTRA_ARGS += -Wno-MULTIDRIVEN
else ifeq ($(TOPLEVEL),ptp_core)
    VERILOG_SOURCES += $(RTL_DIR)/ptp_core.sv
else ifeq ($(TOPLEVEL),timestamp_tap)
    VERILOG_SOURCES += $(RTL_DIR)/timestamp_tap.sv
else ifeq ($(TOPLEVEL),latency_histogram)
    VERILOG_SOURCES += $(RTL_DIR)/latency_histogram.sv
else ifeq ($(TOPLEVEL),eth_axis_rx_wrap)
    VERILOG_SOURCES += $(RTL_DIR)/eth_axis_rx_wrap.sv
    # eth_axis_rx_wrap instantiates Forencich eth_axis_rx internally
    FE_DIR := $(PWD)/../../lib/verilog-ethernet
    VERILOG_SOURCES += $(FE_DIR)/rtl/eth_axis_rx.v
    # Suppress width warnings from third-party library
    EXTRA_ARGS += -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-TIMESCALEMOD -Wno-GENUNNAMED
else ifeq ($(TOPLEVEL),kc705_top)
    VERILOG_SOURCES += $(RTL_DIR)/bfloat16_mul.sv
    VERILOG_SOURCES += $(RTL_DIR)/fp32_acc.sv
    VERILOG_SOURCES += $(RTL_DIR)/dot_product_engine.sv
    VERILOG_SOURCES += $(RTL_DIR)/itch_field_extract.sv
    VERILOG_SOURCES += $(RTL_DIR)/itch_parser.sv
    VERILOG_SOURCES += $(RTL_DIR)/feature_extractor.sv
    VERILOG_SOURCES += $(RTL_DIR)/weight_mem.sv
    VERILOG_SOURCES += $(RTL_DIR)/axi4_lite_slave.sv
    VERILOG_SOURCES += $(RTL_DIR)/output_buffer.sv
    VERILOG_SOURCES += $(RTL_DIR)/moldupp64_strip.sv
    VERILOG_SOURCES += $(RTL_DIR)/symbol_filter.sv
    VERILOG_SOURCES += $(RTL_DIR)/eth_axis_rx_wrap.sv
    VERILOG_SOURCES += $(RTL_DIR)/kc705_top.sv
    # Forencich verilog-ethernet library — required by kc705_top sim path
    FE_DIR := $(PWD)/../../lib/verilog-ethernet
    VERILOG_SOURCES += $(FE_DIR)/rtl/eth_axis_rx.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/udp_complete_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/ip_complete_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/ip.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/ip_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/ip_eth_rx_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/ip_eth_tx_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/arp.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/arp_cache.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/arp_eth_rx.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/arp_eth_tx.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/eth_arb_mux.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/ip_arb_mux.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/udp_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/udp_ip_rx_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/udp_ip_tx_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/udp_checksum_gen_64.v
    VERILOG_SOURCES += $(FE_DIR)/rtl/lfsr.v
    VERILOG_SOURCES += $(FE_DIR)/lib/axis/rtl/axis_async_fifo.v
    VERILOG_SOURCES += $(FE_DIR)/lib/axis/rtl/axis_fifo.v
    VERILOG_SOURCES += $(FE_DIR)/lib/axis/rtl/arbiter.v
    VERILOG_SOURCES += $(FE_DIR)/lib/axis/rtl/priority_encoder.v
    EXTRA_ARGS += -DKINTEX7_SIM_GTX_BYPASS
    EXTRA_ARGS += -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-BLKSEQ -Wno-PROCASSINIT
    EXTRA_ARGS += -Wno-GENUNNAMED -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-LATCH
    EXTRA_ARGS += -Wno-CASEINCOMPLETE -Wno-SELRANGE -Wno-UNOPTFLAT
endif

# Test module lives in tests/
COCOTB_TEST_MODULES = tests.$(TEST_MODULE)

# Verilator extra args
EXTRA_ARGS += --trace
EXTRA_ARGS += -Wno-IMPORTSTAR -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

# Coverage: enable with VL_COVERAGE=1 (not COVERAGE — that's cocotb Python coverage)
ifeq ($(VL_COVERAGE),1)
EXTRA_ARGS += --coverage
endif

# cocotb Makefile.sim
include $(shell cocotb-config --makefiles)/Makefile.sim

# ---- Coverage collection targets ----
COV_DIR    := $(PWD)/coverage_data
COV_TESTS  := \
	bfloat16_mul:test_bfloat16_mul \
	fp32_acc:test_fp32_acc \
	dot_product_engine:test_dot_product_engine \
	itch_parser:test_parser \
	feature_extractor:test_feature_extractor \
	lliu_top:test_smoke \
	lliu_top:test_constrained_random \
	lliu_top:test_backpressure \
	lliu_top:test_latency \
	lliu_top:test_error_injection \
	lliu_top:test_replay \
	itch_parser:test_parser_edge \
	feature_extractor:test_feat_edge \
	bfloat16_mul:test_bf16_mul_edge \
	fp32_acc:test_fp32_acc_edge \
	axi4_lite_slave:test_axil_regmap \
	lliu_top:test_wgtmem_outbuf \
	lliu_top:test_integration_sweep \
	order_book:test_order_book \
	order_book:test_order_book_collision \
	ptp_core:test_ptp \
	latency_histogram:test_histogram

.PHONY: coverage-run coverage-merge coverage-report coverage-clean

coverage-clean:
	rm -rf $(COV_DIR)
	mkdir -p $(COV_DIR)

coverage-run: coverage-clean
	@for spec in $(COV_TESTS); do \
		top=$$(echo $$spec | cut -d: -f1); \
		mod=$$(echo $$spec | cut -d: -f2); \
		echo "==== Running $$top / $$mod ===="; \
		rm -rf sim_build; \
		$(MAKE) SIM=verilator TOPLEVEL=$$top TEST_MODULE=$$mod VL_COVERAGE=1 || true; \
		if [ -f coverage.dat ]; then \
			cp coverage.dat $(COV_DIR)/$${top}__$${mod}.dat; \
		fi; \
	done

coverage-merge:
	@mkdir -p $(COV_DIR)
	verilator_coverage --write $(COV_DIR)/merged.dat \
		$$(find $(COV_DIR) -name '*.dat' ! -name 'merged.dat' | sort)

coverage-report: coverage-merge
	@mkdir -p $(COV_DIR)/annotate
	verilator_coverage --annotate $(COV_DIR)/annotate \
		--annotate-min 1 $(COV_DIR)/merged.dat
	@echo "Coverage report written to $(COV_DIR)/annotate/"
