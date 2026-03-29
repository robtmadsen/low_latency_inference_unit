# Bug Detection Report

> **Plan:** [.github/plan/BUG_INJECT.md](../.github/plan/BUG_INJECT.md)  
> **Updated:** after every cocotb run and every UVM run (20 updates total)  
> **Legend:** ✅ detected (≥1 test failed) · ❌ missed (all tests passed) · ⏳ pending

---

## Baseline

| TB | Result |
|----|--------|
| cocotb | ✅ 28/28 tests pass (9 modules) |
| UVM | ✅ 7/7 tests pass |

---

## Bug 1 — `itch_parser.sv`: Byte-swapped length prefix

**Mutation:** `{s_axis_tdata[63:56], s_axis_tdata[55:48]}` → `{s_axis_tdata[55:48], s_axis_tdata[63:56]}`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_single_add_order` | `fields_valid never asserted` — swapped `msg_len` causes FSM to never exit S_ACCUMULATE |
| UVM    | ✅ detected | `lliu_smoke_test` | 5/7 FAILED; `lliu_base_test` + `lliu_coverage_test` missed (no scoreboard check on inference count) |

---

## Bug 2 — `itch_parser.sv`: ACCUMULATE stride 7 instead of 8

**Mutation:** `byte_cnt <= byte_cnt + 7'd8` → `byte_cnt <= byte_cnt + 7'd7` *(S_ACCUMULATE block)*

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_single_add_order` | 3/4 test_parser FAIL, 7/13 test_parser_edge FAIL; single-beat messages pass (never enter S_ACCUMULATE), multi-beat messages mis-frame |
| UVM    | ✅ detected | `lliu_smoke_test` | 5/7 FAILED; same pattern as Bug 1 — `lliu_base_test` + `lliu_coverage_test` missed |

---

## Bug 3 — `itch_field_extract.sv`: Price MSB off-by-one byte

**Mutation:** `msg_data[(B-1-32)*8 +: 8]` → `msg_data[(B-1-31)*8 +: 8]` *(price MSB)*

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_single_add_order` | 17/115 FAIL; parser field tests + smoke/random/backpressure/error/replay fail; latency/regmap/integration tests pass (do not validate price numerics) |
| UVM    | ✅ detected | `lliu_smoke_test` | Scoreboard fires with `MISMATCH #1: expected=16848.5 actual=603979776.0`; detected after enabling DPI-C (`LLIU_ENABLE_DPI`) |

---

## Bug 4 — `itch_field_extract.sv`: Side decode checks 'S' not 'B'

**Mutation:** `== 8'h42` → `== 8'h53`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_single_add_order` | 4/115 FAIL; only `test_parser` (3) + `test_parser_edge` (1) fail — parser tests cross-check the raw side byte; `feature_extractor` and `lliu_top` tests pass (don’t assert on exact side-dependent output value) |
| UVM    | ✅ detected | `lliu_smoke_test` | 6/7 FAIL; scoreboard mismatches on inverted side encoding; only `lliu_base_test` passes (no scoreboard check) |

---

## Bug 5 — `feature_extractor.sv`: Price delta uses + instead of −

**Mutation:** `$signed({1'b0, price}) - $signed({1'b0, last_price})` → `... + $signed({1'b0, last_price})`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_feature_extractor` | 10/115 FAIL; feature_extractor, feat_edge, smoke, constrained_random, backpressure, replay fail; parser/arithmetic/integration modules pass |
| UVM    | ✅ detected | `lliu_smoke_test` | 6/7 FAIL; scoreboard fires on wrong price delta; only `lliu_base_test` passes |

---

## Bug 6 — `feature_extractor.sv`: Side encoding sign inverted

**Mutation:** `side ? 32'sd1 : -32'sd1` → `side ? -32'sd1 : 32'sd1`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_feature_extractor` | 2/115 FAIL; only unit-level feature extractor tests check the absolute sign of the side feature; end-to-end tests pass |
| UVM    | ✅ detected | `lliu_smoke_test` | 6/7 FAIL; scoreboard fires on wrong side-feature sign; only `lliu_base_test` passes |

---

## Bug 7 — `bfloat16_mul.sv`: Exponent bias 126 instead of 127

**Mutation:** `- 10'd127` → `- 10'd126`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_bfloat16_mul` | 18/115 FAIL; bfloat16_mul, dot_product_engine, and most lliu_top tests fail; bias error shifts every product by 2× |
| UVM    | ✅ detected | `lliu_smoke_test` | 6/7 FAIL; scoreboard fires on wrong inference values; only `lliu_base_test` passes |

---

## Bug 8 — `fp32_acc.sv`: Accumulator clear disabled

**Mutation:** `if (rst || acc_clear)` → `if (rst)` *(always_ff reset condition)*

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_fp32_acc` | 10/115 FAIL; fp32_acc, dot_product_engine, smoke, constrained_random, backpressure, replay fail; accumulator carries state across inference cycles |
| UVM    | ✅ detected | `lliu_smoke_test` | 6/7 FAIL; scoreboard fires on accumulated inference values; only `lliu_base_test` passes |

---

## Bug 9 — `dot_product_engine.sv`: Early termination at element N−2

**Mutation:** `elem_cnt == VEC_LEN[...] - 1` → `elem_cnt == VEC_LEN[...] - 2`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_dot_product_engine` | 14/115 FAIL; dot_product unit tests catch it directly (3/3); smoke, constrained_random, backpressure, error_injection, replay also fail due to dropped last element |
| UVM    | ✅ detected | `lliu_smoke_test` | 6/7 FAIL; scoreboard fires on wrong inference result; only `lliu_base_test` passes |

---

## Bug 10 — `weight_mem.sv`: Read address stuck at 0

**Mutation:** `rd_data <= mem[rd_addr]` → `rd_data <= mem[0]`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ✅ detected | `test_smoke` | 6/115 FAIL; smoke, constrained_random, backpressure, error_injection, replay fail; `test_wgtmem_outbuf` passes (single-weight access pattern coincides with addr 0) |
| UVM    | ✅ detected | `lliu_smoke_test` | 6/7 FAIL; scoreboard fires on wrong weighted dot-product; only `lliu_base_test` passes |

---

## Final Scorecard

| Bug | Module | Description | cocotb | UVM |
|-----|--------|-------------|:------:|:---:|
| 1 | `itch_parser` | Byte-swapped length prefix | ✅ | ✅ |
| 2 | `itch_parser` | ACCUMULATE stride 7 instead of 8 | ✅ | ✅ |
| 3 | `itch_field_extract` | Price MSB off-by-one byte | ✅ | ✅ |
| 4 | `itch_field_extract` | Side decode checks 'S' not 'B' | ✅ | ✅ |
| 5 | `feature_extractor` | Price delta uses + instead of − | ✅ | ✅ |
| 6 | `feature_extractor` | Side encoding sign inverted | ✅ | ✅ |
| 7 | `bfloat16_mul` | Exponent bias 126 instead of 127 | ✅ | ✅ |
| 8 | `fp32_acc` | Accumulator clear disabled | ✅ | ✅ |
| 9 | `dot_product_engine` | Early termination at element N−2 | ✅ | ✅ |
| 10 | `weight_mem` | Read address stuck at 0 | ✅ | ✅ |
| | | **Total** | **10/10** | **10/10** |
