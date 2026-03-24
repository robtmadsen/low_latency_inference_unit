#!/bin/bash
# Analyze RTL line coverage from Verilator annotated output.
# Usage: bash analyze_coverage.sh [annotate_dir]
set -euo pipefail

DIR="${1:-/Users/robertmadsen/Documents/projects/low_latency_inference_unit/tb/uvm/coverage_data/annotate}"
FILES="axi4_lite_slave.sv bfloat16_mul.sv dot_product_engine.sv feature_extractor.sv fp32_acc.sv itch_parser.sv lliu_top.sv"

grand_cov=0
grand_all=0

echo "RTL Line Coverage Summary"
echo "========================="
printf "%-30s %s\n" "File" "Covered / Total (uncov)"
echo "---------------------------------------------------"

for f in $FILES; do
    fp="$DIR/$f"
    if [ ! -f "$fp" ]; then
        printf "%-30s %s\n" "$f" "NOT IN ANNOTATED OUTPUT"
        continue
    fi
    # Count lines with 6-digit hit counts (covered + uncovered)
    all=$(grep -c '[0-9][0-9][0-9][0-9][0-9][0-9]' "$fp")
    # Count lines with exactly 000000 (uncovered)
    uncov=$(grep -c ' 000000 ' "$fp" || true)
    cov=$((all - uncov))
    grand_all=$((grand_all + all))
    grand_cov=$((grand_cov + cov))
    printf "%-30s %3d / %3d  (uncov: %d)\n" "$f" "$cov" "$all" "$uncov"
    if [ "$uncov" -gt 0 ]; then
        grep -n ' 000000 ' "$fp" | sed 's/^/    /'
    fi
done

echo "---------------------------------------------------"
if [ "$grand_all" -gt 0 ]; then
    pct=$((grand_cov * 100 / grand_all))
    printf "%-30s %3d / %3d  (%d%%)\n" "TOTAL" "$grand_cov" "$grand_all" "$pct"
fi
