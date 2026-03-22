# Makefile — LLIU top-level build targets
#
# Usage:
#   make lint          — Verilator lint (full hierarchy)
#   make lint-module M=<module>  — Lint a single module
#   make clean         — Remove build artifacts

VERILATOR    ?= verilator
RTL_DIR      := rtl
LINT_FLAGS   := --lint-only -Wall -Wno-IMPORTSTAR -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

# All RTL sources in dependency order
RTL_SRCS := \
	$(RTL_DIR)/lliu_pkg.sv \
	$(RTL_DIR)/bfloat16_mul.sv \
	$(RTL_DIR)/fp32_acc.sv \
	$(RTL_DIR)/dot_product_engine.sv \
	$(RTL_DIR)/weight_mem.sv \
	$(RTL_DIR)/output_buffer.sv \
	$(RTL_DIR)/itch_field_extract.sv \
	$(RTL_DIR)/itch_parser.sv \
	$(RTL_DIR)/feature_extractor.sv \
	$(RTL_DIR)/axi4_lite_slave.sv \
	$(RTL_DIR)/lliu_top.sv

.PHONY: lint lint-module clean

# Lint full hierarchy
lint:
	$(VERILATOR) $(LINT_FLAGS) --top-module lliu_top -I$(RTL_DIR) $(RTL_SRCS)

# Lint a single module: make lint-module M=feature_extractor
lint-module:
	$(VERILATOR) $(LINT_FLAGS) --top-module $(M) -I$(RTL_DIR) $(RTL_DIR)/lliu_pkg.sv $(RTL_DIR)/$(M).sv

clean:
	rm -rf obj_dir
