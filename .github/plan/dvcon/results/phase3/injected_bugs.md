# Phase 3 — Injected Bugs

DUT: `lliu_core` subsystem (6 files: `lliu_core.sv`, `dot_product_engine.sv`,
`bfloat16_mul.sv`, `fp32_acc.sv`, `weight_mem.sv`, `output_buffer.sv`)

Each bug is injected in isolation (one buggy copy of the subsystem per bug).
Golden-model reference: Python soft-model of bfloat16 MAC with fp32 accumulation.

---

## BUG-001 · `lliu_core.sv` — FSM feed count off-by-one

**Type:** Off-by-one error  
**File:** `rtl/lliu_core.sv`  
**Change:** In `SEQ_FEED`, change terminal comparison from `VEC_LEN - 1` to `VEC_LEN - 2`

```diff
-  if (seq_idx == ($clog2(VEC_LEN+1))'(VEC_LEN - 1)) begin
+  if (seq_idx == ($clog2(VEC_LEN+1))'(VEC_LEN - 2)) begin
```

**Effect:** The sequencer transitions to `SEQ_WAIT` one element early. The last
feature–weight pair is never dispatched to the DPE; the dot product is short by
exactly one MAC term. The error is systematic and proportional to the magnitude
of the last element. Tests that use a uniform all-ones vector may pass if the
tolerance is loose.

---

## BUG-002 · `lliu_core.sv` — Missing back-pressure guard in SEQ_WAIT

**Type:** Missing condition / protocol hazard  
**File:** `rtl/lliu_core.sv`  
**Change:** In `SEQ_WAIT`, remove the `if (dp_result_valid)` guard and transition
to `SEQ_IDLE` unconditionally on every clock cycle.

```diff
-  SEQ_WAIT: begin
-      if (dp_result_valid)
-          seq_state <= SEQ_IDLE;
-  end
+  SEQ_WAIT: begin
+      seq_state <= SEQ_IDLE;
+  end
```

**Effect:** `lliu_core` returns to `SEQ_IDLE` one cycle after the last element is
fed, well before the DPE drain completes (~58 cycles). A second `features_valid`
pulse causes a new `dp_start` (and thus `acc_clear`) to fire while the
accumulator pipeline is still live, corrupting the in-flight result. Invisible on
a single-transaction test; reliably triggers on back-to-back inference traffic.

---

## BUG-003 · `dot_product_engine.sv` — DRAIN exit one cycle early

**Type:** Off-by-one, pipeline timing  
**File:** `rtl/dot_product_engine.sv`  
**Change:** Reduce `DRAIN_EXIT_VAL` by one.

```diff
-  localparam logic [4:0] DRAIN_EXIT_VAL = DRAIN_LAST_EN[4:0] + 5'd5;
+  localparam logic [4:0] DRAIN_EXIT_VAL = DRAIN_LAST_EN[4:0] + 5'd4;
```

**Effect:** `S_DRAIN → S_DONE` fires before the final `acc_en_d4` writeback
commits to `acc_reg` inside `u_merge`. `result` reads a `merge_out` that is
missing the contribution of the last accumulator lane. The error is
non-deterministic in magnitude (depends on which lane is last) but always
produces a result that is smaller than the correct value.

---

## BUG-004 · `dot_product_engine.sv` — Merge accumulator not cleared between inferences

**Type:** Missing reset / state retention  
**File:** `rtl/dot_product_engine.sv`  
**Change:** Remove the `merge_clear <= 1'b1` assignment from the `S_IDLE`/`start` branch.

```diff
   if (start) begin
       mac_elem    <= '0;
       mac_drain   <= 3'd0;
       acc_clear   <= 1'b1;
-      merge_clear <= 1'b1;
       state       <= S_STREAM;
   end
```

**Effect:** `u_merge` (`fp32_acc` instance) retains its accumulated sum across
inferences. All inferences after the first are the sum of all previous results
plus the current one — a cumulative runaway. The first inference in a simulation
is always correct, masking the bug in tests that run only one transaction.

---

## BUG-005 · `bfloat16_mul.sv` — Exponent bias off by one

**Type:** Arithmetic constant error  
**File:** `rtl/bfloat16_mul.sv`  
**Change:** Change the bias subtraction constant from 127 to 126.

```diff
-  assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd127;
+  assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd126;
```

**Effect:** Every product is exactly 2× too large. The output is a well-formed
IEEE float32 with a valid sign, a valid (shifted) exponent, and a valid mantissa
— no NaN or Inf. The error is invisible to structural checks and only caught by
exact numerical comparison against a golden model.

---

## BUG-006 · `bfloat16_mul.sv` — Sign computed as OR instead of XOR

**Type:** Wrong operator  
**File:** `rtl/bfloat16_mul.sv`  
**Change:** Replace `^` with `|` in the result-sign assignment.

```diff
-  assign r_sign = a_sign ^ b_sign;
+  assign r_sign = a_sign | b_sign;
```

**Effect:** Positive × negative and negative × positive are correct (`0|1=1`,
`1|0=1`). Positive × positive is correct (`0|0=0`). Negative × negative
incorrectly yields a negative product (`1|1=1` instead of `0`). The bug is
invisible until both operands of a multiply are simultaneously negative — a
corner case that requires specifically signed test vectors.

---

## BUG-007 · `fp32_acc.sv` — Forwarding mux condition inverted

**Type:** Logic inversion / RAW hazard  
**File:** `rtl/fp32_acc.sv`  
**Change:** Swap the two branches of the forwarding mux.

```diff
-  assign acc_fb = acc_en_d5 ? partial_sum_r : acc_reg;
+  assign acc_fb = acc_en_d5 ? acc_reg : partial_sum_r;
```

**Effect:** When `acc_en_d5=1` (a writeback is in flight to `acc_reg`), the
mux selects the stale committed `acc_reg` instead of the not-yet-committed
`partial_sum_r`. In the round-robin 5-accumulator scheme, consecutive elements
assigned to the same accumulator arrive exactly 5 cycles apart, so `acc_en_d5`
is high precisely at each re-entry — creating a systematic RAW hazard that
discards every partial sum after the first for each accumulator lane.

---

## BUG-008 · `fp32_acc.sv` — Stage A0 pipeline registers not cleared on acc_clear

**Type:** Missing reset condition  
**File:** `rtl/fp32_acc.sv`  
**Change:** In the Stage A0 `always_ff` block, remove `acc_clear` from the reset guard.

```diff
-  if (rst || acc_clear) begin
+  if (rst) begin
```

**Effect:** When `dp_start` fires and `acc_clear` pulses, the Stage A0
pipeline registers (`big_man_r0`, `small_man_r0`, `exp_diff_r0`, etc.) retain
stale values from the previous inference. These propagate through all five
pipeline stages and overwrite `acc_reg` five cycles after the clear, corrupting
the first accumulation of every inference following the first.

---

## BUG-009 · `weight_mem.sv` — Synchronous read made combinational

**Type:** Structural / timing model mismatch  
**File:** `rtl/weight_mem.sv`  
**Change:** Replace the registered read `always_ff` with a combinational `assign`.

```diff
-  always_ff @(posedge clk) begin
-      if (rst) begin
-          rd_data <= '0;
-      end else begin
-          rd_data <= mem[rd_addr];
-      end
-  end
+  assign rd_data = mem[rd_addr];
```

**Effect:** `lliu_core` drives `wgt_rd_addr_r = seq_idx_narrow` combinationally
one cycle before the corresponding feature element is presented to the DPE,
relying on the 1-cycle synchronous read latency to deliver aligned
feature–weight pairs. A combinational read delivers `weight[N]` one cycle early,
so element N is multiplied by `weight[N−1]`. The dot product computes
$\sum_i \text{feat}[i] \cdot \text{weight}[i-1]$ — a rotated weight vector.
The result is a plausible float32 that will only fail golden-model comparison.

---

## BUG-010 · `output_buffer.sv` — Write-once register; stale result after first inference

**Type:** Functional / state retention  
**File:** `rtl/output_buffer.sv`  
**Change:** Add a `!result_ready_reg` guard to the latch condition.

```diff
-  end else if (result_valid) begin
+  end else if (result_valid && !result_ready_reg) begin
```

**Effect:** After the first inference, `result_ready_reg` latches to `1'b1` and
never clears. The guard prevents any subsequent `result_valid` strobe from
updating `result_out`. All inferences after the first return the first
inference's stale result while `result_ready` stays permanently asserted —
masking the error entirely for tests that only check the ready flag rather than
the value.

---

## Summary Table

| ID      | File                    | Type                          | Trigger condition                          |
|---------|-------------------------|-------------------------------|--------------------------------------------|
| BUG-001 | `lliu_core.sv`          | Off-by-one, FSM               | Any inference with VEC_LEN > 1             |
| BUG-002 | `lliu_core.sv`          | Missing condition / hazard    | Back-to-back inferences                    |
| BUG-003 | `dot_product_engine.sv` | Off-by-one, pipeline timing   | Any inference                              |
| BUG-004 | `dot_product_engine.sv` | Missing reset / state leak    | Second or later inference                  |
| BUG-005 | `bfloat16_mul.sv`       | Wrong constant                | Any inference (golden-model comparison)    |
| BUG-006 | `bfloat16_mul.sv`       | Wrong operator                | Both operands of any multiply are negative |
| BUG-007 | `fp32_acc.sv`           | Logic inversion / RAW hazard  | Any accumulator with ≥2 elements           |
| BUG-008 | `fp32_acc.sv`           | Missing reset condition       | Second or later inference                  |
| BUG-009 | `weight_mem.sv`         | Structural / timing mismatch  | Any inference (golden-model comparison)    |
| BUG-010 | `output_buffer.sv`      | Write-once / state retention  | Second or later inference                  |
