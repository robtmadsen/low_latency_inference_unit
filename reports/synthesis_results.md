# LLIU Synthesis & P&R Results — xc7k160tffg676-2

**Updated:** 2026-04-05  
**Tool:** Vivado ML Standard v2025.2  
**Target:** `xc7k160tffg676-2` (Kintex-7, -2 speed grade)  
**Synthesis top:** `lliu_top` (LLIU inference core, AXI4-S + AXI4-Lite)  
**EC2 instance:** `c5.4xlarge` — IP `3.86.63.142`  
**Constraints:** `syn/constraints_lliu_top.xdc` (300 MHz clock on `clk`, false-path I/Os; PBLOCK `pblock_fp32acc` added Run 5)  

---

## Run History

| Run | RTL commit | WNS | Critical path | Status |
|-----|-----------|-----|---------------|--------|
| 1 | `2f2098e` (fp32_acc 1-stage) | −6.188 ns | `fp32_acc` CARRY4 chain (25 levels) | ❌ |
| 2 | `b938747` (fp32_acc 3-stage) | −2.322 ns | `itch_parser`→`feature_extractor` (18 levels) | ❌ |
| 3 | `200bdc6` (itch_field_extract reg.) | −2.217 ns | `fp32_acc` feedback: `partial_sum_r`→`aligned_small_r` (11 levels) | ❌ |
| 4 | `223a498` (fp32_acc 4-stage) | −2.307 ns | `fp32_acc` Stage A1→B: add+normalize (14 levels) | ❌ |
| 5 | `6b03819` (PBLOCK `u_dp_engine/u_acc/*`) | −2.251 ns | `weight_mem`→`bfloat16_mul`: mantissa multiply (13 levels) | ❌ |

---

## 1. Resource Utilization — Post-Implementation

| Resource | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | Available | Util% (Run 5) |
|----------|-------|-------|-------|-------|-------|-----------|---------------|
| Slice LUTs | 1,599 | 1,534 | — | 1,466 | **1,460** | 101,400 | **1.44%** |
| Slice Registers (FFs) | 417 | 534 | — | 700 | **697** | 202,800 | **0.34%** |
| DSP48E1 | 0 | 0 | — | 0 | **0** | 600 | 0.00% |
| Block RAM Tile | 0 | 0 | — | 0 | **0** | 325 | 0.00% |
| IOB | 147¹ | 147¹ | — | 147¹ | **147¹** | 400 | — |

¹ 147 `lliu_top` AXI ports are unconstrained (no board pin assignments yet — expected).

¹ 147 `lliu_top` AXI ports are unconstrained (no board pin assignments yet — expected).  
— Run 3 reports were not committed (EC2 diagnostic run only).

**Notes:**
- **LUT trend (1,599 → 1,460 over five runs):** Each pipeline stage addition breaks a long combinational path; Vivado packs smaller per-stage logic more efficiently. The PBLOCK (Run 5) reduced LUTs slightly (1,466 → 1,460) through improved placement quality.
- **FF trend (417 → 697):** Each new pipeline stage adds register banks. Run 4 added A0/A1 registers inside `fp32_acc`; Run 5 PBLOCK caused marginal FF reduction (700 → 697) through Vivado register merging.
- **0 DSPs:** `bfloat16_mul` performs an 8×8 mantissa multiply in LUT/CARRY4 fabric. No `use_dsp` attribute is set; operands are sub-16-bit so Vivado does not infer DSP48E1 automatically. **This is the primary remaining timing bottleneck (see Section 4).**
- **0 BRAMs:** `weight_mem` DEPTH = 4 entries (16×4 = 64 bits) — well below the 512-bit RAMB18 threshold; synthesised to distributed RAM.
- Utilization remains very low — LLIU fits comfortably in the smallest Kintex-7 variant.

---

## 2. Timing Summary — 300 MHz Target

| Metric | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 |
|--------|-------|-------|-------|-------|-------|
| Target clock | 300 MHz | 300 MHz | 300 MHz | 300 MHz | 300 MHz |
| WNS (setup) | **−6.188 ns** ❌ | **−2.322 ns** ❌ | **−2.217 ns** ❌ | **−2.307 ns** ❌ | **−2.251 ns** ❌ |
| TNS | −412.035 ns | −277.510 ns | — | −194.448 ns | −183.136 ns |
| Failing endpoints | 189 / 1,047 | 194 | — | 148 / 1,821 | 122 / 1,821 |
| WHS (hold) | +0.071 ns ✅ | +0.122 ns ✅ | — | +0.111 ns ✅ | +0.082 ns ✅ |
| Routing | Complete | Complete | Complete | Complete | Complete |
| Bitstream | Blocked (no LOC) | Blocked (no LOC) | — | Blocked (no LOC) | Blocked (no LOC) |

**Status: Timing NOT MET at 300 MHz across all five runs.**

**PBLOCK effect (Run 4 → Run 5):** Failing endpoints reduced 148 → 122 (−26), TNS reduced −194.4 → −183.1 ns (−11.3 ns). fp32_acc was successfully removed as the critical path; critical path moved to `bfloat16_mul` mantissa multiply. WNS improved only 0.056 ns because the failing-endpoint population is broad (many paths at ~2.25 ns slack).

**Pattern:** Each run has WNS in the range −2.2 to −2.3 ns. Fixing individual paths consistently reveals the next queued path at similar slack. The design's achievable frequency in LUT/CARRY4 fabric is ≈ 180 MHz (period = 3.333 + 2.25 = 5.58 ns). Closing at 300 MHz requires architectural changes, not incremental pipelining.

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

Registering the `itch_field_extract` outputs (PR #29) eliminated the itch-parse critical path. However, the hot-path reverts to a _cross-stage feedback_ within `fp32_acc`: the accumulator result feeds back through the `acc_fb` mux (forwarding bypass) into the Stage-A exponent comparison and barrel-shift alignment logic.

$$f_{max}^{(3)} = \frac{1}{3.333 + 2.217\,\text{ns}} \approx 180\,\text{MHz}$$

### Run 4

**Worst path:** `u_dp_engine/u_acc/aligned_small_r_reg[8]/C` (SLICE_X9Y125) → `u_dp_engine/u_acc/partial_sum_r_reg[19]/D` (SLICE_X6Y130)  
**Module:** `fp32_acc` — Stage A1 (barrel-shifted small mantissa) feeding into Stage B (mantissa add + normalize)  
**Data path delay:** 5.687 ns (logic 1.458 ns / 25.6%, route 4.229 ns / 74.4%)  
**Logic levels:** 14 (CARRY4×4, LUT4×3, LUT6×7)  
**Slack:** −2.307 ns

The 4-stage `fp32_acc` split removed the A-stage feedback from the critical path. The critical path is now _within Stage B_ — mantissa add (CARRY4 chain) directly chained with normalization logic (leading-zero detect MUX tree) in a single clock cycle. Two high-fanout intermediate nets dominate the route delay:

| Signal | Fanout | Route delay |
|--------|--------|-------------|
| `sum_man_b1` | 27 | 0.472 ns |
| `sel0[6]` | 41 | 0.660 ns |

$$f_{max}^{(4)} = \frac{1}{3.333 + 2.307\,\text{ns}} \approx 177\,\text{MHz}$$

### Run 5

**Worst path:** `u_weight_mem/rd_data_reg[0]/C` (SLICE_X7Y125) → `u_dp_engine/u_mul/result_reg[15]/R` (SLICE_X1Y129)  
**Modules:** `weight_mem` → `bfloat16_mul` (8×8 mantissa multiply → result-zero reset logic)  
**Data path delay:** 5.208 ns (logic 1.910 ns / 36.7%, route 3.298 ns / 63.3%)  
**Logic levels:** 13 (CARRY4×6, LUT4×2, LUT5×2, LUT6×3)  
**Slack:** −2.251 ns

The PBLOCK successfully compacted `fp32_acc` cells and removed it from the critical path (failing endpoints: 148 → 122). The new worst path is the 8×8 unsigned mantissa multiply inside `bfloat16_mul`, implemented in LUT/CARRY4 fabric. The path terminates at the synchronous reset pin of a result register — this is the end-of-multiply zero-detection logic. With 6 CARRY4 stages in the multiply chain plus additional correction logic, the combinational logic alone is 1.910 ns with no room for further route-delay reduction below the 3.333 ns budget.

**Root cause:** 8×8 LUT multiply is inherently a ≈2-cycle operation at 300 MHz. Vivado did not infer DSP48E1 (8-bit operands fall below the automatic inference threshold). DSP48E1 can perform this multiply in a single registered cycle well above 400 MHz on Kintex-7 -2.

$$f_{max}^{(5)} = \frac{1}{3.333 + 2.251\,\text{ns}} \approx 180\,\text{MHz}$$

---

## 4. Timing Closure Path

### Summary of all five runs

Every run has produced WNS in the range −2.2 to −2.3 ns. Each RTL or constraint fix has moved the critical path to a different sub-module, but the population of failing paths (≥ 122 endpoints) means no single-path fix will close timing — the achievable frequency in pure LUT/CARRY4 fabric is ≈ 180 MHz.

| Run | Fix applied | New critical path |
|-----|------------|-------------------|
| 1→2 | fp32_acc monolithic → 3-stage pipeline | itch_parser→feature_extractor combinational decode |
| 2→3 | itch_field_extract registered boundary | fp32_acc A-stage feedback (partial_sum_r→acc_fb→aligned_small_r) |
| 3→4 | fp32_acc A-stage split A0+A1 | fp32_acc Stage B: mantissa add + normalize combined |
| 4→5 | PBLOCK to compact fp32_acc placement | weight_mem→bfloat16_mul: 8×8 mantissa multiply (CARRY4×6) |

### Next action: DSP48E1 for `bfloat16_mul` mantissa multiply

**Root cause:** Kintex-7 DSP48E1 is purpose-built for multiplications up to 18×18 bits and can run well above 400 MHz at -2 speed grade. The bfloat16 mantissa multiply (8×8 unsigned) fits trivially. Vivado did not infer DSP48E1 automatically because the operands are sub-16-bit.

**Fix:** Add `(* use_dsp = "yes" *)` attribute to the mantissa product computation in `bfloat16_mul.sv`, and pipeline the multiply with one register stage (DSP48E1 PREG=1). This eliminates the 6-stage CARRY4 chain entirely.

**Latency impact:** +1 cycle to the `bfloat16_mul` pipeline → `DOT_PRODUCT_LATENCY = FEATURE_VEC_LEN + 4`. All DV latency bounds +1 again.

| Sub-path after fix | Estimated delay |
|--------------------|----------------|
| weight_mem → DSP48E1 input | ≈ 0.5–0.8 ns (registered input, short route) |
| DSP48E1 multiply (registered PREG=1) | ≈ 1.5–2.0 ns (well within 3.333 ns) |

With DSP for the multiply and the PBLOCK keeping fp32_acc compact, the design should close 300 MHz or reveal the next critical path at significantly better slack than the current −2.25 ns.

**Escalate to:** `rtl_engineer` — add `use_dsp` attribute and pipeline register to `bfloat16_mul`, update `dot_product_engine` to accommodate the +1 cycle, update `lliu_pkg` `DOT_PRODUCT_LATENCY = FEATURE_VEC_LEN + 4`.

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
| `syn/reports/` | Not committed — diagnostic run only; WNS −2.217 ns captured in this document |

### Run 4

| File | SHA / Notes |
|------|-------------|
| `syn/vivado_impl.tcl` | commit `223a498` (fp32_acc 4-stage A0+A1 split, PR #31) |
| `syn/constraints_lliu_top.xdc` | commit `223a498` — unchanged from Run 1 |
| `syn/reports/` | Superseded by Run 5; WNS −2.307 ns data retained in this document |

### Run 5

| File | SHA / Notes |
|------|-------------|
| `syn/vivado_impl.tcl` | commit `6b03819` (PBLOCK `pblock_fp32acc`, PR #34) |
| `syn/constraints_lliu_top.xdc` | commit `6b03819` — PBLOCK added |
| `syn/reports/utilization_synth.txt` | Post-synthesis snapshot |
| `syn/reports/utilization.txt` | Post-implementation snapshot |
| `syn/reports/timing.txt` | `report_timing_summary -check_timing_verbose` |
| `syn/reports/vivado.log` | Full Vivado run log |
