#!/usr/bin/env python3
"""Parse Verilator annotated coverage and generate reports/coverage.txt."""
import os, re, sys

REPORT_DIR = "../reports"
ANNOTATE_DIR = os.path.join(REPORT_DIR, "annotate")

def find_file(base, name):
    for root, _, files in os.walk(base):
        if name in files:
            return os.path.join(root, name)
    return None

def parse(path):
    covered = uncovered = 0
    with open(path) as fh:
        for line in fh:
            s = line.lstrip()
            if s.startswith('%'):
                uncovered += 1
            elif s and s[0].isdigit():
                m = re.match(r'(\d+)', s)
                if m and int(m.group(1)) > 0:
                    covered += 1
    return covered, uncovered

def main():
    os.makedirs(REPORT_DIR, exist_ok=True)
    fp = find_file(ANNOTATE_DIR, "lliu_core.sv")
    if not fp:
        print("WARNING: annotated lliu_core.sv not found")
        with open(os.path.join(REPORT_DIR, "coverage.txt"), "w") as f:
            f.write("Line Coverage Report\nModule: lliu_core\nERROR: data not found\n")
        return 1
    cov, uncov = parse(fp)
    total = cov + uncov
    pct = (cov * 100 // total) if total else 0
    with open(os.path.join(REPORT_DIR, "coverage.txt"), "w") as f:
        f.write("Line Coverage Report\n")
        f.write("=" * 40 + "\n\n")
        f.write(f"Module: lliu_core\n")
        f.write(f"Covered lines:   {cov}\n")
        f.write(f"Uncovered lines: {uncov}\n")
        f.write(f"Total:           {total}\n")
        f.write(f"Line coverage:   {pct}%\n")
    print(f"lliu_core line coverage: {pct}% ({cov}/{total})")
    return 0 if pct == 100 else 1

if __name__ == "__main__":
    sys.exit(main())
