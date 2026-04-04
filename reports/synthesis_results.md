# LLIU Synthesis & P&R Results — xc7k160tffg676-2

**Updated:** 2026-04-04  
**Tool:** Vivado ML Standard v2025.2  
**Target:** `xc7k160tffg676-2` (Kintex-7, -2 speed grade)  
**Synthesis top:** `lliu_top` (LLIU inference core, AXI4-S + AXI4-Lite)  
**EC2 instance:** `c5.4xlarge` — IP `3.86.63.142`  
**Constraints:** `syn/constraints_lliu_top.xdc` (300 MHz clock on `clk`, false-path I/Os)  

---

## Run History

| Run | RTL commit | WNS | Critical path | Status |
|-----|-----------|-----|---------------|--------|
| 1 | `2f2098e` (fp32_acc 1-stage) | −6.188 ns | `fp32_acc` CARRY4 chain | ❌ |
| 2 | `b938747` (fp32_acc 3-stage) | −2.322 ns | `itch_parser`→`feature_extractor` | ❌ |

---

## 1. Resource Utilization — Run 2 (Post-Implementation)

| Resource | Run 1 | Run 2 | Available | Util% (Run 2) |
|----------|-------|-------|-----------|---------------|
| Slice LUTs | 1,599 | **1,534** | 101,400 | **1.51%** |
| Slice Registers (FFs) | 417 | **534** | 202,800 | **0.26%** |
| DSP48E1 | 0 | **0** | 600 | 0.00% |
| Block RAM Tile | 0 | **0** | 325 | 0.00% |
| IOB | 147¹ | **147¹** | 400 | — |

¹ 147 `lliu_top` AXI ports are unconstrained (no board pin assignments yet — expected).

**Notes:**
- **LUT decrease (1,599 → 1,534):** The 3-stage `fp32_acc` pipeline breaks the combinational CARRY4 chain, reducing the amount of logic Vivado must route through a single level; slightly more efficient LUT packing results.
- **FF increase (417 → 534):** Expected — the 3-stage pipeline adds two register stages (`acc_en_d1/d2`, `partial_sum_r`) inside `fp32_acc`.
- **0 DSPs:** `bfloat16_mul` performs an 8×8 mantissa multiply in LUT fabric. Vivado did not infer a DSP48E1 because no `use_dsp` attribute is set and the operands are sub-16-bit.
- **0 BRAMs:** `weight_mem` DEPTH = 4 entries (16×4 = 64 bits) — well below the 512-bit RAMB18 threshold; synthesised to distributed RAM.
- Utilization remains very low — LLIU fits comfortably in the smallest Kintex-7 variant.

---

## 2. Timing Summary — 300 MHz Target

| Metric | Run 1 | Run 2 |
|--------|-------|-------|
| Target clock | 300 MHz (3.333 ns) | 300 MHz (3.333 ns) |
| WNS (setup) | **−6.188 ns** ❌ | **−2.322 ns** ❌ |
| TNS | −412.035 ns | −277.510 ns |
| Failing endpoints | 189 / 1,047 | 194 |
| WHS (hold) | +0.071 ns ✅ | +0.122 ns ✅ |
| Routing | Complete — 0 unrouted | Complete — 0 unrouted |
| Bitstream | Blocked: no LOC/IOSTANDARD | Blocked: no LOC/IOSTANDARD |

**Status: Timing NOT MET at 300 MHz.** The design is fully routed; only the bitstream step requires board pin assignments.

**Run 2 improvement:** WNS improved by **+3.866 ns** (from −6.188 → −2.322 ns) after pipelining `fp32_acc` to 3 stages. The `fp32_acc` is no longer the critical path.

---

## 3. Critical Path Analysis

### Run 1

**Worst path:** `u_dp_engine/u_acc/partial_sum_r_reg[28]/C` → `partial_sum_r_reg[2]/D`  
**Module:** `fp32_acc` (floating-point 32-bit accumulator)  
**Data path delay:** 9.228 ns (logic 2.490 ns / 27%, route 6.738 ns / 73%)  
**Logic levels:** 25 (CARRY4 ×10, LUT6 ×9, LUT5 ×3, LUT3 ×1, LUT2 ×2)  
**Slack:** −6.188 ns

$$f_{max}^{(1)} = \frac{1}{3.333 + 6.188\,\text{ns}} \approx 105\,\text{MHz}$$

### Run 2

**Worst path:** `u_parser/msg_buf_reg[19][1]/C` → `u_feat_extract/features_reg[2][3]/D`  
**Modules:** `itch_parser` → `itch_field_extract` → `feature_extractor`  
**Data path delay:** 5.604 ns (logic 1.818 ns / 32%, route 3.786 ns / 68%)  
**Logic levels:** 18 (CARRY4 ×7, LUT6 ×6, LUT5 ×2, LUT4 ×2, LUT1 ×1)  
**Slack:** −2.322 ns

The path traverses a 7-stage CARRY4 chain through `itch_field_extract` (field extraction arithmetic from raw ITCH message bytes) followed by multiple LUT levels in `feature_extractor`. The `fp32_acc` bottleneck is resolved; the new bottleneck is the combinational decode path from the ITCH message buffer to the feature registers.

$$f_{max}^{(2)} = \frac{1}{3.333 + 2.322\,\text{ns}} \approx 177\,\text{MHz}$$

---

## 4. Timing Closure Path

### Next RTL change: pipeline `itch_field_extract` output

The critical path enters `feature_extractor/features_reg` after passing combinationally through `itch_parser/msg_buf` → `itch_field_extract` arithmetic. Adding a register stage at the `itch_field_extract` boundary splits this path in two:

| Sub-path | Estimated delay after fix |
|----------|--------------------------|
| `msg_buf` → registered field outputs | ≈ 2.2–2.8 ns — within 3.333 ns |
| Registered field values → `features_reg` | ≈ 2.0–2.5 ns — within 3.333 ns |

**Latency impact:** +1 cycle to the ITCH parse-to-feature path only; the dot-product and output-buffer paths are unaffected. End-to-end latency target (< 12 cycles) remains well within budget.

**Escalate to:** `rtl_engineer` — register the `itch_field_extract` outputs at the module boundary and update `DOT_PRODUCT_LATENCY` / `RESULT_TIMEOUT` as needed.

| Option | Description | Estimated WNS after |
|--------|-------------|---------------------|
| **A — Register field_extract output** | Flop `itch_field_extract` port outputs; 1-cycle latency penalty | +2.0 to +2.5 ns → likely ≥ 0 at 300 MHz |
| **B — 250 MHz fallback** | Widen to 4.000 ns period; no RTL change | WNS ≈ 4.000 − 5.604 = −1.6 ns → still ❌ |
| **C — 200 MHz fallback** | Widen to 5.000 ns period; no RTL change | WNS ≈ 5.000 − 5.604 = −0.6 ns → close, check full TNS |

> **Recommendation:** Option A. Registering the `itch_field_extract` boundary is low risk and is standard practice for parser/compute datapath boundaries. No DV contract changes needed beyond a +1 cycle parse latency adjustment.

---

## 5. Bitstream Status

`write_bitstream` is blocked by DRC NSTD-1 and UCIO-1 — all 147 `lliu_top` AXI ports lack `IOSTANDARD` and `LOC` constraints. This is expected: `constraints_lliu_top.xdc` intentionally omits pin assignments because the target board has not been selected. A board-specific XDC append must be written once the physical board is identified.

The routed checkpoint (`syn/lliu_routed.dcp`) is complete and can be re-entered for bitstream generation after pin assignments are added.

---

## 6. Run Provenance

### Run 1

| File | SHA / Notes |
|------|-------------|
| `syn/vivado_impl.tcl` | commit `2f2098e` |
| `syn/constraints_lliu_top.xdc` | commit `2f2098e` — new file |
| `syn/reports/` | Reports from Run 1 archived in `reports/v1_dut/` |

### Run 2

| File | SHA / Notes |
|------|-------------|
| `syn/vivado_impl.tcl` | commit `b938747` (3-stage `fp32_acc`, PR #25) |
| `syn/constraints_lliu_top.xdc` | commit `b938747` — unchanged from Run 1 |
| `syn/reports/utilization_synth.txt` | Post-synthesis snapshot |
| `syn/reports/utilization.txt` | Post-implementation snapshot |
| `syn/reports/timing.txt` | `report_timing_summary -check_timing_verbose` |
| `syn/reports/vivado.log` | Full Vivado run log |
