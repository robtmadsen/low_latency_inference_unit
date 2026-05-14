TOPLEVEL_LANG = verilog
SIM            = verilator
TOPLEVEL       = kc705_top
MODULE         = test_kc705

RTL   = ../rtl
FOREN = /tmp/verilog-ethernet

VERILOG_SOURCES = \
    $(RTL)/lliu_pkg.sv \
    $(RTL)/axi4_lite_slave.sv \
    $(RTL)/bfloat16_mul.sv \
    $(RTL)/dot_product_engine.sv \
    $(RTL)/eth_axis_rx_wrap.sv \
    $(RTL)/feature_extractor_v2.sv \
    $(RTL)/fp32_acc.sv \
    $(RTL)/itch_field_extract.sv \
    $(RTL)/itch_parser_v2.sv \
    $(RTL)/latency_histogram.sv \
    $(RTL)/lliu_core.sv \
    $(RTL)/lliu_top_v2.sv \
    $(RTL)/moldupp64_strip.sv \
    $(RTL)/order_book.sv \
    $(RTL)/ouch_engine.sv \
    $(RTL)/output_buffer.sv \
    $(RTL)/pcie_dma_engine.sv \
    $(RTL)/ptp_core.sv \
    $(RTL)/risk_check.sv \
    $(RTL)/snapshot_mux.sv \
    $(RTL)/strategy_arbiter.sv \
    $(RTL)/symbol_filter.sv \
    $(RTL)/timestamp_tap.sv \
    $(RTL)/weight_mem.sv \
    $(RTL)/kc705_top.sv \
    $(FOREN)/rtl/eth_axis_rx.v \
    $(FOREN)/rtl/udp_complete_64.v \
    $(FOREN)/rtl/ip_complete_64.v \
    $(FOREN)/rtl/ip_64.v \
    $(FOREN)/rtl/ip_arb_mux.v \
    $(FOREN)/rtl/ip_eth_rx_64.v \
    $(FOREN)/rtl/ip_eth_tx_64.v \
    $(FOREN)/rtl/udp_64.v \
    $(FOREN)/rtl/udp_ip_rx_64.v \
    $(FOREN)/rtl/udp_ip_tx_64.v \
    $(FOREN)/rtl/udp_checksum_gen_64.v \
    $(FOREN)/rtl/arp.v \
    $(FOREN)/rtl/arp_cache.v \
    $(FOREN)/rtl/arp_eth_rx.v \
    $(FOREN)/rtl/arp_eth_tx.v \
    $(FOREN)/rtl/eth_arb_mux.v \
    $(FOREN)/rtl/lfsr.v \
    $(FOREN)/lib/axis/rtl/axis_async_fifo.v \
    $(FOREN)/lib/axis/rtl/arbiter.v \
    $(FOREN)/lib/axis/rtl/axis_fifo.v \
    $(FOREN)/lib/axis/rtl/priority_encoder.v

COMPILE_ARGS += -DKINTEX7_SIM_GTX_BYPASS
COMPILE_ARGS += --coverage-line
COMPILE_ARGS += -Wno-fatal
COMPILE_ARGS += --timing
COMPILE_ARGS += -j 0
COMPILE_ARGS += --x-initial unique
COMPILE_ARGS += --x-assign unique
COMPILE_ARGS += -Wno-WIDTHEXPAND
COMPILE_ARGS += -Wno-WIDTHTRUNC
COMPILE_ARGS += -Wno-CASEINCOMPLETE
COMPILE_ARGS += -Wno-UNOPTFLAT
COMPILE_ARGS += -Wno-UNSIGNED
COMPILE_ARGS += -Wno-UNUSEDSIGNAL
COMPILE_ARGS += -Wno-UNUSEDPARAM
COMPILE_ARGS += -Wno-PINCONNECTEMPTY
COMPILE_ARGS += -Wno-IMPORTSTAR
COMPILE_ARGS += -Wno-SYNCASYNCNET
COMPILE_ARGS += -Wno-BLKSEQ
COMPILE_ARGS += -Wno-MULTIDRIVEN
COMPILE_ARGS += -Wno-SELRANGE
COMPILE_ARGS += -Wno-PINMISSING

COCOTB_HDL_TIMEUNIT      = 1ps
COCOTB_HDL_TIMEPRECISION = 1ps

SIM_ARGS += +verilator+coverage+file+coverage.dat

include $(shell cocotb-config --makefiles)/Makefile.sim

.PHONY: test coverage

test: sim
	@echo "=== Generating coverage report ==="
	-verilator_coverage --annotate-all --annotate-min 1 --annotate coverage_ann/ coverage.dat 2>/dev/null
	-python3 gen_coverage.py
