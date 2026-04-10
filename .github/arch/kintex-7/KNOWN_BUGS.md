# LLIU — Known RTL Bugs

> **Updated:** 2026-04-10  
> **Scope:** Active bugs confirmed by cocotb regression failures; awaiting RTL fix.

---

## BUG-001 — `fp32_acc` pipeline hazard causes wrong dot products

| Field | Detail |
|-------|--------|
| **Severity** | Critical — all dot-product results are incorrect |
| **Status** | Open |
| **Detected by** | cocotb `tests/test_dot_product_engine.py` (all 3 tests fail) |
| **Files to modify** | `rtl/fp32_acc.sv` and/or `rtl/dot_product_engine.sv` |

### Root Cause

`fp32_acc` is a 5-stage pipeline (A0 → A1 → B1 → B2_reg → C). The feedback mux is:

```systemverilog
acc_fb = acc_en_d4 ? partial_sum_r : acc_reg;
```

`acc_en_d4` only asserts when `acc_en` has been **continuously high for at least 5 cycles**.

`dot_product_engine` asserts `acc_en = 1` for exactly **4** consecutive cycles (one per MAC
element for `VEC_LEN = 4`, driven via `feature_valid_d2`). Consequently `acc_en_d4` **never
fires** during the accumulation burst. Every addend enters Stage A0 reading `acc_fb = acc_reg
= 0` (stale). Stage C fires 4 separate times in the drain phase, each writing `0 + product[i]`
to `acc_reg`, with each write overwriting the previous. The final value is `product[3]` — only
the last element's partial product.

**Confirmed empirically:**  
Inputs `[1.0, 2.0, 3.0, 4.0]`, weights `[0.5, −0.5, 0.25, −0.25]`.  
Expected dot product: `−0.75`. DUT returns: `−1.0` (= `4 × −0.25`).

### Failing Test Output

```
AssertionError: Dot product mismatch: got -1.0, expected -0.75
```

### Required Fix Options (RTL engineer to choose one)

| Option | Description | Notes |
|--------|-------------|-------|
| A | **Fix `fp32_acc` bypass** — add a proper forwarding path that propagates the running partial sum through all pipeline stages so every addend sees the correct accumulated value regardless of consecutive `acc_en` cycles. | Most robust; eliminates the latency constraint on callers. Preferred long-term. |
| B | **Sequential accumulation in `dot_product_engine`** — assert `acc_en` for 1 cycle per element with a 5-cycle pipeline flush between each element (total ≈ 9 × `VEC_LEN` cycles). Update the drain counter accordingly. | Lowest risk; no changes to `fp32_acc` internals. Increases accumulation latency. |
| C | **Deepen the drain counter** — extend `acc_en` to `VEC_LEN + 4` continuous cycles. | Partially correct only; the first element still receives `acc_fb = 0`. Not recommended. |

---

## BUG-002 — `int_to_bf16(0)` returns `0x3f00` (= 0.5) instead of `0x0000`

| Field | Detail |
|-------|--------|
| **Severity** | High — zero-price normalization produces wrong feature value |
| **Status** | Open |
| **Detected by** | cocotb `tests/test_feat_edge.py::test_zero_price_input` |
| **Files to modify** | `rtl/feature_extractor.sv` (or `rtl/feature_extractor_v2.sv`, whichever is the active RTL source) |

### Root Cause

The `int_to_bf16` SystemVerilog function does not guard against the all-zero input before
computing the leading-one exponent and mantissa. When `price = 0` is presented and
`features_valid = 1`, the `features[3]` output (normalized price) is `0x3f00` (bfloat16
representation of 0.5) instead of `0x0000`.

The reference Python function `int_to_bf16_ref(0)` correctly returns `0x0000`. All
non-zero price test cases pass; the failure is isolated to the zero-input edge case.

### Failing Test Output

```
AssertionError: norm_price should be 0, got 0x3f00
```

### Required Fix

Add an early-return zero check as the **first** statement in the function:

```systemverilog
function automatic [15:0] int_to_bf16(input signed [31:0] val);
    if (val == '0) return 16'h0000;   // ← must be first check
    // ... existing exponent/mantissa logic unchanged ...
endfunction
```

This fix must be applied in whichever file is synthesised/simulated as the feature extractor
source. If both `feature_extractor.sv` and `feature_extractor_v2.sv` contain a copy of
`int_to_bf16`, both must be patched.

---

## BUG-003 — `order_book` delete fails for some orders under stress (CRC-17 collision hypothesis)

| Field | Detail |
|-------|--------|
| **Severity** | High — incorrect BBO after large-population delete bursts |
| **Status** | Open |
| **Detected by** | cocotb `tests/test_order_book.py::test_stress_10k_adds_5k_deletes_2k_replaces` |
| **Files to modify** | `rtl/order_book.sv` (collision resolution); possibly `tb/cocotb/models/golden_model.py` / `OrderBookModel` in `test_order_book.py` |

### Failing Test Output

```
AssertionError: BBO ask mismatch at delete op 3499: DUT=10666 model=0 sym=350
```

The Python `OrderBookModel` reports no ask orders remaining at symbol 350, but the DUT still
exposes a best ask at price 10666 — meaning the DUT failed to delete an order that the model
successfully removed.

### Root Cause (Hypothesis)

`order_book.sv` uses a CRC-17/CAN hash (polynomial `0x1002D`) to map each 64-bit `order_ref`
to a 17-bit bucket index into a 131,072-entry table. With 10,000 concurrent live orders, the
birthday-paradox probability of at least one CRC-17 collision across those keys is approximately
38 %. The Python `OrderBookModel` detects only exact `order_ref` duplicates; it does **not**
model the case where two distinct `order_ref` values map to the same CRC-17 bucket. If such a
collision occurs, the DUT's delete path may fail to locate the correct bucket entry, leaving a
stale ask price visible in the BBO output.

### Steps to Investigate

1. **Determine collision-resolution strategy** — inspect `order_book.sv` to confirm whether the
   hash table uses open addressing (linear/quadratic probe) or chaining. The delete path must
   walk the full probe/chain sequence until the matching `order_ref` is found.
2. **Trace the failing delete** — re-run the stress test with `SIM_ARGS="+define+TRACE"` (or
   add a cocotb `dut._log.info` statement in the delete driver) to capture which `order_ref`
   was targeted at delete op 3499, compute its CRC-17 hash, and check whether any other live
   order at that point shares the same bucket index.
3. **Align the model** — determine whether `OrderBookModel` should be updated to simulate
   CRC-17 bucket collisions so that its delete behavior matches the DUT. If the DUT's collision
   resolution is correct, the model is the source of divergence; if the DUT's collision
   resolution is broken, fix the RTL.

### Files Involved

| File | Role |
|------|------|
| `rtl/order_book.sv` | Hash table — collision resolution and delete walk logic |
| `tb/cocotb/models/golden_model.py` | May need CRC-17 collision simulation added |
| `tb/cocotb/tests/test_order_book.py` | Contains `OrderBookModel`; may need same update |

---

## Summary Table

| ID | Severity | Status | Files | Detected By |
|----|----------|--------|-------|-------------|
| BUG-001 | Critical | Open | `rtl/fp32_acc.sv`, `rtl/dot_product_engine.sv` | `test_dot_product_engine.py` |
| BUG-002 | High | Open | `rtl/feature_extractor.sv` / `feature_extractor_v2.sv` | `test_feat_edge.py::test_zero_price_input` |
| BUG-003 | High | Open | `rtl/order_book.sv`, `tb/cocotb/models/golden_model.py` | `test_order_book.py::test_stress_10k_adds_5k_deletes_2k_replaces` |
