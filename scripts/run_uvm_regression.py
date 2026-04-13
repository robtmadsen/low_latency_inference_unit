#!/usr/bin/env python3
"""Compile (if needed) and run the full UVM regression, then produce a merged report.

For each test the script runs the simv binary, captures output, and writes:
  - tb/uvm/sim_build/verilator/<test_name>.log   (full simulation log)
  - reports/uvm_results.xml                      (merged JUnit-style XML with summary)

Usage:
    # Compile + run all tests + report
    python3 scripts/run_uvm_regression.py

    # Skip compile step (use existing simv)
    python3 scripts/run_uvm_regression.py --no-compile

    # Skip running tests; parse existing logs and produce report only
    python3 scripts/run_uvm_regression.py --no-run

    # Custom output path
    python3 scripts/run_uvm_regression.py --output path/to/out.xml
"""

import argparse
import os
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path
from typing import List

REPO_ROOT  = Path(__file__).resolve().parent.parent
UVM_DIR    = REPO_ROOT / "tb" / "uvm"
SIMV       = UVM_DIR / "sim_build" / "verilator" / "simv"
LOG_DIR    = UVM_DIR / "sim_build" / "verilator"
DEFAULT_OUT= REPO_ROOT / "reports" / "uvm_results.xml"

UVM_HOME   = os.environ.get(
    "UVM_HOME",
    "/Users/robertmadsen/Documents/projects/uvm-reference/src"
)

ALL_TESTS = [
    "lliu_base_test",
    "lliu_smoke_test",
    "lliu_replay_test",
    "lliu_random_test",
    "lliu_stress_test",
    "lliu_error_test",
    "lliu_coverage_test",
]

# Tests that require a separate compilation with a different TOPLEVEL.
# Each entry: (toplevel_name, [test_names])
EXTRA_TOPLEVEL_TESTS = [
    # Phase 1 v2.0 — order book stress (needs TOPLEVEL=order_book for DUT ifdef)
    ("order_book", ["lliu_order_book_test"]),
    # Phase 2 v2.0 — block-level block tests (each needs its own TOPLEVEL)
    ("moldupp64_strip",  ["lliu_moldupp64_test"]),
    ("symbol_filter",    ["lliu_symfilter_test"]),
    ("eth_axis_rx_wrap", ["lliu_dropfull_test"]),
    # Phase 2 v2.0 — kc705_top system-level tests
    ("kc705_top", [
        "lliu_kc705_test",
        "lliu_kc705_perf_test",
        "lliu_risk_fuzz_test",
        "lliu_ouch_compliance_test",
        "lliu_tx_backpressure_test",
    ]),
]


# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------

def compile_uvm(toplevel: str = "lliu_top") -> bool:
    """Run make compile for the given TOPLEVEL. Returns True on success."""
    print(f"Compiling UVM testbench (TOPLEVEL={toplevel})...")
    result = subprocess.run(
        ["make", "SIM=verilator", f"UVM_HOME={UVM_HOME}",
         f"TOPLEVEL={toplevel}", "compile"],
        cwd=UVM_DIR,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print("ERROR: compilation failed. Last 10 lines of output:")
        for line in (result.stdout + result.stderr).splitlines()[-10:]:
            print(f"  {line}")
        return False
    print("  Compilation successful.\n")
    return True


# ---------------------------------------------------------------------------
# Run one test
# ---------------------------------------------------------------------------

def run_test(test_name: str) -> dict:
    """Run one UVM test. Returns a result dict."""
    log_path = LOG_DIR / f"{test_name}.log"
    print(f"  {test_name} ... ", end="", flush=True)

    result = subprocess.run(
        [
            str(SIMV),
            f"+UVM_TESTNAME={test_name}",
            "+UVM_VERBOSITY=UVM_MEDIUM",
            "+DATA_DIR=../../data",
            "+GOLDEN_MODEL=golden_model/golden_model.py",
        ],
        cwd=UVM_DIR,
        capture_output=True,
        text=True,
    )

    output = result.stdout + result.stderr
    log_path.parent.mkdir(parents=True, exist_ok=True)
    log_path.write_text(output)

    return parse_log(test_name, output, result.returncode)


# ---------------------------------------------------------------------------
# Parse a log (run-time or from file)
# ---------------------------------------------------------------------------

def parse_log(test_name: str, output: str, exit_code=None) -> dict:
    """Extract verdict and counts from UVM log text."""
    passed  = bool(re.search(r"\*\* TEST PASSED \*\*", output))
    failed  = bool(re.search(r"\*\* TEST FAILED \*\*", output))

    # UVM report-server summary block  "UVM_ERROR :    2"
    def _count(tag: str) -> int:
        m = re.search(rf"^{tag}\s*:\s*(\d+)", output, re.MULTILINE)
        return int(m.group(1)) if m else 0

    errors   = _count("UVM_ERROR")
    warnings = _count("UVM_WARNING")
    fatals   = _count("UVM_FATAL")

    # Sim timestamp from "** TEST ... **  @ <time>"
    sim_time = ""
    m = re.search(r"@\s*([\d.]+):", output)
    if m:
        sim_time = m.group(1)

    # Failure message — first UVM_ERROR line body
    failure_msg = ""
    if failed or (not passed):
        m = re.search(r"UVM_ERROR[^\n]+\[TEST\]\s*(.*)", output)
        if m:
            failure_msg = m.group(1).strip()
        if not failure_msg:
            # Collect first non-info UVM_ERROR line
            for line in output.splitlines():
                if "UVM_ERROR" in line and "[TEST]" not in line and "[UVM/" not in line:
                    failure_msg = line.strip()
                    break

    verdict = "PASSED" if passed else "FAILED"
    print(verdict)

    return {
        "name":        test_name,
        "passed":      passed,
        "failed":      not passed,
        "verdict":     verdict,
        "errors":      errors,
        "warnings":    warnings,
        "fatals":      fatals,
        "sim_time_ns": sim_time,
        "failure_msg": failure_msg,
        "exit_code":   exit_code if exit_code is not None else (0 if passed else 1),
    }


# ---------------------------------------------------------------------------
# Build XML report
# ---------------------------------------------------------------------------

def _indent_xml(elem: ET.Element, level: int = 0) -> None:
    """Recursive pretty-printer compatible with Python 3.8 (ET.indent needs 3.9)."""
    indent = "\n" + "  " * level
    if len(elem):
        elem.text = indent + "  "
        elem.tail = indent
        for child in elem:
            _indent_xml(child, level + 1)
        child.tail = indent
    else:
        elem.tail = indent
    if level == 0:
        elem.tail = "\n"


def build_report(results: List[dict], output_path: Path) -> None:
    total   = len(results)
    passed  = sum(1 for r in results if r["passed"])
    failed  = total - passed

    doc = ET.Element("testsuites", name="uvm_regression")

    summary = ET.SubElement(doc, "summary")
    summary.set("timestamp", datetime.now().isoformat(timespec="seconds"))
    summary.set("tests",   str(total))
    summary.set("passed",  str(passed))
    summary.set("failed",  str(failed))
    summary.set("skipped", "0")

    ts = ET.SubElement(doc, "testsuite", name="uvm",
                       tests=str(total), failures=str(failed), skipped="0")

    for r in results:
        tc = ET.SubElement(ts, "testcase",
                           name=r["name"],
                           classname="uvm",
                           time="0")
        tc.set("sim_time_ns", r["sim_time_ns"])
        tc.set("uvm_errors",   str(r["errors"]))
        tc.set("uvm_warnings", str(r["warnings"]))
        tc.set("uvm_fatals",   str(r["fatals"]))
        tc.set("log", str(LOG_DIR / f"{r['name']}.log"))

        if r["failed"]:
            failure = ET.SubElement(tc, "failure",
                                    error_type="UVM_ERROR" if r["errors"] else "TEST_FAILED")
            failure.set("error_msg", r["failure_msg"] or f"TEST FAILED (exit {r['exit_code']})")

    tree = ET.ElementTree(doc)
    # ET.indent was added in Python 3.9; provide a compatible fallback for 3.8.
    if hasattr(ET, "indent"):
        ET.indent(tree, space="  ")
    else:
        _indent_xml(doc)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(str(output_path), encoding="unicode", xml_declaration=True)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", default=str(DEFAULT_OUT),
                        help="Path for output XML (default: reports/uvm_results.xml)")
    parser.add_argument("--no-compile", action="store_true",
                        help="Skip compilation; use existing simv binary")
    parser.add_argument("--no-run", action="store_true",
                        help="Skip running tests; parse existing log files and produce report")
    args = parser.parse_args()

    output_path = Path(args.output)
    results: List[dict] = []

    print(f"\n{'='*64}")
    print(f"  UVM Regression  —  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*64}\n")

    if args.no_run:
        print("--no-run: parsing existing log files\n")
        all_test_names = list(ALL_TESTS)
        for _, names in EXTRA_TOPLEVEL_TESTS:
            all_test_names.extend(names)
        for test_name in all_test_names:
            log_path = LOG_DIR / f"{test_name}.log"
            if log_path.exists():
                print(f"  {test_name} ... ", end="", flush=True)
                results.append(parse_log(test_name, log_path.read_text()))
            else:
                print(f"  {test_name} ... MISSING LOG — skipped")
    else:
        # --- Default toplevel tests --------------------------------------
        if not args.no_compile:
            if not compile_uvm():
                return 2

        if not SIMV.exists():
            print(f"ERROR: simv not found at {SIMV}. Run without --no-compile.")
            return 2

        print("Running tests:\n")
        for test_name in ALL_TESTS:
            results.append(run_test(test_name))

        # --- Extra toplevel groups (Phase 1 v2.0 order_book, etc.) ------
        for toplevel, test_names in EXTRA_TOPLEVEL_TESTS:
            print(f"\nCompiling extra group (TOPLEVEL={toplevel}):")
            if not args.no_compile:
                if not compile_uvm(toplevel):
                    # Mark all tests in this group as failed
                    for test_name in test_names:
                        results.append({
                            "name": test_name, "passed": False, "failed": True,
                            "verdict": "FAILED", "errors": 1, "warnings": 0,
                            "fatals": 0, "sim_time_ns": "", "exit_code": 2,
                            "failure_msg": f"Compilation failed for TOPLEVEL={toplevel}",
                        })
                    continue

            if not SIMV.exists():
                print(f"  ERROR: simv not found after {toplevel} compile.")
                continue

            print(f"Running {toplevel} tests:\n")
            for test_name in test_names:
                results.append(run_test(test_name))

    build_report(results, output_path)

    total  = len(results)
    passed = sum(1 for r in results if r["passed"])
    failed = total - passed

    print(f"\nReport written → {output_path}\n")
    print(f"{'='*64}")
    print(f"  SUMMARY  tests={total}  passed={passed}  failed={failed}  skipped=0")
    print(f"{'='*64}\n")

    return 1 if failed > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
