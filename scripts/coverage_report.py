#!/usr/bin/env python3
"""Parse Verilator LCOV .info files and produce a Markdown coverage report.

Usage:
    python3 scripts/coverage_report.py \
        --cocotb tb/cocotb/coverage_data/cocotb.info \
        --uvm    tb/uvm/coverage_data/uvm.info \
        --out    reports/coverage_baseline.md

Only DUT RTL files (under rtl/) are included in the report.
"""

import argparse
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path


@dataclass
class FileCov:
    """Coverage counters for a single source file."""
    lines_hit: int = 0
    lines_total: int = 0
    branches_hit: int = 0
    branches_total: int = 0

    @property
    def line_pct(self) -> float:
        return 100.0 * self.lines_hit / self.lines_total if self.lines_total else 0.0

    @property
    def branch_pct(self) -> float:
        return 100.0 * self.branches_hit / self.branches_total if self.branches_total else 0.0

    def __iadd__(self, other: "FileCov") -> "FileCov":
        self.lines_hit += other.lines_hit
        self.lines_total += other.lines_total
        self.branches_hit += other.branches_hit
        self.branches_total += other.branches_total
        return self


def parse_lcov(info_path: str, rtl_dir: str) -> dict[str, FileCov]:
    """Parse an LCOV .info file. Return {basename: FileCov} for RTL files only."""
    results: dict[str, FileCov] = {}
    current: FileCov | None = None
    current_name: str | None = None

    with open(info_path) as f:
        for raw_line in f:
            line = raw_line.strip()
            if line.startswith("SF:"):
                # Resolve to absolute, then check if it's under rtl/
                sf_path = os.path.realpath(line[3:])
                rtl_abs = os.path.realpath(rtl_dir)
                if sf_path.startswith(rtl_abs):
                    current_name = os.path.basename(sf_path)
                    current = results.setdefault(current_name, FileCov())
                else:
                    current = None
                    current_name = None
            elif line == "end_of_record":
                current = None
                current_name = None
            elif current is None:
                continue
            elif line.startswith("DA:"):
                # DA:line_no,exec_count
                parts = line[3:].split(",")
                if len(parts) >= 2:
                    current.lines_total += 1
                    if int(parts[1]) > 0:
                        current.lines_hit += 1
            elif line.startswith("BRDA:"):
                # BRDA:line,block,branch,count
                parts = line[5:].split(",")
                if len(parts) >= 4:
                    current.branches_total += 1
                    try:
                        if int(parts[3]) > 0:
                            current.branches_hit += 1
                    except ValueError:
                        pass  # '-' means not taken

    return results


def fmt_pct(val: float) -> str:
    return f"{val:.1f}%"


def generate_report(
    cocotb_data: dict[str, FileCov],
    uvm_data: dict[str, FileCov],
) -> str:
    """Generate a Markdown coverage baseline report."""
    lines: list[str] = []

    lines.append("# Coverage Baseline Report")
    lines.append("")
    lines.append("Baseline structural coverage from existing test suites — no new tests added.")
    lines.append("Coverage collected with Verilator `--coverage` (line + toggle + branch).")
    lines.append("")
    lines.append("> **Note:** Verilator merges toggle coverage into branch counts.")
    lines.append("> The \"Branch\" column below includes both branch and toggle coverage points.")
    lines.append("")

    # Collect all module names
    all_modules = sorted(set(list(cocotb_data.keys()) + list(uvm_data.keys())))

    # --- Per-module table ---
    lines.append("## Per-Module Coverage")
    lines.append("")
    lines.append("| Module | cocotb Line | cocotb Branch | UVM Line | UVM Branch |")
    lines.append("|--------|-------------|---------------|----------|------------|")

    cocotb_total = FileCov()
    uvm_total = FileCov()

    for mod in all_modules:
        cc = cocotb_data.get(mod, FileCov())
        uv = uvm_data.get(mod, FileCov())
        cocotb_total += FileCov(cc.lines_hit, cc.lines_total, cc.branches_hit, cc.branches_total)
        uvm_total += FileCov(uv.lines_hit, uv.lines_total, uv.branches_hit, uv.branches_total)

        cc_line = f"{fmt_pct(cc.line_pct)} ({cc.lines_hit}/{cc.lines_total})" if cc.lines_total else "—"
        cc_br = f"{fmt_pct(cc.branch_pct)} ({cc.branches_hit}/{cc.branches_total})" if cc.branches_total else "—"
        uv_line = f"{fmt_pct(uv.line_pct)} ({uv.lines_hit}/{uv.lines_total})" if uv.lines_total else "—"
        uv_br = f"{fmt_pct(uv.branch_pct)} ({uv.branches_hit}/{uv.branches_total})" if uv.branches_total else "—"

        lines.append(f"| {mod} | {cc_line} | {cc_br} | {uv_line} | {uv_br} |")

    # Totals row
    cc_line_t = f"**{fmt_pct(cocotb_total.line_pct)}** ({cocotb_total.lines_hit}/{cocotb_total.lines_total})"
    cc_br_t = f"**{fmt_pct(cocotb_total.branch_pct)}** ({cocotb_total.branches_hit}/{cocotb_total.branches_total})"
    uv_line_t = f"**{fmt_pct(uvm_total.line_pct)}** ({uvm_total.lines_hit}/{uvm_total.lines_total})"
    uv_br_t = f"**{fmt_pct(uvm_total.branch_pct)}** ({uvm_total.branches_hit}/{uvm_total.branches_total})"
    lines.append(f"| **TOTAL** | {cc_line_t} | {cc_br_t} | {uv_line_t} | {uv_br_t} |")
    lines.append("")

    # --- Gap analysis ---
    lines.append("## Gap Analysis")
    lines.append("")

    for framework, data in [("cocotb", cocotb_data), ("UVM", uvm_data)]:
        lines.append(f"### {framework} — Uncovered Areas")
        lines.append("")
        for mod in all_modules:
            fc = data.get(mod, FileCov())
            if fc.lines_total == 0:
                lines.append(f"- **{mod}**: no coverage data (not compiled in this flow)")
                continue
            uncov_lines = fc.lines_total - fc.lines_hit
            uncov_br = fc.branches_total - fc.branches_hit
            if uncov_lines == 0 and uncov_br == 0:
                continue
            lines.append(f"- **{mod}**: {uncov_lines} uncovered lines, {uncov_br} uncovered branches")
        lines.append("")

    # --- Summary ---
    lines.append("## Summary")
    lines.append("")
    lines.append("| Metric | cocotb | UVM |")
    lines.append("|--------|--------|-----|")
    lines.append(f"| DUT Line Coverage | {fmt_pct(cocotb_total.line_pct)} | {fmt_pct(uvm_total.line_pct)} |")
    lines.append(f"| DUT Branch Coverage | {fmt_pct(cocotb_total.branch_pct)} | {fmt_pct(uvm_total.branch_pct)} |")
    lines.append(f"| Target | 100% line, 100% branch | 100% line, 100% branch |")
    lines.append("")

    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description="Generate coverage baseline report")
    parser.add_argument("--cocotb", required=True, help="Path to cocotb LCOV .info file")
    parser.add_argument("--uvm", required=True, help="Path to UVM LCOV .info file")
    parser.add_argument("--rtl-dir", default="rtl", help="Path to RTL source directory")
    parser.add_argument("--out", required=True, help="Output Markdown file path")
    args = parser.parse_args()

    cocotb_data = parse_lcov(args.cocotb, args.rtl_dir)
    uvm_data = parse_lcov(args.uvm, args.rtl_dir)

    report = generate_report(cocotb_data, uvm_data)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(report)

    print(f"Report written to {args.out}")

    # Print summary to stdout
    cc_total = FileCov()
    uv_total = FileCov()
    for fc in cocotb_data.values():
        cc_total += FileCov(fc.lines_hit, fc.lines_total, fc.branches_hit, fc.branches_total)
    for fc in uvm_data.values():
        uv_total += FileCov(fc.lines_hit, fc.lines_total, fc.branches_hit, fc.branches_total)
    print(f"cocotb DUT: {fmt_pct(cc_total.line_pct)} line, {fmt_pct(cc_total.branch_pct)} branch")
    print(f"UVM    DUT: {fmt_pct(uv_total.line_pct)} line, {fmt_pct(uv_total.branch_pct)} branch")


if __name__ == "__main__":
    main()
