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


# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------

def compile_uvm() -> bool:
    """Run make compile. Returns True on success."""
    print("Compiling UVM testbench...")
    result = subprocess.run(
        ["make", "SIM=verilator", f"UVM_HOME={UVM_HOME}", "compile"],
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

def parse_log(test_name: str, output: str, exit_code: int | None = None) -> dict:
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

def build_report(results: list[dict], output_path: Path) -> None:
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
    ET.indent(tree, space="  ")
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
    results: list[dict] = []

    print(f"\n{'='*64}")
    print(f"  UVM Regression  —  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'='*64}\n")

    if args.no_run:
        print("--no-run: parsing existing log files\n")
        for test_name in ALL_TESTS:
            log_path = LOG_DIR / f"{test_name}.log"
            if log_path.exists():
                print(f"  {test_name} ... ", end="", flush=True)
                results.append(parse_log(test_name, log_path.read_text()))
            else:
                print(f"  {test_name} ... MISSING LOG — skipped")
    else:
        if not args.no_compile:
            if not compile_uvm():
                return 2

        if not SIMV.exists():
            print(f"ERROR: simv not found at {SIMV}. Run without --no-compile.")
            return 2

        print("Running tests:\n")
        for test_name in ALL_TESTS:
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
