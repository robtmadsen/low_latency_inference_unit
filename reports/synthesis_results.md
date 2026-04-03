# LLIU Synthesis & P&R Results — xc7k160tffg676-2

**Updated:** 2026-04-03  
**Tool:** Vivado ML Standard v2025.2  
**Target:** `xc7k160tffg676-2` (Kintex-7, -2 speed grade)  
**Synthesis top:** `lliu_top` (LLIU inference core, AXI4-S + AXI4-Lite)  
**EC2 instance:** `c5.4xlarge` — IP `3.86.63.142`  
**Constraints:** `syn/constraints_lliu_top.xdc` (300 MHz clock on `clk`, false-path I/Os)  

---

## 1. Resource Utilization (Post-Implementation)

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| Slice LUTs | **1,599** | 101,400 | **1.58%** |
| Slice Registers (FFs) | **417** | 202,800 | **0.21%** |
| DSP48E1 | **0** | 600 | 0.00% |
| Block RAM Tile | **0** | 325 | 0.00% |
| IOB | 147¹ | 400 | — |

¹ 147 `lliu_top` AXI ports are unconstrained (no board pin assignments yet — expected).

**Notes:**
- **0 DSPs:** `bfloat16_mul` performs an 8×8 mantissa multiply in LUT fabric. Vivado did not infer a DSP48E1 because no `use_dsp` attribute is set and the operands are sub-16-bit.
- **0 BRAMs:** `weight_mem` DEPTH = 4 entries (16×4 = 64 bits) — well below the 512-bit RAMB18 threshold; synthesised to distributed RAM.
- Utilization is very low — the LLIU core fits comfortably in the smallest Kintex-7 variant.

---

## 2. Timing Summary — 300 MHz Target

| Metric | Value |
|--------|-------|
| Target clock | `sys_clk` = 300 MHz (3.333 ns) |
| WNS (setup) | **−6.188 ns** ❌ |
| TNS | −412.035 ns |
| Failing endpoints | 189 / 1,047 |
| WHS (hold) | +0.071 ns ✅ |
| THS | 0.000 ns (no hold violations) |
| Routing | **Complete — 0 unrouted nets** |
| Bitstream | Blocked: no board IOSTANDARD/LOC (expected) |

**Status: Timing NOT MET at 300 MHz.** The design is fully routed; only the bitstream step requires board pin assignments.

---

## 3. Critical Path Analysis

**Worst path:** `u_dp_engine/u_acc/partial_sum_r_reg[28]/C` → `partial_sum_r_reg[2]/D`  
**Module:** `fp32_acc` (floating-point 32-bit accumulator)  
**Data path delay:** 9.228 ns (logic 2.490 ns, route 6.738 ns)  
**Logic levels:** 25 (CARRY4 ×10, LUT6 ×9, LUT5 ×3, LUT3 ×1, LUT2 ×2)  
**Required:** 3.333 ns → **Slack: −6.188 ns**

The 10× CARRY4 ripple-carry chain inside `fp32_acc` is the bottleneck.  
The 32-bit FP mantissa accumulation is fully unrolled combinationally in a single cycle.

### Equivalent maximum frequency
$$f_{max} = \frac{1}{3.333\,\text{ns} + 6.188\,\text{ns}} = \frac{1}{9.521\,\text{ns}} \approx 105\,\text{MHz}$$

---

## 4. Timing Closure Path

To meet 300 MHz timing, the critical paths in `fp32_acc` must be broken. Options (for the RTL engineer):

| Option | Description | Estimated gain |
|--------|-------------|----------------|
| **A — Pipeline fp32_acc** | Add 1–2 register stages inside the 32-bit mantissa adder; split the 10× CARRY4 chain | ~+6 ns WNS (likely closes 300 MHz) |
| **B — DSP48E1 for accumulation** | Route the 32-bit accumulation through DSP48E1 P-register for free pipelining | +6–8 ns |
| **C — 250 MHz fallback** | Widen the clock period to 4.000 ns (250 MHz); no RTL change needed | WNS ≈ −2.2 ns → still ❌; need ~200 MHz |
| **D — 200 MHz** | 5 ns period → WNS ≈ +0.7 ns — likely meets timing with margin | Latency contract: < 12 cycles @ 200 MHz (60 ns, within 80 ns target) |

> **Recommendation:** Option A (pipeline `fp32_acc`) is the highest-leverage fix.  
> A single pipeline register after the mantissa addition closes the critical path without restructuring the dot-product control flow. Escalate to `rtl_engineer`.

---

## 5. Bitstream Status

`write_bitstream` is blocked by DRC NSTD-1 and UCIO-1 — all 147 `lliu_top` AXI ports lack `IOSTANDARD` and `LOC` constraints. This is expected: `constraints_lliu_top.xdc` intentionally omits pin assignments because the target board has not been selected. A board-specific XDC append must be written once the physical board is identified.

The routed checkpoint (`syn/lliu_routed.dcp`) is complete and can be re-entered for bitstream generation after pin assignments are added.

---

## 6. Run Provenance

| File | SHA / Notes |
|------|-------------|
| `syn/vivado_impl.tcl` | commit `2f2098e` |
| `syn/constraints_lliu_top.xdc` | commit `2f2098e` — new file |
| `syn/reports/utilization_synth.txt` | Post-synthesis snapshot |
| `syn/reports/utilization.txt` | Post-implementation snapshot |
| `syn/reports/timing.txt` | `report_timing_summary -check_timing_verbose` |
| `syn/reports/vivado.log` | Full Vivado run log |
