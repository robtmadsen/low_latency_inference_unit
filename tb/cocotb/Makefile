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
endif

# Test module lives in tests/
MODULE = tests.$(TEST_MODULE)

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
	lliu_top:test_integration_sweep

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
		$(MAKE) SIM=verilator TOPLEVEL=$$top MODULE=tests.$$mod VL_COVERAGE=1 || true; \
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
