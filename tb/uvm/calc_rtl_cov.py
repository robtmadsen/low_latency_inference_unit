#!/usr/bin/env python3
"""Calculate RTL-only coverage from Verilator annotated files."""
import os, re, sys

rtl_mods = [
    'axi4_lite_slave.sv','bfloat16_mul.sv','dot_product_engine.sv','eth_axis_rx_wrap.sv',
    'feature_extractor_v2.sv','fp32_acc.sv','itch_field_extract.sv','itch_parser_v2.sv',
    'kc705_top.sv','latency_histogram.sv','lliu_core.sv','lliu_top_v2.sv','moldupp64_strip.sv',
    'order_book.sv','ouch_engine.sv','output_buffer.sv','pcie_dma_engine.sv','ptp_core.sv',
    'risk_check.sv','snapshot_mux.sv','strategy_arbiter.sv','symbol_filter.sv',
    'timestamp_tap.sv','weight_mem.sv'
]

adir = sys.argv[1] if len(sys.argv) > 1 else '../reports/annotate'
tc = 0
tt = 0

print("\n=== RTL-only line coverage (excluding UVM library) ===")
for m in rtl_mods:
    p = os.path.join(adir, m)
    c = 0
    u = 0
    if os.path.exists(p):
        with open(p) as f:
            for l in f:
                match = re.match(r'\s*[~]?(\d{6})\s+', l)
                if match:
                    if int(match.group(1)) > 0:
                        c += 1
                    else:
                        u += 1
    t = c + u
    tc += c
    tt += t
    pct = f'{c/t*100:.1f}%' if t else 'n/a'
    print(f'  {m:<32} {c:>5}/{t:<5} {pct}')

pct = f'{tc/tt*100:.1f}%' if tt else '0%'
print(f'  {"RTL TOTAL":<32} {tc:>5}/{tt:<5} {pct}')
