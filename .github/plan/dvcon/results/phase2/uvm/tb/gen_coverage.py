#!/usr/bin/env python3
"""Parse Verilator LCOV coverage info and report line coverage for itch_field_extract.sv."""
import sys

def main():
    info_file = sys.argv[1] if len(sys.argv) > 1 else "coverage.info"
    in_file = False
    lh = lf = 0
    da_hit = da_total = 0

    try:
        with open(info_file) as f:
            for line in f:
                line = line.strip()
                if line.startswith("SF:") and "itch_field_extract" in line:
                    in_file = True
                    da_hit = da_total = 0
                    continue
                if line == "end_of_record" and in_file:
                    lh = da_hit
                    lf = da_total
                    break
                if in_file:
                    if line.startswith("LH:"):
                        lh = int(line[3:])
                    elif line.startswith("LF:"):
                        lf = int(line[3:])
                    elif line.startswith("DA:"):
                        parts = line[3:].split(",")
                        da_total += 1
                        if int(parts[1]) > 0:
                            da_hit += 1
    except FileNotFoundError:
        print(f"ERROR: {info_file} not found", file=sys.stderr)
        sys.exit(1)

    if lf == 0 and da_total > 0:
        lf = da_total
        lh = da_hit
    if lf == 0:
        print("No line-coverage data found for itch_field_extract.sv")
        sys.exit(1)

    pct = 100.0 * lh / lf
    print(f"Line Coverage for itch_field_extract.sv: {lh}/{lf} lines")
    if pct == 100.0:
        print("100%")
    else:
        print(f"{pct:.1f}%")

if __name__ == "__main__":
    main()
