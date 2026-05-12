#!/usr/bin/env python3
"""Parse Verilator annotated coverage and produce reports/coverage.txt.

Annotation format (per Verilator --annotate):
  %000000  — coverable point with ZERO hits (uncovered)
  %NNNNNN  — coverable point with NNNNNN hits (covered)
   NNNNNN  — coverable point with non-zero hits
  ~NNNNNN  — toggle point partially covered
  (blank)  — not a coverable point
"""

import os
import re
import glob

REPORT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reports')
ANN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'coverage_ann')


def parse_annotated_file(path):
    total = 0
    hit = 0
    missed_lines = []
    with open(path) as f:
        for raw_line in f:
            line = raw_line.rstrip('\n')
            # Match: optional leading whitespace, then one of:
            #   %NNNNNN   — coverage point (possibly zero)
            #   ~NNNNNN   — partial toggle
            #    NNNNNN   — non-zero coverage (leading space)
            m = re.match(r'^([%~ ])(\d{6})\s+(.*)', line)
            if not m:
                continue
            prefix = m.group(1)
            count = int(m.group(2))
            src = m.group(3).strip()
            total += 1
            if count > 0:
                hit += 1
            else:
                missed_lines.append(src)
    return total, hit, missed_lines


def main():
    os.makedirs(REPORT_DIR, exist_ok=True)

    out = []
    out.append("=" * 70)
    out.append("Verilator Coverage Report")
    out.append("=" * 70)
    out.append("")

    ann_files = sorted(glob.glob(os.path.join(ANN_DIR, '*.sv')))

    summary = {}
    for af in ann_files:
        basename = os.path.basename(af)
        total, hit, missed = parse_annotated_file(af)
        if total == 0:
            continue
        pct = 100.0 * hit / total
        summary[basename] = (total, hit, pct, missed)

    for basename in sorted(summary.keys()):
        total, hit, pct, missed = summary[basename]
        out.append(f"  {basename:40s} {hit:4d}/{total:4d}  {pct:6.1f}%")
        if missed:
            for src in missed[:5]:
                out.append(f"      MISS: {src[:70]}")

    out.append("")
    out.append("-" * 70)
    lliu = summary.get('lliu_core.sv')
    if lliu:
        total, hit, pct, _ = lliu
        out.append(f"lliu_core line coverage: {hit}/{total} = {pct:.1f}%")
        if pct >= 100.0:
            out.append("100%")
    else:
        out.append("WARNING: lliu_core.sv not found in annotated coverage")
    out.append("")

    report = '\n'.join(out) + '\n'
    with open(os.path.join(REPORT_DIR, 'coverage.txt'), 'w') as f:
        f.write(report)
    print(report)


if __name__ == '__main__':
    main()
