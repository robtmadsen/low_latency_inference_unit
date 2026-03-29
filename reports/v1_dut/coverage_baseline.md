# Coverage Baseline Report

Baseline structural coverage from existing test suites — no new tests added.
Coverage collected with Verilator `--coverage` (line + toggle + branch).

> **Note:** Verilator merges toggle coverage into branch counts.
> The "Branch" column below includes both branch and toggle coverage points.

## Per-Module Coverage

| Module | cocotb Line | cocotb Branch | UVM Line | UVM Branch |
|--------|-------------|---------------|----------|------------|
| axi4_lite_slave.sv | 89.1% (82/92) | 62.6% (296/473) | 89.1% (82/92) | 53.1% (251/473) |
| bfloat16_mul.sv | 91.9% (34/37) | 78.4% (877/1119) | 83.8% (31/37) | 62.3% (223/358) |
| dot_product_engine.sv | 95.7% (44/46) | 86.5% (782/904) | 95.7% (44/46) | 70.4% (300/426) |
| feature_extractor.sv | 98.5% (64/65) | 69.7% (1215/1744) | 98.5% (64/65) | 84.7% (706/834) |
| fp32_acc.sv | 81.6% (84/103) | 71.6% (1645/2298) | 82.5% (85/103) | 81.5% (571/701) |
| itch_field_extract.sv | 100.0% (6/6) | 82.9% (355/428) | 100.0% (6/6) | 92.5% (198/214) |
| itch_parser.sv | 92.9% (52/56) | 84.9% (761/896) | 96.4% (54/56) | 91.7% (378/412) |
| lliu_top.sv | 93.4% (71/76) | 82.0% (800/976) | 93.4% (71/76) | 74.9% (731/976) |
| output_buffer.sv | 100.0% (14/14) | 91.4% (128/140) | 100.0% (14/14) | 86.4% (121/140) |
| weight_mem.sv | 100.0% (16/16) | 57.1% (120/210) | 100.0% (16/16) | 32.4% (68/210) |
| **TOTAL** | **91.4%** (467/511) | **76.0%** (6979/9188) | **91.4%** (467/511) | **74.8%** (3547/4744) |

## Gap Analysis

### cocotb — Uncovered Areas

- **axi4_lite_slave.sv**: 10 uncovered lines, 177 uncovered branches
- **bfloat16_mul.sv**: 3 uncovered lines, 242 uncovered branches
- **dot_product_engine.sv**: 2 uncovered lines, 122 uncovered branches
- **feature_extractor.sv**: 1 uncovered lines, 529 uncovered branches
- **fp32_acc.sv**: 19 uncovered lines, 653 uncovered branches
- **itch_field_extract.sv**: 0 uncovered lines, 73 uncovered branches
- **itch_parser.sv**: 4 uncovered lines, 135 uncovered branches
- **lliu_top.sv**: 5 uncovered lines, 176 uncovered branches
- **output_buffer.sv**: 0 uncovered lines, 12 uncovered branches
- **weight_mem.sv**: 0 uncovered lines, 90 uncovered branches

### UVM — Uncovered Areas

- **axi4_lite_slave.sv**: 10 uncovered lines, 222 uncovered branches
- **bfloat16_mul.sv**: 6 uncovered lines, 135 uncovered branches
- **dot_product_engine.sv**: 2 uncovered lines, 126 uncovered branches
- **feature_extractor.sv**: 1 uncovered lines, 128 uncovered branches
- **fp32_acc.sv**: 18 uncovered lines, 130 uncovered branches
- **itch_field_extract.sv**: 0 uncovered lines, 16 uncovered branches
- **itch_parser.sv**: 2 uncovered lines, 34 uncovered branches
- **lliu_top.sv**: 5 uncovered lines, 245 uncovered branches
- **output_buffer.sv**: 0 uncovered lines, 19 uncovered branches
- **weight_mem.sv**: 0 uncovered lines, 142 uncovered branches

## Summary

| Metric | cocotb | UVM |
|--------|--------|-----|
| DUT Line Coverage | 91.4% | 91.4% |
| DUT Branch Coverage | 76.0% | 74.8% |
| Target | 100% line, 100% branch | 100% line, 100% branch |
