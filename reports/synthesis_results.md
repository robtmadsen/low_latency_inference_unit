# LLIU Synthesis & P&R Results — xc7k160tffg676-2

**Updated:** 2026-04-05  
**Tool:** Vivado ML Standard v2025.2  
**Target:** `xc7k160tffg676-2` (Kintex-7, -2 speed grade)  
**Synthesis top:** `lliu_top` (LLIU inference core, AXI4-S + AXI4-Lite)  
**EC2 instance:** `c5.4xlarge` — IP `3.86.63.142`  
**Constraints:** `syn/constraints_lliu_top.xdc` (300 MHz clock on `clk`, false-path I/Os)  

---

## Run History

| Run | RTL commit | WNS | Critical path | Status |
|-----|-----------|-----|---------------|--------|
| 1 | `2f2098e` (fp32_acc 1-stage) | −6.188 ns | `fp32_acc` CARRY4 chain (25 levels) | ❌ |
| 2 | `b938747` (fp32_acc 3-stage) | −2.322 ns | `itch_parser`→`feature_extractor` (18 levels) | ❌ |
| 3 | `200bdc6` (itch_field_extract reg.) | −2.217 ns | `fp32_acc` feedback: `partial_sum_r`→`aligned_small_r` (11 levels) | ❌ |
| 4 | `223a498` (fp32_acc 4-stage) | −2.307 ns | `fp32_acc` Stage A1→B: add+normalize (14 levels) | ❌ |

---

## 1. Resource Utilization — Post-Implementation

| Resource | Run 1 | Run 2 | Run 3 | Run 4 | Available | Util% (Run 4) |
|----------|-------|-------|-------|-------|-----------|---------------|
| Slice LUTs | 1,599 | 1,534 | — | **1,466** | 101,400 | **1.45%** |
| Slice Registers (FFs) | 417 | 534 | — | **700** | 202,800 | **0.35%** |
| DSP48E1 | 0 | 0 | — | **0** | 600 | 0.00% |
| Block RAM Tile | 0 | 0 | — | **0** | 325 | 0.00% |
| IOB | 147¹ | 147¹ | — | **147¹** | 400 | — |

¹ 147 `lliu_top` AXI ports are unconstrained (no board pin assignments yet — expected).

¹ 147 `lliu_top` AXI ports are unconstrained (no board pin assignments yet — expected).
— Run 3 reports were not committed (EC2 run for diagnostic purposes only).

**Notes:**
- **LUT decrease (1,599 → 1,466 over four runs):** Each pipeline stage addition breaks a long combinational path; Vivado can pack the smaller per-stage logic more efficiently. The 4-stage `fp32_acc` (Run 4) removed ~70 LUTs vs Run 2 primarily through better DFG optimization.
- **FF increase (417 → 700 over four runs):** Expected — each new pipeline stage adds register banks. Run 4 added three more `acc_en_dN` delay registers plus the A0/A1 stage registers.
- **0 DSPs:** `bfloat16_mul` performs an 8×8 mantissa multiply in LUT fabric. Vivado did not infer a DSP48E1 because no `use_dsp` attribute is set and the operands are sub-16-bit.
- **0 BRAMs:** `weight_mem` DEPTH = 4 entries (16×4 = 64 bits) — well below the 512-bit RAMB18 threshold; synthesised to distributed RAM.
- Utilization remains very low — LLIU fits comfortably in the smallest Kintex-7 variant.

---

## 2. Timing Summary — 300 MHz Target

| Metric | Run 1 | Run 2 | Run 3 | Run 4 |
|--------|-------|-------|-------|-------|
| Target clock | 300 MHz | 300 MHz | 300 MHz | 300 MHz |
| WNS (setup) | **−6.188 ns** ❌ | **−2.322 ns** ❌ | **−2.217 ns** ❌ | **−2.307 ns** ❌ |
| TNS | −412.035 ns | −277.510 ns | — | −194.448 ns |
| Failing endpoints | 189 / 1,047 | 194 / (unknown) | — | 148 / 1,821 |
| WHS (hold) | +0.071 ns ✅ | +0.122 ns ✅ | — | +0.111 ns ✅ |
| Routing | Complete | Complete | Complete | Complete |
| Bitstream | Blocked (no LOC) | Blocked (no LOC) | — | Blocked (no LOC) |

**Status: Timing NOT MET at 300 MHz across all four runs.**

**Run 2:** WNS +3.866 ns improvement (fp32_acc 3-stage). Critical path moved to itch_parser→feature_extractor.
**Run 3:** WNS +0.105 ns improvement (itch_field_extract registered). Critical path moved back to fp32_acc feedback path.
**Run 4:** WNS −0.090 ns regression (fp32_acc 4-stage A0+A1 split). The 4-stage split did not help because the critical path is _within Stage B_ (mantissa add + normalize), not the A-stage feedback loop.

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

### Run 3

**Worst path:** `u_dp_engine/u_acc/partial_sum_r_reg[24]/C` → `u_dp_engine/u_acc/aligned_small_r_reg[0]/D`  
**Module:** `fp32_acc` — Stage B output feedback into Stage A (via `acc_fb` mux → exponent compare → alignment)  
**Data path delay:** 5.418 ns  
**Logic levels:** 11  
**Slack:** −2.217 ns

Registering the `itch_field_extract` outputs (PR #29) eliminated the itch-parse critical path. However, the hot-path now reverts to a _cross-stage feedback_ within `fp32_acc`: the accumulator result feeds back through the `acc_fb` mux (forwarding bypass) into the Stage-A exponent comparison and barrel-shift alignment logic. The forward data path from `partial_sum_r` to the next A-stage is the new bottleneck.

$$f_{max}^{(3)} = \frac{1}{3.333 + 2.217\,\text{ns}} \approx 180\,\text{MHz}$$

### Run 4

**Worst path:** `u_dp_engine/u_acc/aligned_small_r_reg[8]/C` (SLICE_X9Y125) → `u_dp_engine/u_acc/partial_sum_r_reg[19]/D` (SLICE_X6Y130)  
**Module:** `fp32_acc` — Stage A1 (barrel-shifted small mantissa) feeding into Stage B (mantissa add + normalize)  
**Data path delay:** 5.687 ns (logic 1.458 ns / **25.6%**, route 4.229 ns / **74.4%**)  
**Logic levels:** 14 (CARRY4 ×4, LUT4 ×3, LUT6 ×7)  
**Slack:** −2.307 ns

The 4-stage `fp32_acc` split removed the A-stage feedback from the critical path. The critical path is now _within Stage B_ — the mantissa add (CARRY4 chain) directly chained with the normalization logic (leading-zero detect mux tree) in a single clock cycle. Two high-fanout intermediate nets dominate the route delay:

| Signal | Fanout | Route delay |
|--------|--------|-------------|
| `sum_man_b1` | 27 | 0.472 ns |
| `sel0[6]` | 41 | 0.660 ns |

The normalization MUX tree (7 LUT6 levels) is spread across SLICE_X6Y126 – SLICE_X11Y134, causing substantial routing zigzag despite the small total logic. Route delay at 74% indicates a placement-driven problem.

$$f_{max}^{(4)} = \frac{1}{3.333 + 2.307\,\text{ns}} \approx 177\,\text{MHz}$$

---

## 4. Timing Closure Path

### Run 4 root-cause and next action

All four runs have exhibited WNS in the range −2.2 to −2.3 ns, and the critical path has shifted with each pipeline addition:

| Run | Fixed | New critical path |
|-----|-------|-------------------|
| 1→2 | fp32_acc CARRY4 monolithic block | itch_parser→feature_extractor combinational decode |
| 2→3 | itch_field_extract registered boundary | fp32_acc A-stage feedback (`partial_sum_r`→`acc_fb`→`aligned_small_r`) |
| 3→4 | fp32_acc A-stage split A0+A1 | fp32_acc Stage B: mantissa add + normalize combined (14 levels) |

The root cause is now the **Stage B add+normalize block**: a 24-bit mantissa add (CARRY4 chain) chained with a full normalization MUX tree (7× LUT6 levels) executed in one 3.333 ns clock cycle. This path has 1.458 ns of logic (14 levels) with 4.229 ns of routing, suggesting Vivado is spreading the normalization LUT tree across a wide placement region.

### Option A — Split Stage B into B0 + B1 (recommended)

**B0 (new):** Mantissa addition only → register the raw sum `sum_man_r` and carry flag `sum_ov_r`  
**B1 (old B):** Normalization (leading-zero detect, barrel-shift, exponent update) → register `partial_sum_r`

| Sub-path | Logic budget | Est. delay |
|----------|-------------|------------|
| A1→B0: aligned_small + big_man CARRY4 chain | 4 CARRY4 | ≈ 1.2–1.5 ns |
| B0→B1: normalization LUT tree only | 7 LUT6 levels | ≈ 1.0–1.4 ns |

**Latency impact:** +1 drain cycle. `DOT_PRODUCT_LATENCY = FEATURE_VEC_LEN + 4`. All DV latency bounds +1 again.

**Escalate to:** `rtl_engineer`

### Option B — PBLOCK placement constraint (backend alternative)

With 74% of path delay in routing, a tight PBLOCK forcing all `u_dp_engine/u_acc/*` cells into a compact region (≈ 12×12 slices) may reduce route delay sufficiently. If route delay drops from 4.229 ns to ≤ 1.9 ns while logic stays at 1.458 ns, the path would close (1.458 + 1.9 = 3.358 ns ≤ 3.333 ns is still marginal; would need ≤ 1.8 ns route).

This is a backend-only change (add to `syn/constraints_lliu_top.xdc`) and requires no DV updates. However, PBLOCK constraints are fragile: any logic growth in fp32_acc can cause placement overflow.

| Option | RTL change | DV change | Risk |
|--------|-----------|-----------|------|
| A — Split Stage B | Yes (+1 stage) | Yes (+1 latency bound) | Low — clean pipelining |
| B — PBLOCK | No | No | Medium — fragile if design grows |

**Recommendation:** Try Option B first (zero-cost trial run); if it closes, commit the PBLOCK. If not, escalate to Option A.

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
| `syn/reports/` | Reports archived in `reports/v1_dut/` |

### Run 3

| File | SHA / Notes |
|------|-------------|
| `syn/vivado_impl.tcl` | commit `200bdc6` (`itch_field_extract` registered, PR #29) |
| `syn/reports/` | Not committed — diagnostic run only; WNS −2.217 ns result captured in this document |

### Run 4

| File | SHA / Notes |
|------|-------------|
| `syn/vivado_impl.tcl` | commit `223a498` (fp32_acc 4-stage A0+A1 split, PR #31) |
| `syn/constraints_lliu_top.xdc` | commit `223a498` — unchanged from Run 1 |
| `syn/reports/utilization_synth.txt` | Post-synthesis snapshot |
| `syn/reports/utilization.txt` | Post-implementation snapshot |
| `syn/reports/timing.txt` | `report_timing_summary -check_timing_verbose` |
| `syn/reports/vivado.log` | Full Vivado run log |
