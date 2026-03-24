#!/bin/bash
# Run all UVM tests with coverage enabled, collecting coverage.dat from each

PROJ_ROOT="/Users/robertmadsen/Documents/projects/low_latency_inference_unit"
BUILD_DIR="$PROJ_ROOT/tb/uvm/sim_build/verilator"
COV_DIR="$PROJ_ROOT/tb/uvm/coverage_data"
DATA_DIR="$PROJ_ROOT/data"
GM_PY="$PROJ_ROOT/tb/uvm/golden_model/golden_model.py"

TESTS="lliu_smoke_test lliu_replay_test lliu_random_test lliu_stress_test lliu_error_test lliu_coverage_test"

rm -rf "$COV_DIR"
mkdir -p "$COV_DIR"

cd "$BUILD_DIR"

for t in $TESTS; do
    echo "==== Running $t ===="
    rm -f coverage.dat
    ./simv \
        +UVM_TESTNAME=$t \
        +UVM_VERBOSITY=UVM_LOW \
        +DATA_DIR=$DATA_DIR \
        +GOLDEN_MODEL=$GM_PY \
        > "$COV_DIR/${t}.log" 2>&1 || true

    if [ -f coverage.dat ]; then
        cp coverage.dat "$COV_DIR/${t}.dat"
        echo "  -> coverage.dat collected"
    else
        echo "  -> NO coverage.dat"
    fi

    # Check test result
    if grep -q "UVM_FATAL" "$COV_DIR/${t}.log"; then
        echo "  -> FATAL in $t"
        grep "UVM_FATAL" "$COV_DIR/${t}.log" | head -2
    fi
    if grep -q "TEST PASSED\|TEST_PASSED\|UVM_INFO.*report_phase" "$COV_DIR/${t}.log"; then
        echo "  -> PASSED"
    fi
done

echo ""
echo "==== Merging coverage ===="
DAT_FILES=$(find "$COV_DIR" -name '*.dat' ! -name 'merged.dat' | sort | tr '\n' ' ')
if [ -n "$DAT_FILES" ]; then
    verilator_coverage --write "$COV_DIR/merged.dat" $DAT_FILES
    echo "Merged -> $COV_DIR/merged.dat"

    echo ""
    echo "==== Coverage Summary ===="
    verilator_coverage --annotate "$COV_DIR/annotate" --annotate-min 1 "$COV_DIR/merged.dat"
    echo "Annotated files in $COV_DIR/annotate/"
else
    echo "No .dat files found!"
fi
