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
| cocotb | ⏳ | | |
| UVM    | ⏳ | | |

---

## Bug 4 — `itch_field_extract.sv`: Side decode checks 'S' not 'B'

**Mutation:** `== 8'h42` → `== 8'h53`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ⏳ | | |
| UVM    | ⏳ | | |

---

## Bug 5 — `feature_extractor.sv`: Price delta uses + instead of −

**Mutation:** `$signed({1'b0, price}) - $signed({1'b0, last_price})` → `... + $signed({1'b0, last_price})`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ⏳ | | |
| UVM    | ⏳ | | |

---

## Bug 6 — `feature_extractor.sv`: Side encoding sign inverted

**Mutation:** `side ? 32'sd1 : -32'sd1` → `side ? -32'sd1 : 32'sd1`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ⏳ | | |
| UVM    | ⏳ | | |

---

## Bug 7 — `bfloat16_mul.sv`: Exponent bias 126 instead of 127

**Mutation:** `- 10'd127` → `- 10'd126`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ⏳ | | |
| UVM    | ⏳ | | |

---

## Bug 8 — `fp32_acc.sv`: Accumulator clear disabled

**Mutation:** `if (rst || acc_clear)` → `if (rst)` *(always_ff reset condition)*

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ⏳ | | |
| UVM    | ⏳ | | |

---

## Bug 9 — `dot_product_engine.sv`: Early termination at element N−2

**Mutation:** `elem_cnt == VEC_LEN[...] - 1` → `elem_cnt == VEC_LEN[...] - 2`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ⏳ | | |
| UVM    | ⏳ | | |

---

## Bug 10 — `weight_mem.sv`: Read address stuck at 0

**Mutation:** `rd_data <= mem[rd_addr]` → `rd_data <= mem[0]`

| TB | Result | First failing test | Notes |
|----|--------|--------------------|-------|
| cocotb | ⏳ | | |
| UVM    | ⏳ | | |

---

## Final Scorecard

| Bug | Module | Description | cocotb | UVM |
|-----|--------|-------------|:------:|:---:|
| 1 | `itch_parser` | Byte-swapped length prefix | ⏳ | ⏳ |
| 2 | `itch_parser` | ACCUMULATE stride 7 instead of 8 | ⏳ | ⏳ |
| 3 | `itch_field_extract` | Price MSB off-by-one byte | ⏳ | ⏳ |
| 4 | `itch_field_extract` | Side decode checks 'S' not 'B' | ⏳ | ⏳ |
| 5 | `feature_extractor` | Price delta uses + instead of − | ⏳ | ⏳ |
| 6 | `feature_extractor` | Side encoding sign inverted | ⏳ | ⏳ |
| 7 | `bfloat16_mul` | Exponent bias 126 instead of 127 | ⏳ | ⏳ |
| 8 | `fp32_acc` | Accumulator clear disabled | ⏳ | ⏳ |
| 9 | `dot_product_engine` | Early termination at element N−2 | ⏳ | ⏳ |
| 10 | `weight_mem` | Read address stuck at 0 | ⏳ | ⏳ |
| | | **Total** | **⏳ /10** | **⏳ /10** |
