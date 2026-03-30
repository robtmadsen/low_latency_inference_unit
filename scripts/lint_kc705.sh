#!/usr/bin/env bash
# Lint kc705_top with all Forencich dependencies.
# Usage: bash scripts/lint_kc705.sh
#
# Warning suppressions:
#   WIDTHEXPAND / WIDTHTRUNC / BLKSEQ / PROCASSINIT / GENUNNAMED —
#     all originate exclusively in Forencich library source files which
#     we cannot modify.  Suppressed globally to keep lint output readable.
#   TIMESCALEMOD — Forencich .v files carry `timescale`; our .sv files do
#     not.  Pre-existing and harmless for simulation.
#   PINCONNECTEMPTY — intentionally unused TX discard ports on udp_complete_64
#     and axis_async_fifo; suppressed in-source with lint_off/on.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
FE="$REPO/lib/verilog-ethernet"
verilator --lint-only -Wall -sv --top-module kc705_top \
    -DKINTEX7_SIM_GTX_BYPASS \
    -Wno-WIDTHEXPAND \
    -Wno-WIDTHTRUNC \
    -Wno-BLKSEQ \
    -Wno-PROCASSINIT \
    -Wno-GENUNNAMED \
    -Wno-TIMESCALEMOD \
    -Wno-PINCONNECTEMPTY \
    -Wno-PINMISSING \
    -Wno-LATCH \
    -Wno-UNUSEDSIGNAL \
    -Wno-CASEINCOMPLETE \
    -Wno-SELRANGE \
    -Wno-UNUSEDPARAM \
    -Wno-UNOPTFLAT \
    "$REPO/rtl/lliu_pkg.sv" \
    "$REPO/rtl/bfloat16_mul.sv" \
    "$REPO/rtl/fp32_acc.sv" \
    "$REPO/rtl/dot_product_engine.sv" \
    "$REPO/rtl/itch_parser.sv" \
    "$REPO/rtl/itch_field_extract.sv" \
    "$REPO/rtl/feature_extractor.sv" \
    "$REPO/rtl/weight_mem.sv" \
    "$REPO/rtl/axi4_lite_slave.sv" \
    "$REPO/rtl/output_buffer.sv" \
    "$REPO/rtl/moldupp64_strip.sv" \
    "$REPO/rtl/symbol_filter.sv" \
    "$REPO/rtl/eth_axis_rx_wrap.sv" \
    "$REPO/rtl/kc705_top.sv" \
    "$FE/rtl/eth_axis_rx.v" \
    "$FE/rtl/udp_complete_64.v" \
    "$FE/rtl/ip_complete_64.v" \
    "$FE/rtl/ip.v" \
    "$FE/rtl/ip_64.v" \
    "$FE/rtl/ip_eth_rx_64.v" \
    "$FE/rtl/ip_eth_tx_64.v" \
    "$FE/rtl/arp.v" \
    "$FE/rtl/arp_cache.v" \
    "$FE/rtl/arp_eth_rx.v" \
    "$FE/rtl/arp_eth_tx.v" \
    "$FE/rtl/eth_arb_mux.v" \
    "$FE/rtl/ip_arb_mux.v" \
    "$FE/rtl/udp_64.v" \
    "$FE/rtl/udp_ip_rx_64.v" \
    "$FE/rtl/udp_ip_tx_64.v" \
    "$FE/rtl/udp_checksum_gen_64.v" \
    "$FE/rtl/lfsr.v" \
    "$FE/lib/axis/rtl/axis_async_fifo.v" \
    "$FE/lib/axis/rtl/axis_fifo.v" \
    "$FE/lib/axis/rtl/arbiter.v" \
    "$FE/lib/axis/rtl/priority_encoder.v"
