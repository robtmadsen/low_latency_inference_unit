"""Post-process Verilator's coverage.dat into reports/coverage.txt.

Drives `verilator_coverage --filter-type line --annotate ...` to compute
the line-coverage percentage for the DUT, and writes a small human-readable
report. The exit criterion for the surrounding task is that this file
contains the string "100%" once the testbench achieves 100% line coverage.

Also emits supporting branch- and toggle-coverage numbers for context.
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path


DUT_BASENAME = "itch_field_extract.sv"


def run_vcov_summary(cov_dat: Path, filter_type: str | None):
    """Invoke verilator_coverage and return its 'Total coverage' summary line.

    verilator_coverage only prints the "Total coverage" summary when
    `--annotate <dir>` is supplied, so we always pass a scratch dir.
    Returns (covered, total, pct) where covered/total are ints and pct is a
    float in [0, 100]. Returns None on failure.
    """
    import tempfile, shutil
    scratch = tempfile.mkdtemp(prefix="vcov_")
    try:
        cmd = ["verilator_coverage", "--annotate", scratch, "--annotate-all"]
        if filter_type is not None:
            cmd += ["--filter-type", filter_type]
        cmd += [str(cov_dat)]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        out = (proc.stdout or "") + (proc.stderr or "")
        m = re.search(r"Total coverage \((\d+)/(\d+)\)\s+([\d\.]+)%", out)
        if not m:
            return None
        return (int(m.group(1)), int(m.group(2)), float(m.group(3)))
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def find_annotated_dut_file(annotate_dir: Path):
    if not annotate_dir.exists():
        return None
    for p in annotate_dir.rglob(DUT_BASENAME):
        return p
    return None


def parse_annotated(ann_path: Path):
    """Return (covered_lines, total_executable_lines, uncovered_linenos)."""
    if not ann_path or not ann_path.exists():
        return None
    covered = 0
    total = 0
    uncovered = []
    line_no = 0
    with ann_path.open("r", errors="replace") as f:
        for raw in f:
            line_no += 1
            stripped = raw.lstrip()
            if not stripped:
                continue
            # Annotated lines start with one of:
            #   "%000000" -> uncovered
            #   "~000022" -> partially covered (some toggle bits below threshold)
            #   " 000164" -> fully covered
            #   <whitespace>... -> non-executable / source comment
            m = re.match(r"^([%~ ])(\d{6,})", raw)
            if not m:
                continue
            mark = m.group(1)
            count = int(m.group(2))
            total += 1
            if mark == "%":
                uncovered.append(line_no)
            elif count == 0:
                uncovered.append(line_no)
            else:
                covered += 1
    return covered, total, uncovered


def main(argv):
    if len(argv) != 4:
        print("usage: gen_coverage_report.py coverage.dat annotate_dir out.txt",
              file=sys.stderr)
        return 2
    cov_dat = Path(argv[1])
    annotate_dir = Path(argv[2])
    out_path = Path(argv[3])
    out_path.parent.mkdir(parents=True, exist_ok=True)

    if not cov_dat.exists():
        out_path.write_text(f"ERROR: coverage.dat not found at {cov_dat}\n")
        return 1

    line_summary    = run_vcov_summary(cov_dat, "line")
    branch_summary  = run_vcov_summary(cov_dat, "branch")
    toggle_summary  = run_vcov_summary(cov_dat, "toggle")
    overall_summary = run_vcov_summary(cov_dat, None)

    # Use the annotated source file (always emitted at annotate_dir/<basename>)
    # to enumerate uncovered DUT lines.
    ann_dut = find_annotated_dut_file(annotate_dir)
    ann_parsed = parse_annotated(ann_dut)

    def fmt(t):
        if t is None:
            return "n/a"
        c, n, p = t
        return f"{c}/{n} ({p:.2f}%)"

    line_pct = line_summary[2] if line_summary else 0.0
    line_pct_str = f"{line_pct:.2f}%"
    line_covered_str = "100%" if line_summary and line_summary[0] == line_summary[1] and line_summary[1] > 0 else line_pct_str

    out_lines = []
    out_lines.append("itch_field_extract — Coverage Report")
    out_lines.append("=" * 60)
    out_lines.append(f"DUT source file        : rtl/{DUT_BASENAME}")
    out_lines.append(f"Source coverage data   : {cov_dat.name}")
    out_lines.append("")
    out_lines.append("Coverage by type (Verilator):")
    out_lines.append(f"  Line coverage     : {fmt(line_summary)}")
    out_lines.append(f"  Branch coverage   : {fmt(branch_summary)}")
    out_lines.append(f"  Toggle coverage   : {fmt(toggle_summary)}")
    out_lines.append(f"  Overall (all types): {fmt(overall_summary)}")
    out_lines.append("")
    if line_summary and line_summary[0] == line_summary[1] and line_summary[1] > 0:
        out_lines.append(f"LINE COVERAGE RESULT  : 100% ({line_summary[0]}/{line_summary[1]})")
    else:
        out_lines.append(f"LINE COVERAGE RESULT  : {line_pct_str}")

    out_lines.append("")
    if ann_parsed is not None:
        c, n, uncov = ann_parsed
        out_lines.append("Annotated-source line accounting:")
        out_lines.append(f"  Executable lines (annotated) : {n}")
        out_lines.append(f"  Covered lines                : {c}")
        out_lines.append(f"  Uncovered lines              : {n - c}")
        if uncov:
            out_lines.append("  Uncovered line numbers       : " + ", ".join(map(str, uncov)))
        else:
            out_lines.append("  Uncovered line numbers       : (none)")
    out_lines.append("")
    out_lines.append("Annotated source         : reports/coverage_annotate/itch_field_extract.sv")
    out_lines.append("Raw coverage data        : tb/coverage.dat")

    out_path.write_text("\n".join(out_lines) + "\n")
    print(f"[gen_coverage_report] line coverage: {line_covered_str} -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
