#!/usr/bin/env python3
"""Parse Verilator coverage output and print per-module line coverage."""

import os, re, sys

def parse_annotated(ann_dir="coverage_ann"):
    results = {}
    if not os.path.isdir(ann_dir):
        print(f"[coverage] {ann_dir}/ not found — skipping", file=sys.stderr)
        return results
    for fname in sorted(os.listdir(ann_dir)):
        if not fname.endswith(".sv") and not fname.endswith(".v"):
            continue
        total = hit = 0
        path = os.path.join(ann_dir, fname)
        with open(path) as f:
            for line in f:
                m = re.match(r"\s*(%\d+|\d+)\s", line)
                if m:
                    token = m.group(1)
                    if token.startswith("%"):
                        total += 1  # uncovered
                    else:
                        total += 1
                        hit += 1
        if total > 0:
            pct = 100.0 * hit / total
            results[fname] = (hit, total, pct)
    return results


DUT_MODULES = {
    "axi4_lite_slave.sv", "bfloat16_mul.sv", "dot_product_engine.sv",
    "eth_axis_rx_wrap.sv", "feature_extractor_v2.sv", "fp32_acc.sv",
    "itch_field_extract.sv", "itch_parser_v2.sv", "kc705_top.sv",
    "latency_histogram.sv", "lliu_core.sv", "lliu_pkg.sv", "lliu_top_v2.sv",
    "moldupp64_strip.sv", "order_book.sv", "ouch_engine.sv", "output_buffer.sv",
    "pcie_dma_engine.sv", "ptp_core.sv", "risk_check.sv", "snapshot_mux.sv",
    "strategy_arbiter.sv", "symbol_filter.sv", "timestamp_tap.sv", "weight_mem.sv",
}


def main():
    results = parse_annotated()
    if not results:
        print("[coverage] No annotated files found.")
        return

    def print_table(mods, title, fh=None):
        hdr = f"\n=== {title} ===\n"
        line = f"{'Module':<40s} {'Hit':>6s} {'Total':>6s} {'Pct':>7s}\n"
        sep = "-" * 62 + "\n"
        for dest in ([sys.stdout] if fh is None else [sys.stdout, fh]):
            dest.write(hdr)
            dest.write(line)
            dest.write(sep)
        t_hit = t_all = 0
        for mod in sorted(mods):
            if mod not in results:
                continue
            hit, total, pct = results[mod]
            t_hit += hit
            t_all += total
            row = f"{mod:<40s} {hit:>6d} {total:>6d} {pct:>6.1f}%\n"
            for dest in ([sys.stdout] if fh is None else [sys.stdout, fh]):
                dest.write(row)
        if t_all:
            overall = 100.0 * t_hit / t_all
            footer = sep + f"{'TOTAL':<40s} {t_hit:>6d} {t_all:>6d} {overall:>6.1f}%\n"
            for dest in ([sys.stdout] if fh is None else [sys.stdout, fh]):
                dest.write(footer)
        return t_hit, t_all

    dut_mods = {m for m in results if m in DUT_MODULES}
    ext_mods = {m for m in results if m not in DUT_MODULES}

    os.makedirs("reports", exist_ok=True)
    with open("reports/coverage.txt", "w") as f:
        dut_hit, dut_all = print_table(dut_mods, "DUT Modules (rtl/)", f)
        ext_hit, ext_all = print_table(ext_mods, "External Modules (verilog-ethernet)", f)
        all_hit = dut_hit + ext_hit
        all_all = dut_all + ext_all
        if all_all:
            summary = (
                f"\n=== Summary ===\n"
                f"DUT line coverage:      {dut_hit}/{dut_all} = {100.0*dut_hit/dut_all:.1f}%\n"
                f"External line coverage:  {ext_hit}/{ext_all} = {100.0*ext_hit/ext_all:.1f}%\n"
                f"Overall line coverage:   {all_hit}/{all_all} = {100.0*all_hit/all_all:.1f}%\n"
            )
            for dest in [sys.stdout, f]:
                dest.write(summary)


if __name__ == "__main__":
    main()
