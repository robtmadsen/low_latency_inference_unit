#!/usr/bin/env bash
# clean_regression_artifacts.sh
# Deletes all stale test artifacts before a fresh regression run.
# Run from the repo root:
#   bash scripts/clean_regression_artifacts.sh

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Cleaning regression artifacts under: $REPO_ROOT"

# cocotb
rm -f  "$REPO_ROOT/tb/cocotb/results.xml"
rm -f  "$REPO_ROOT/tb/cocotb/results "*.xml   # numbered copies, e.g. "results 2.xml"
rm -f  "$REPO_ROOT/tb/cocotb/regression_results"/results_*.xml

# UVM sim_build (logs + binary — forces recompile)
rm -rf "$REPO_ROOT/tb/uvm/sim_build/verilator"

# Merged report XMLs
rm -f  "$REPO_ROOT/reports/cocotb_results.xml"
rm -f  "$REPO_ROOT/reports/uvm_results.xml"

echo "Done."
