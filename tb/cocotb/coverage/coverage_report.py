"""Coverage reporting — formats and optionally persists coverage results."""

import json
import os


def format_coverage(cov_data: dict) -> str:
    """Format a coverage report dict into a human-readable string."""
    lines = []
    lines.append(f"=== Functional Coverage Report ({cov_data['total_sampled']} samples) ===")
    lines.append(f"Overall: {cov_data['overall_coverage_pct']:.1f}%")
    lines.append("")

    for cp in cov_data.get('coverpoints', []):
        lines.append(f"  [{cp['name']}] {cp['covered_bins']}/{cp['total_bins']} bins "
                      f"({cp['coverage_pct']:.1f}%)")
        for bin_name, count in cp['bins'].items():
            marker = "✓" if count > 0 else "✗"
            lines.append(f"    {marker} {bin_name}: {count}")

    for cross in cov_data.get('crosses', []):
        lines.append(f"  [{cross['name']}] {cross['covered_bins']}/{cross['total_bins']} bins "
                      f"({cross['coverage_pct']:.1f}%)")
        for bin_name, count in cross['bins'].items():
            marker = "✓" if count > 0 else "✗"
            lines.append(f"    {marker} {bin_name}: {count}")

    return "\n".join(lines)


def save_coverage_json(cov_data: dict, path: str = "coverage_report.json"):
    """Write coverage data to a JSON file for CI artifact upload."""
    os.makedirs(os.path.dirname(path) if os.path.dirname(path) else ".", exist_ok=True)
    with open(path, 'w') as f:
        json.dump(cov_data, f, indent=2)
