#!/usr/bin/env python3
"""Summarise line coverage for itch_field_extract.sv.

Usage:
  cov_summary.py <coverage.info> <annot_dir> <basename> <out.txt>
"""
import os
import re
import sys


def parse_lcov(info_path, target_basename):
    """Parse an lcov .info file and extract per-line hits for the target file."""
    if not os.path.isfile(info_path):
        return None
    cur_file = None
    keep = False
    da = {}
    with open(info_path, "r", errors="replace") as f:
        for line in f:
            line = line.rstrip("\n")
            if line.startswith("SF:"):
                cur_file = line[3:].strip()
                keep = os.path.basename(cur_file) == target_basename
            elif line == "end_of_record":
                if keep and da:
                    return da
                cur_file = None
                keep = False
                da = {}
            elif keep and line.startswith("DA:"):
                rest = line[3:]
                parts = rest.split(",")
                if len(parts) >= 2:
                    try:
                        ln = int(parts[0])
                        hits = int(parts[1])
                        da[ln] = hits
                    except ValueError:
                        pass
    return da if da else None


def parse_annot(annot_dir, target_basename):
    """Parse Verilator annotated source. Each non-comment, in-coverage line
    starts with either '%' (not hit) or a hit count, then the source.

    Verilator's --annotate-all output prefixes each source line with a token
    like '+%000000' or '+ 000010 ' (the leading '+' marks a coverage point;
    '%' indicates a 0-hit). Lines without coverage points have no prefix.
    """
    path = os.path.join(annot_dir, target_basename)
    if not os.path.isfile(path):
        # Try recursive search
        for root, _dirs, files in os.walk(annot_dir):
            if target_basename in files:
                path = os.path.join(root, target_basename)
                break
        else:
            return None
    # Pattern: optional whitespace, then either %DDDDDD or DDDDDD digits
    # Actual annotation format (Verilator):
    #   "  hits  source"  where hits is the count or %000000
    pat = re.compile(r"^\s*(%?\d+)\s+\d{5}\s+(.*)$")
    da = {}
    with open(path, "r", errors="replace") as f:
        for ln, line in enumerate(f, 1):
            m = pat.match(line)
            if not m:
                continue
            tok = m.group(1)
            if tok.startswith("%"):
                hits = 0
            else:
                try:
                    hits = int(tok)
                except ValueError:
                    continue
            da[ln] = hits
    return da if da else None


def main():
    if len(sys.argv) != 5:
        print("usage: cov_summary.py <info> <annot_dir> <basename> <out>",
              file=sys.stderr)
        sys.exit(2)
    info_path, annot_dir, basename, out_path = sys.argv[1:]

    da = parse_lcov(info_path, basename)
    src = "lcov"
    if not da:
        da = parse_annot(annot_dir, basename)
        src = "annot"
    if not da:
        with open(out_path, "w") as f:
            f.write(f"ERROR: no coverage data found for {basename}\n")
        sys.exit(1)

    total = len(da)
    hit = sum(1 for v in da.values() if v > 0)
    miss_lines = sorted(ln for ln, v in da.items() if v == 0)
    pct = (hit * 100.0 / total) if total else 0.0
    pct_int = int(round(pct))

    lines = []
    lines.append(f"Coverage report for {basename} (source: {src})")
    lines.append(f"Lines found: {total}")
    lines.append(f"Lines hit  : {hit}")
    lines.append(f"Line coverage: {pct:.2f}%")
    if pct_int >= 100 and hit == total:
        lines.append(f"Result: 100% line coverage achieved")
    else:
        lines.append(f"Result: {pct:.2f}% line coverage")
        if miss_lines:
            lines.append(f"Uncovered lines: {miss_lines}")
    out = "\n".join(lines) + "\n"
    with open(out_path, "w") as f:
        f.write(out)
    print(out)


if __name__ == "__main__":
    main()
