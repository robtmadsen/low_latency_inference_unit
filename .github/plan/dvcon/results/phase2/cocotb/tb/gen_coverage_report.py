#!/usr/bin/env python3
"""Parse Verilator coverage data and generate reports/coverage.txt.

Two strategies:
  1. Parse coverage.dat directly for line+branch entries (precise).
  2. Parse annotated source for procedural-block lines (backup).
"""
import subprocess
import os
import glob
import sys
import re


def find_coverage_dat():
    for p in ['coverage.dat', 'sim_build/coverage.dat']:
        if os.path.exists(p):
            return p
    return None


def parse_coverage_dat(dat_path, target_file='itch_field_extract.sv'):
    """Parse raw coverage.dat and count line+branch entries for our DUT."""
    covered = 0
    total = 0
    uncovered_details = []

    with open(dat_path) as f:
        for line in f:
            if not line.startswith('C '):
                continue
            if target_file not in line:
                continue

            parts = line.split('\x01')
            info = {}
            for p in parts:
                if '\x02' in p:
                    k, v = p.split('\x02', 1)
                    info[k] = v

            cov_type = info.get('t', '')
            if cov_type not in ('line', 'branch'):
                continue

            count = int(line.rsplit("'", 1)[1].strip())
            lineno = info.get('l', '?')
            obj = info.get('o', '').split('\x01')[0]
            total += 1
            if count > 0:
                covered += 1
            else:
                uncovered_details.append(f"  {cov_type} at line {lineno} ({obj}): count={count}")

    return covered, total, uncovered_details


def parse_annotated(annot_file):
    """Backup: parse annotated source, counting only lines inside always blocks."""
    covered = 0
    uncovered = 0
    uncovered_lines = []
    in_always = False

    with open(annot_file) as f:
        for ln, line in enumerate(f, 1):
            src = line.rstrip()
            if 'always_ff' in src or 'always @' in src:
                in_always = True
            if in_always and re.match(r'^\s+end\s*$', src.split('\t')[-1] if '\t' in src else ''):
                pass

            parts = line.split('\t', 1)
            if len(parts) < 2:
                continue
            prefix = parts[0].strip()
            source = parts[1].rstrip()

            if not in_always:
                continue
            if not prefix:
                continue

            if prefix.startswith('%'):
                try:
                    c = int(prefix[1:])
                    if c == 0:
                        uncovered += 1
                        uncovered_lines.append((ln, source))
                    else:
                        covered += 1
                except ValueError:
                    pass
            else:
                try:
                    c = int(prefix)
                    if c > 0:
                        covered += 1
                    else:
                        uncovered += 1
                        uncovered_lines.append((ln, source))
                except ValueError:
                    pass

            if re.search(r'\bend\b', source) and source.strip() == 'end':
                in_always = False

    return covered, uncovered, uncovered_lines


def main():
    dat = find_coverage_dat()
    if not dat:
        print("ERROR: coverage.dat not found")
        sys.exit(1)

    # Strategy 1: parse raw coverage.dat for line+branch entries
    covered, total, uncov_details = parse_coverage_dat(dat)

    if total == 0:
        # Fallback: use annotated file
        annot_dir = 'coverage_annot'
        os.makedirs(annot_dir, exist_ok=True)
        subprocess.run(['verilator_coverage', '--annotate', annot_dir, dat], check=True)
        for f in glob.glob(os.path.join(annot_dir, '**', '*itch_field_extract*'), recursive=True):
            cov, uncov, uncov_lines = parse_annotated(f)
            covered = cov
            total = cov + uncov
            uncov_details = [f"  Line {ln}: {src}" for ln, src in uncov_lines]
            break

    if total == 0:
        print("ERROR: no coverage points found")
        sys.exit(1)

    pct = covered * 100.0 / total

    report_dir = os.path.join('..', 'reports')
    os.makedirs(report_dir, exist_ok=True)

    with open(os.path.join(report_dir, 'coverage.txt'), 'w') as f:
        f.write(f"Line Coverage: {pct:.0f}%\n")
        f.write(f"Covered: {covered}/{total} (line + branch points)\n")
        if uncov_details:
            f.write("\nUncovered:\n")
            for d in uncov_details:
                f.write(d + "\n")
        else:
            f.write("\nAll line and branch coverage points covered.\n")

    print(f"Line Coverage: {pct:.0f}% ({covered}/{total})")
    if uncov_details:
        print("Uncovered:")
        for d in uncov_details:
            print(d)

    return int(pct)


if __name__ == '__main__':
    pct = main()
    if pct < 100:
        print(f"\nWARNING: Line coverage is {pct}%, target is 100%")
        sys.exit(1)
    else:
        print("\nAll lines covered!")
