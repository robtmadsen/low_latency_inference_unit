# Mutation Testing Plan: `low_latency_inference_unit`

> **Purpose:** Evaluate the fault-detection capability of the cocotb and UVM testbenches by injecting 10 known, subtle RTL bugs one at a time and recording which TB catches each one.

---

## Reproducibility Anchors

1. **Sync with HEAD before starting** — this work is intended to land as a PR, so the branch must be up to date:
   ```bash
   git fetch origin
   git rebase origin/main   # or merge, per project convention
   git status               # must be clean before any mutation
   ```
2. Each mutation is a **single, precise string substitution** documented in the table below — the same edit every time.
3. After all runs for a given bug, restore the file with:
   ```bash
   git checkout -- rtl/<file>.sv
   ```
4. **Detection criterion:** A TB detects the bug if **at least one test exits with a non-zero exit code** (test failure, scoreboard mismatch, checker assertion, or compile-time error).
5. Results are recorded live in [`reports/bug_detection.md`](../../reports/bug_detection.md) — updated after every cocotb run and after every UVM run (20 updates total). The scorecard at the bottom of this file is the final summary.

---

## The 10 Mutations

| # | File | Change | Mechanism |
|---|------|--------|-----------|
| 1 | `itch_parser.sv` | Byte-swap the length prefix: `{s_axis_tdata[63:56], s_axis_tdata[55:48]}` → `{s_axis_tdata[55:48], s_axis_tdata[63:56]}` | `msg_len` gets a byte-swapped value; parser over- or under-reads every message body |
| 2 | `itch_parser.sv` | Decrement in ACCUMULATE by 7 instead of 8: first `byte_cnt + 7'd8` → `byte_cnt + 7'd7` in the ACCUMULATE block | All message bytes past the first beat are misaligned by 1; message type still lands but every downstream field shifts |
| 3 | `itch_field_extract.sv` | Off-by-one in price MSB slice: `(B-1-32)` → `(B-1-31)` for the first (MSB) price byte | Price reads from byte 31 (overlapping the stock ticker field) instead of byte 32; price is subtly wrong |
| 4 | `itch_field_extract.sv` | Invert side decode: `== 8'h42` (`'B'`) → `== 8'h53` (`'S'`) | Buy orders are reported as sells and vice versa for every message |
| 5 | `feature_extractor.sv` | Flip sign of price delta: `$signed({1'b0, price}) - $signed({1'b0, last_price})` → `$signed({1'b0, price}) + $signed({1'b0, last_price})` | Feature[0] becomes price sum instead of delta — wrong arithmetic, still within legal bfloat16 range |
| 6 | `feature_extractor.sv` | Invert side encoding: `side ? 32'sd1 : -32'sd1` → `side ? -32'sd1 : 32'sd1` | Buy and sell produce swapped feature values; result has wrong sign but correct magnitude |
| 7 | `bfloat16_mul.sv` | Off-by-one in exponent bias: `- 10'd127` → `- 10'd126` | Every product is 2× too large; compiles cleanly, numerics silently wrong |
| 8 | `fp32_acc.sv` | Remove accumulator clear: `rst \|\| acc_clear` → `rst` in the `always_ff` reset condition | Accumulator never clears between inferences; results from previous messages bleed into the next |
| 9 | `dot_product_engine.sv` | Early termination off-by-one: `elem_cnt == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1` → `elem_cnt == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 2` | Engine stops after 3 of 4 elements; the last MAC is always skipped |
| 10 | `weight_mem.sv` | Stick read address to 0: `rd_data <= mem[rd_addr]` → `rd_data <= mem[0]` | All four dot-product inputs use weight[0]; weights[1–3] are never read |

---

## Exact String Substitutions (for precision)

### Bug 1 — `itch_parser.sv`
```diff
-   msg_len <= {s_axis_tdata[63:56], s_axis_tdata[55:48]};
+   msg_len <= {s_axis_tdata[55:48], s_axis_tdata[63:56]};
```

### Bug 2 — `itch_parser.sv`
```diff
-   byte_cnt <= byte_cnt + 7'd8;
+   byte_cnt <= byte_cnt + 7'd7;
```
*(In the `S_ACCUMULATE` block only — the first occurrence of `+ 7'd8`.)*

### Bug 3 — `itch_field_extract.sv`
```diff
-   msg_data[(B-1-32)*8 +: 8],
+   msg_data[(B-1-31)*8 +: 8],
```
*(First line of the `price` concatenation — the MSB byte.)*

### Bug 4 — `itch_field_extract.sv`
```diff
-   assign side = (msg_data[(B-1-19)*8 +: 8] == 8'h42);
+   assign side = (msg_data[(B-1-19)*8 +: 8] == 8'h53);
```

### Bug 5 — `feature_extractor.sv`
```diff
-   price_delta = 32'($signed({1'b0, price}) - $signed({1'b0, last_price}));
+   price_delta = 32'($signed({1'b0, price}) + $signed({1'b0, last_price}));
```

### Bug 6 — `feature_extractor.sv`
```diff
-   side_enc_int = side ? 32'sd1 : -32'sd1;
+   side_enc_int = side ? -32'sd1 : 32'sd1;
```

### Bug 7 — `bfloat16_mul.sv`
```diff
-   assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd127;
+   assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd126;
```

### Bug 8 — `fp32_acc.sv`
```diff
-   if (rst || acc_clear) begin
+   if (rst) begin
```
*(In the `always_ff` sequential block of `fp32_acc`.)*

### Bug 9 — `dot_product_engine.sv`
```diff
-   if (elem_cnt == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 1) begin
+   if (elem_cnt == VEC_LEN[$clog2(VEC_LEN+1)-1:0] - 2) begin
```

### Bug 10 — `weight_mem.sv`
```diff
-   rd_data <= mem[rd_addr];
+   rd_data <= mem[0];
```

---

## Test Commands

### cocotb (Verilator backend)
```bash
cd tb/cocotb

# System-level
make SIM=verilator TOPLEVEL=lliu_top      TEST_MODULE=test_smoke
make SIM=verilator TOPLEVEL=lliu_top      TEST_MODULE=test_constrained_random
make SIM=verilator TOPLEVEL=lliu_top      TEST_MODULE=test_error_injection
make SIM=verilator TOPLEVEL=lliu_top      TEST_MODULE=test_latency
make SIM=verilator TOPLEVEL=lliu_top      TEST_MODULE=test_replay

# Block-level
make SIM=verilator TOPLEVEL=itch_parser        TEST_MODULE=test_parser
make SIM=verilator TOPLEVEL=bfloat16_mul       TEST_MODULE=test_bfloat16_mul
make SIM=verilator TOPLEVEL=dot_product_engine TEST_MODULE=test_dot_product_engine
make SIM=verilator TOPLEVEL=feature_extractor  TEST_MODULE=test_feature_extractor
```

### UVM (Verilator backend)
```bash
cd tb/uvm

make SIM=verilator UVM_HOME=$UVM_HOME TEST=lliu_smoke_test  run
make SIM=verilator UVM_HOME=$UVM_HOME TEST=lliu_replay_test run
make SIM=verilator UVM_HOME=$UVM_HOME TEST=lliu_random_test run
make SIM=verilator UVM_HOME=$UVM_HOME TEST=lliu_stress_test run
make SIM=verilator UVM_HOME=$UVM_HOME TEST=lliu_error_test  run
```

---

## Execution Order

1. **Sync & baseline** — rebase onto `origin/main`, confirm `git status` is clean, then run both full suites on clean RTL and confirm 100% green.
2. **For each bug 1–10:**
   a. Apply the mutation (single string substitution per the table above)
   b. Run the full cocotb suite; update `reports/bug_detection.md` with the result
   c. Run the full UVM suite; update `reports/bug_detection.md` with the result
   d. `git checkout -- rtl/<file>.sv` to restore clean RTL
3. **Final restore check** — `git diff rtl/` must be empty; `git status` must be clean
4. **Summarize** — fill in the scorecard totals below and commit `reports/bug_detection.md`

---

## Scorecard

| Bug | Module | Description | cocotb detected | UVM detected |
|-----|--------|-------------|:---------------:|:------------:|
| 1 | `itch_parser` | Byte-swapped length prefix | | |
| 2 | `itch_parser` | ACCUMULATE stride 7 instead of 8 | | |
| 3 | `itch_field_extract` | Price MSB off-by-one byte | | |
| 4 | `itch_field_extract` | Side decode checks 'S' not 'B' | | |
| 5 | `feature_extractor` | Price delta uses + instead of − | | |
| 6 | `feature_extractor` | Side encoding sign inverted | | |
| 7 | `bfloat16_mul` | Exponent bias 126 instead of 127 | | |
| 8 | `fp32_acc` | Accumulator clear disabled | | |
| 9 | `dot_product_engine` | Early termination at element N-2 | | |
| 10 | `weight_mem` | Read address stuck at 0 | | |
| | | **Total** | **/10** | **/10** |
