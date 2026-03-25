#!/usr/bin/env python3
"""Run the full cocotb regression and produce a merged results XML with a summary.

For each test module the script:
  1. Runs `make SIM=verilator TOPLEVEL=<top> MODULE=tests.<module>` from tb/cocotb/.
  2. Saves a copy of results.xml as tb/cocotb/regression_results/results_<module>.xml.

After all runs a merged XML is written to reports/cocotb_results.xml (or --output).
The root <testsuites> element carries a <summary> child with aggregate counts.

Usage:
    # Run everything and produce merged report
    python3 scripts/run_cocotb_regression.py

    # Skip running tests, just merge previously saved per-module XMLs
    python3 scripts/run_cocotb_regression.py --no-run

    # Custom output path
    python3 scripts/run_cocotb_regression.py --output path/to/out.xml
"""

import argparse
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
COCOTB_DIR = REPO_ROOT / "tb" / "cocotb"
RESULTS_XML = COCOTB_DIR / "results.xml"
SAVED_DIR   = COCOTB_DIR / "regression_results"
DEFAULT_OUT = REPO_ROOT / "reports" / "cocotb_results.xml"

# (TOPLEVEL, MODULE) — order determines make-clean boundaries between toplevels
TEST_MODULES = [
    ("bfloat16_mul",       "test_bfloat16_mul"),
    ("bfloat16_mul",       "test_bf16_mul_edge"),
    ("fp32_acc",           "test_fp32_acc"),
    ("fp32_acc",           "test_fp32_acc_edge"),
    ("dot_product_engine", "test_dot_product_engine"),
    ("itch_parser",        "test_parser"),
    ("itch_parser",        "test_parser_edge"),
    ("feature_extractor",  "test_feature_extractor"),
    ("feature_extractor",  "test_feat_edge"),
    ("axi4_lite_slave",    "test_axil_regmap"),
    ("lliu_top",           "test_smoke"),
    ("lliu_top",           "test_constrained_random"),
    ("lliu_top",           "test_backpressure"),
    ("lliu_top",           "test_latency"),
    ("lliu_top",           "test_error_injection"),
    ("lliu_top",           "test_wgtmem_outbuf"),
    ("lliu_top",           "test_integration_sweep"),
    ("lliu_top",           "test_replay"),   # needs data/tvagg_sample.bin
]


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def run_test(toplevel: str, module: str, prev_toplevel: str | None) -> tuple[int, Path]:
    """Run one test module. Returns (make exit code, saved xml path)."""
    if prev_toplevel != toplevel:
        subprocess.run(["make", "clean"], cwd=COCOTB_DIR,
                       capture_output=True, check=False)

    print(f"  [{toplevel}] {module} ... ", end="", flush=True)

    result = subprocess.run(
        ["make", "SIM=verilator", f"TOPLEVEL={toplevel}", f"MODULE=tests.{module}"],
        cwd=COCOTB_DIR,
        capture_output=True,
        text=True,
    )

    # Extract TESTS= summary line from combined output
    summary = ""
    for line in (result.stdout + result.stderr).splitlines():
        if "TESTS=" in line:
            summary = line.strip().strip("* ").strip()
            break

    print(summary if summary else ("PASS" if result.returncode == 0 else f"exit {result.returncode}"))

    saved = SAVED_DIR / f"results_{module}.xml"
    if RESULTS_XML.exists():
        shutil.copy(RESULTS_XML, saved)

    return result.returncode, saved


# ---------------------------------------------------------------------------
# Merger
# ---------------------------------------------------------------------------

def merge_results(xml_files: list[Path], output_path: Path) -> tuple[int, int, int, int]:
    """Merge per-module result XMLs into one file. Returns (total, pass, fail, skip)."""
    total = passed = failed = skipped = 0
    all_testcases: list[ET.Element] = []

    for xml_file in xml_files:
        if not xml_file.exists():
            continue
        try:
            root = ET.parse(xml_file).getroot()
        except ET.ParseError:
            print(f"  WARNING: could not parse {xml_file.name} — skipping")
            continue
        for tc in root.iter("testcase"):
            all_testcases.append(tc)
            total += 1
            if tc.find("failure") is not None or tc.find("error") is not None:
                failed += 1
            elif tc.find("skipped") is not None:
                skipped += 1
            else:
                passed += 1

    # Build merged document
    doc = ET.Element("testsuites", name="cocotb_regression")

    summary = ET.SubElement(doc, "summary")
    summary.set("timestamp", datetime.now().isoformat(timespec="seconds"))
    summary.set("tests",   str(total))
    summary.set("passed",  str(passed))
    summary.set("failed",  str(failed))
    summary.set("skipped", str(skipped))

    ts = ET.SubElement(doc, "testsuite", name="all",
                       tests=str(total), failures=str(failed), skipped=str(skipped))
    for tc in all_testcases:
        ts.append(tc)

    tree = ET.ElementTree(doc)
    ET.indent(tree, space="  ")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tree.write(str(output_path), encoding="unicode", xml_declaration=True)

    return total, passed, failed, skipped


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", default=str(DEFAULT_OUT),
                        help="Path for merged output XML (default: reports/cocotb_results.xml)")
    parser.add_argument("--no-run", action="store_true",
                        help="Skip running tests; merge existing saved XMLs in regression_results/")
    args = parser.parse_args()

    output_path = Path(args.output)
    SAVED_DIR.mkdir(parents=True, exist_ok=True)

    saved_files: list[Path] = []

    if not args.no_run:
        print(f"\n{'='*64}")
        print(f"  cocotb Regression  —  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"{'='*64}\n")

        prev_toplevel: str | None = None
        for toplevel, module in TEST_MODULES:
            _, saved = run_test(toplevel, module, prev_toplevel)
            saved_files.append(saved)
            prev_toplevel = toplevel
    else:
        saved_files = sorted(SAVED_DIR.glob("results_*.xml"))
        print(f"--no-run: merging {len(saved_files)} existing XML files from {SAVED_DIR}")

    print(f"\nMerging {len(saved_files)} result file(s) → {output_path}\n")
    total, passed, failed, skipped = merge_results(saved_files, output_path)

    print(f"{'='*64}")
    print(f"  SUMMARY  tests={total}  passed={passed}  failed={failed}  skipped={skipped}")
    print(f"{'='*64}\n")

    return 1 if failed > 0 else 0


if __name__ == "__main__":
    sys.exit(main())
