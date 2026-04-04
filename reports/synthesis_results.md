# LLIU Synthesis & P&R Results — xc7k160tffg676-2

**Updated:** 2026-04-04 (Run 10 — timing CLOSED ✅)  
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
| 6 | `37b9a42` (DSP48E1 `bfloat16_mul` + PBLOCK) | −2.142 ns | `itch_field_extract`→`feature_extractor`: price arithmetic (17 levels) | ❌ |
| 7 | `f2a062f` (feature_extractor 2-stage, PR #37) | −1.852 ns | `fp32_acc` Stage B: raw add + normalize combined (15 levels, 5.065 ns) | ❌ |
| 8 | `b65d3a8` (fp32_acc B1+B2 split, 5-stage) | −1.322 ns | `feature_extractor` Stage 2: CARRY4 magnitude + LUT normalization (14 levels, 4.584 ns) | ❌ |
| 9 | `106783d` (feature_extractor Stage 2→2a+2b, 3-stage) | −0.068 ns | `feature_extractor` Stage 2b: fo=24 routing on leading-zero net (7 levels, 3.390 ns, 83% route) | ❌ |
| **10** | **`f998742`** (post-route `phys_opt_design` + re-route) | **+0.001 ns** | — 0 endpoints failing — | **✅ CLOSED** |

---

## 1. Resource Utilization — Post-Implementation

| Resource | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | Run 6 | Run 10 | Available | Util% (Run 10) |
|----------|-------|-------|-------|-------|-------|-------|--------|-----------|----------------|
| Slice LUTs | 1,599 | 1,534 | — | 1,466 | 1,460 | 1,378 | **1,172** | 101,400 | **1.16%** |
| Slice Registers (FFs) | 417 | 534 | — | 700 | 697 | 706 | **932** | 202,800 | **0.46%** |
| DSP48E1 | 0 | 0 | — | 0 | 0 | 1 | **1** | 600 | **0.17%** |
| Block RAM Tile | 0 | 0 | — | 0 | 0 | 0 | **0** | 325 | **0.00%** |
| IOB | 147¹ | 147¹ | — | 147¹ | 147¹ | 147¹ | **147¹** | 400 | — |

¹ 147 `lliu_top` AXI ports are unconstrained (no board pin assignments yet — expected).  
— Run 3 reports were not committed (EC2 diagnostic run only). Runs 7–9 reports were overwritten by Run 10.

**Notes:**
- **LUT trend (1,599 → 1,172 over ten runs):** Each pipeline stage addition breaks a long combinational path; Vivado packs smaller per-stage logic more efficiently. The largest single-run drop (1,460 → 1,378) came from replacing the 8×8 CARRY4 multiply chain with DSP48E1 (Run 6). Runs 7–10 added further pipeline registers, creating the additional ~200 LUT reduction through better Vivado packing of shorter combinational cones.
- **FF trend (417 → 932):** Reflects all pipeline stage additions across Runs 1–10. Each new `_r` or `_r2` bank adds FF registers. Run 10 also adds phys_opt register-duplication cells.
- **1 DSP48E1:** `bfloat16_mul` maps its 8×8 mantissa multiply to DSP48E1 via `(* use_dsp = "yes" *)` (PR #35); unchanged through Run 10.
- **0 BRAMs:** `weight_mem` DEPTH = 4 entries — well below the RAMB18 threshold; synthesised to distributed RAM.
- Utilization remains very low — LLIU fits comfortably in the smallest Kintex-7 variant.

---

## 2. Timing Summary — 300 MHz Target

| Metric | Run 1 | Run 2 | Run 3 | Run 4 | Run 5 | Run 6 | Run 7 | Run 8 | Run 9 | **Run 10** |
|--------|-------|-------|-------|-------|-------|-------|-------|-------|-------|------------|
| Target clock | 300 MHz | 300 MHz | 300 MHz | 300 MHz | 300 MHz | 300 MHz | 300 MHz | 300 MHz | 300 MHz | **300 MHz** |
| WNS (setup) | −6.188 ns ❌ | −2.322 ns ❌ | −2.217 ns ❌ | −2.307 ns ❌ | −2.251 ns ❌ | −2.142 ns ❌ | −1.852 ns ❌ | −1.322 ns ❌ | −0.068 ns ❌ | **+0.001 ns ✅** |
| TNS | −412.035 ns | −277.510 ns | — | −194.448 ns | −183.136 ns | −108.576 ns | −74.973 ns | −27.520 ns | −0.172 ns | **0.000 ns** |
| Failing endpoints | 189 / 1,047 | 194 | — | 148 / 1,821 | 122 / 1,821 | 109 / 1,849 | 94 / 2,284 | 43 / 2,284 | 4 / 2,532 | **0 / 2,532** |
| WHS (hold) | +0.071 ns ✅ | +0.122 ns ✅ | — | +0.111 ns ✅ | +0.082 ns ✅ | +0.080 ns ✅ | +0.056 ns ✅ | +0.094 ns ✅ | +0.079 ns ✅ | **+0.079 ns ✅** |
| Routing | Complete | Complete | Complete | Complete | Complete | Complete | Complete | Complete | Complete | **Complete** |
| Bitstream | Blocked (no LOC) | Blocked (no LOC) | — | Blocked (no LOC) | Blocked (no LOC) | Blocked (no LOC) | Blocked (no LOC) | Blocked (no LOC) | Blocked (no LOC) | **Blocked (no LOC)** |

**Status: Timing CLOSED at 300 MHz in Run 10. WNS +0.001 ns, 0 failing endpoints, 0 failing hold endpoints.**

**PBLOCK effect (Run 4 → Run 5):** Failing endpoints reduced 148 → 122 (−26), TNS reduced −194.4 → −183.1 ns (−11.3 ns). fp32_acc was successfully removed as the critical path; critical path moved to `bfloat16_mul` mantissa multiply. WNS improved only 0.056 ns because the failing-endpoint population is broad (many paths at ~2.25 ns slack).

**DSP48 effect (Run 5 → Run 6):** TNS reduced −183.1 → −108.6 ns (−74.5 ns, 41% improvement). Failing endpoints reduced 122 → 109 (−13). The mantissa-multiply population is eliminated; the 1 DSP48E1 runs cleanly. WNS improved only 0.109 ns because the new bottleneck (`feature_extractor` price arithmetic, 8×CARRY4) was already queued at similar slack behind the now-removed bfloat16_mul path.

**Pattern:** Each run has WNS in the range −2.1 to −2.3 ns. Fixing individual paths consistently reveals the next queued path at similar slack. The design's achievable frequency in LUT/CARRY4 fabric is ≈ 180 MHz (period = 3.333 + 2.14 = 5.47 ns). Closing at 300 MHz requires further pipelining of the arithmetic-heavy modules.

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

### Run 6

**Worst path:** `u_parser/u_field_extract/price_reg[0]/C` (SLICE_X15Y83) → `u_feat_extract/features_reg[0][0]/D` (SLICE_X13Y88)  
**Modules:** `itch_field_extract` → `feature_extractor` (price field-to-feature arithmetic)  
**Data path delay:** 5.453 ns (logic 1.803 ns / 33.1%, route 3.650 ns / 66.9%)  
**Logic levels:** 17 (CARRY4×8, LUT6×4, LUT5×3, LUT4×1, LUT1×1)  
**Slack:** −2.142 ns

The DSP48 change (PR #35) successfully eliminated `bfloat16_mul` from the critical path; 1 DSP48E1 is confirmed in utilization and TNS dropped 41%. The new worst path is the combinational price-field arithmetic inside `feature_extractor`. Starting from the registered `price_reg` output (registered since PR #29), the path traverses 8 chained CARRY4s computing the scaled price feature, followed by LUT merge logic into `features_reg`. This is structurally identical to the Run 2 path (18 levels, −2.322 ns) — the `itch_field_extract` register boundary removed one hierarchy hop, leaving 17 levels at effectively the same slack.

**Root cause:** The price-to-feature arithmetic (CARRY4×8 + LUT fan-out) in `feature_extractor` forms a 5.453 ns combinational cloud from the registered `price_reg` output to `features_reg`. No intermediate register breaks this path. Route delay (66.9%) dominates, indicating a sub-optimal placement spread across the fabric.

$$f_{max}^{(6)} = \frac{1}{3.333 + 2.142\,\text{ns}} \approx 182\,\text{MHz}$$

### Run 7

**Worst path:** `u_dp_engine/u_acc/aligned_small_r_reg[9]/C` (SLICE_X6Y146) → `u_dp_engine/u_acc/partial_sum_r_reg[26]/D` (SLICE_X6Y153)  
**Module:** `fp32_acc` — Stage B: 25-bit mantissa add/subtract (CARRY4×6) immediately chained with normalization priority encoder (LUT×9)  
**Data path delay:** 5.065 ns (logic 1.597 ns / 31.5%, route 3.468 ns / 68.5%)  
**Logic levels:** 15 (CARRY4×6, LUT6×5, LUT4×3, LUT2×1)  
**Slack:** −1.852 ns (TNS −74.973 ns, 94 failing endpoints)  
**High-fanout bottlenecks:** `sum_man_b1` (fo=26, 0.478 ns route), `sel0[13]` (fo=47, 0.453 ns route)

The `feature_extractor` 2-stage pipelining (PR #37) moved the critical path back to `fp32_acc`, where Stage B still combines the raw mantissa adder and the full normalization tree in a single cycle.

$$f_{max}^{(7)} = \frac{1}{3.333 + 1.852\,\text{ns}} \approx 193\,\text{MHz}$$

### Run 8

**Worst path:** `u_feat_extract/price_delta_r_reg[0]_replica_1/C` → `u_feat_extract/features_reg[0][0]/D`  
**Module:** `feature_extractor` — Stage 2: two's-complement magnitude (CARRY4×5) directly chained with leading-zero priority encoder (LUT5×2, LUT6×6)  
**Data path delay:** 4.584 ns (logic 1.312 ns / 28.6%, route 3.272 ns / 71.4%)  
**Logic levels:** 14 (CARRY4×5, LUT5×2, LUT6×6, LUT1×1)  
**Slack:** −1.322 ns (TNS −27.520 ns, 43 failing endpoints)

Splitting `fp32_acc` Stage B into B1 (adder) + B2 (normalize) resolved that bottleneck. The new critical path is structurally identical: `feature_extractor` Stage 2 computes magnitude via CARRY4 negation and then runs the full `int_to_bf16` leading-zero tree in the same clock cycle.

$$f_{max}^{(8)} = \frac{1}{3.333 + 1.322\,\text{ns}} \approx 215\,\text{MHz}$$

### Run 9

**Worst path:** `u_feat_extract/mag3_r2_reg[25]/C` (SLICE_X14Y116) → `u_feat_extract/features_reg[3][5]/D` (SLICE_X16Y112)  
**Module:** `feature_extractor` — Stage 2b: leading-zero priority encoder reading from registered magnitude  
**Data path delay:** 3.390 ns (logic 0.560 ns / 16.5%, route 2.830 ns / 83.5%)  
**Logic levels:** 7 (LUT3×1, LUT5×1, LUT6×5)  
**Key bottleneck:** `features[3][11]_i_4` net (fo=24, 0.542 ns route)  
**Slack:** −0.068 ns (TNS −0.172 ns, only 4 failing endpoints)

Splitting Stage 2 into 2a (magnitude) + 2b (normalize) reduced the logic depth to 7 LUT levels (0.560 ns). The path is now 83.5% routing — a placement-driven problem, not a logic-depth problem. The solver placed `mag3_r2_reg` and `features_reg` in different CLB columns, making the fo=24 intermediate net span 4 CLB rows.

$$f_{max}^{(9)} \approx \frac{1}{3.333 + 0.068\,\text{ns}} \approx 294\,\text{MHz}$$

### Run 10 — **TIMING CLOSED** ✅

**Best (worst) path:** No VIOLATED paths. Only MET paths reported.  
**WNS:** +0.001 ns (setup) / +0.079 ns (hold)  
**TNS:** 0.000 ns — 0 failing endpoints out of 2,532 total  
**Key fix:** Post-route `phys_opt_design -directive AggressiveExplore` replicated the high-fanout fo=24 `features[3][11]_i_4` driver and redistributed the loads across adjacent CLBs, reducing the worst route delay below ~2.8 ns. A subsequent `route_design -directive NoTimingRelaxation` sealed the tight hold margin.

**Final pipeline latency:** 18 cycles (AXI4-S last beat → `dp_result_valid`) at 300 MHz = 60 ns end-to-end.

$$f_{max}^{(10)} > 300\,\text{MHz}\;\text{(WNS > 0)}$$

---

## 4. Timing Closure Path

### Summary of all six runs

Every run has produced WNS in the range −2.1 to −2.3 ns. Each fix moves the critical path to a different sub-module but does not reduce the overall failing-endpoint population proportionally — the achievable frequency in LUT/CARRY4 fabric is ≈ 180–182 MHz.

| Run | Fix applied | New critical path |
|-----|------------|-------------------|
| 1→2 | fp32_acc monolithic → 3-stage pipeline | itch_parser→feature_extractor combinational decode |
| 2→3 | itch_field_extract registered boundary | fp32_acc A-stage feedback (partial_sum_r→acc_fb→aligned_small_r) |
| 3→4 | fp32_acc A-stage split A0+A1 | fp32_acc Stage B: mantissa add + normalize combined |
| 4→5 | PBLOCK to compact fp32_acc placement | weight_mem→bfloat16_mul: 8×8 mantissa multiply (CARRY4×6) |
| 5→6 | DSP48E1 for `bfloat16_mul` + PBLOCK retained | `itch_field_extract`→`feature_extractor`: price arithmetic (CARRY4×8, 17 levels) |
| 6→7 | `feature_extractor` 2-stage pipeline (PR #37) | `fp32_acc` Stage B: adder + normalize combined (15 levels, 5.065 ns) |
| 7→8 | `fp32_acc` Stage B → B1 (adder) + B2 (normalize) | `feature_extractor` Stage 2: CARRY4 magnitude + LUT normalization (14 levels) |
| 8→9 | `feature_extractor` Stage 2 → 2a (magnitude) + 2b (normalize) | fo=24 routing on `features[3][11]_i_4` net (7 levels, 83% route) |
| 9→10 | Post-route `phys_opt_design` + re-route | **TIMING CLOSED** — 0 failing endpoints |

### Status: CLOSED ✅

**300 MHz timing closed at Run 10.** WNS +0.001 ns, TNS 0.000 ns, 0 failing endpoints (setup and hold).

The final fix was not an RTL change but an implementation strategy change: adding a **post-route** `phys_opt_design -directive AggressiveExplore` pass after `route_design`. Vivado's pre-route phys_opt (already present from Run 1) does not have visibility into final routing congestion; the post-route pass can replicate high-fanout cell outputs into new LEs placed nearer their loads. The fo=24 `features[3][11]_i_4` intermediate net in `feature_extractor` Stage 2b was the sole remaining bottleneck at Run 9, with 7 logic levels (0.560 ns) and 2.830 ns routing. Post-route replication shrank the worst route delay sufficiently to achieve WNS +0.001 ns.

**Final pipeline latency budget (18 cycles at 300 MHz = 60 ns):**

| Module | Latency |
|--------|---------|
| `itch_parser` | 1 cy |
| `itch_field_extract` | 1 cy |
| `feature_extractor` | 3 cy |
| `dot_product_engine` (VEC_LEN=4 MACs + 5 drain) | 9 cy |
| `output_buffer` | 1 cy |
| `lliu_top` AXI overhead | 3 cy |
| **Total** | **18 cy** |

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

### Run 6

| File | SHA / Notes |
|------|-------------|
| `rtl/bfloat16_mul.sv` | commit `37b9a42` — 2-stage DSP48E1 pipeline (PR #35) |
| `rtl/dot_product_engine.sv` | commit `37b9a42` — 5-cycle drain, `feature_valid_d2` |
| `rtl/lliu_pkg.sv` | commit `37b9a42` — `DOT_PRODUCT_LATENCY = FEATURE_VEC_LEN + 4` |
| `syn/constraints_lliu_top.xdc` | commit `37b9a42` — PBLOCK `pblock_fp32acc` retained from Run 5 |
| `syn/reports/utilization_synth.txt` | Post-synthesis snapshot |
| `syn/reports/utilization.txt` | Post-implementation snapshot |
| `syn/reports/timing.txt` | `report_timing_summary -check_timing_verbose` |
| `syn/reports/vivado.log` | Full Vivado run log |

### Runs 7–9

Reports for Runs 7–9 were overwritten on EC2 by Run 10. WNS/TNS/endpoint data captured in this document from live SSH queries during iterative closure.

| Run | Key RTL commit | Notes |
|-----|---------------|-------|
| 7 | `f2a062f` (PR #37 — feature_extractor 2-stage) | feature_extractor 2-stage added; see PR #37 |
| 8 | `b65d3a8` (feat/timing-closure — fp32_acc B1+B2) | fp32_acc 5-stage: drain extended to 6 cycles; `DOT_PRODUCT_LATENCY = FEATURE_VEC_LEN + 5` |
| 9 | `106783d` (feat/timing-closure — feature_extractor 3-stage) | feature_extractor Stage 2 split into 2a+2b; 3-stage total |

### Run 10 — **FINAL (TIMING CLOSED)** ✅

| File | SHA / Notes |
|------|-------------|
| `syn/vivado_impl.tcl` | commit `f998742` — post-route `phys_opt_design -directive AggressiveExplore` + `route_design -directive NoTimingRelaxation` added |
| `rtl/fp32_acc.sv` | commit `b65d3a8` — 5-stage pipeline (A0, A1, B1, B2, C) |
| `rtl/feature_extractor.sv` | commit `106783d` — 3-stage pipeline (Stage 1 integer arith, Stage 2a magnitude, Stage 2b normalize) |
| `rtl/dot_product_engine.sv` | commit `b65d3a8` — 6-cycle drain (drain_cnt 0→5) |
| `rtl/lliu_pkg.sv` | commit `b65d3a8` — `DOT_PRODUCT_LATENCY = FEATURE_VEC_LEN + 5` |
| `syn/constraints_lliu_top.xdc` | commit `b65d3a8` — PBLOCK `pblock_fp32acc` retained |
| `syn/reports/utilization_synth.txt` | Post-synthesis snapshot (Run 10) |
| `syn/reports/utilization.txt` | Post-implementation snapshot — 1,172 LUTs, 932 FFs, 1 DSP48E1 |
| `syn/reports/timing.txt` | `report_timing_summary -check_timing_verbose` — WNS +0.001 ns, 0 failing |
| `syn/reports/vivado.log` | Full Vivado run log |
