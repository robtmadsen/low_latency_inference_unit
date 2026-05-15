# RTL Bugs Found

## Bug 1: `itch_parser_v2` — Off-by-one in ACCUMULATE→EMIT transition

- **Test**: hft_base_test — all ITCH message types
- **Observed**: The parser uses `byte_cnt + 8 > msg_len` (strictly greater-than) to decide when to transition from `S_ACCUMULATE` to `S_EMIT`. For messages where `byte_cnt + 8 == msg_len` exactly (e.g., Execute Order: 6 body bytes from IDLE + 8 from one ACCUMULATE beat = 14, but msg_len=30, so after third beat: 6+8+8=22, 22+8=30, 30 > 30 is false), the parser requires an extra beat. The testbench works around this by padding short messages.
- **Expected**: `byte_cnt + 8 >= msg_len` (greater-than-or-equal)
- **Root cause**: Line 179 of `itch_parser_v2.sv` — `>` should be `>=`.
- **found_at**: 2026-05-15T00:10:00Z

## Bug 2: `itch_parser_v2` — Price field offset error (1-byte shift)

- **Test**: hft_base_test — Add Order messages
- **Observed**: Parser extracts price from `msg_buf[33:36]` for Add Order ('A'), but per ITCH 5.0 spec, the price field is at body bytes 32–35 (indices 32..35 in msg_buf). Using indices [33..36] shifts the price field by one byte, effectively multiplying the price by ~256. The testbench observes inflated price values in the order book.
- **Expected**: `price <= {msg_buf[32], msg_buf[33], msg_buf[34], msg_buf[35]}`
- **Root cause**: Lines 217–219 in `itch_parser_v2.sv` — indices are off by 1 (`[33:36]` instead of `[32:35]`).
- **found_at**: 2026-05-15T00:12:00Z

## Bug 3: `order_book` — BBO bid comparison is inverted

- **Test**: hft_base_test — Add Order Buy messages
- **Observed**: `bbo_bid_better_r` in `S_SCAN_BOOK3` is computed as `op_price < bbo_bid_price_snap_r` (line 476). For bids, a *higher* price is better (best bid = highest). This inverted comparison means bid BBO is never updated: the first bid order sets BBO to 0 (initial value), and all subsequent bids have `op_price > 0 = bbo_snap`, which fails the `<` check. Bid BBO remains 0 forever.
- **Expected**: `op_price > bbo_bid_price_snap_r` (or `bbo_bid_price_snap_r == 0 || op_price > bbo_bid_price_snap_r`)
- **Root cause**: Line 476 in `order_book.sv` — `<` should be `>` for bid side.
- **found_at**: 2026-05-15T00:14:00Z

## Bug 4: `ouch_engine` — Shares and price fields swapped in beat assembly

- **Test**: hft_base_test — OUCH output packet inspection
- **Observed**: In `S_LOAD`, beat_buf[2] places `latch_price` in the shares field position and beat_buf[3] places `latch_shares` in the price field position. Specifically:
  - `beat_buf[2] <= {{8'h0, latch_price[23:0]}, tmpl_rd_b2}` — price in shares slot
  - `beat_buf[3] <= {tmpl_rd_b3, {8'h0, latch_shares}}` — shares in price slot
- **Expected**: Beat 2 should contain shares, beat 3 should contain price.
- **Root cause**: Lines 237–240 in `ouch_engine.sv` — `latch_price` and `latch_shares` are swapped.
- **found_at**: 2026-05-15T00:16:00Z

## Bug 5: `itch_parser_v2` — `sym_id` hardcoded to 0

- **Test**: hft_base_test — Multiple symbol tests (AAPL, MSFT)
- **Observed**: `sym_id` is always assigned `'0` in the `S_EMIT` state (line 198). The parser never maps the stock ticker to a symbol ID. All orders are routed to symbol 0 regardless of the actual stock name.
- **Expected**: `sym_id` should be derived from the symbol filter CAM lookup or stock field hash.
- **Root cause**: Line 198 in `itch_parser_v2.sv` — `sym_id <= '0` is a placeholder that was never replaced with actual logic.
- **found_at**: 2026-05-15T00:18:00Z

## Bug 6: `feature_extractor_v2` — Order flow counter increments inverted

- **Test**: hft_base_test — Feature extraction
- **Observed**: In Stage 1, when `side_s05 == 1` (buy), `order_flow_cnt` is decremented (`- 16'sd1`), and when `side_s05 == 0` (sell), it is incremented (`+ 16'sd1`). This is backwards relative to the spec which states "order_flow = running buy − sell counter".
- **Expected**: Buy should increment, sell should decrement.
- **Root cause**: Lines 393–396 in `feature_extractor_v2.sv` — increment/decrement branches are swapped.
- **found_at**: 2026-05-15T00:20:00Z

## Bug 7: `ouch_engine` — Back-pressure watchdog threshold too low

- **Test**: hft_base_test — Back-pressure test (Phase 12k)
- **Observed**: `tx_overflow` asserts after only 2 consecutive stalled cycles (`bp_cnt >= 6'h1`), not the documented 64 cycles. The spec says "Asserts after 64 consecutive stalled cycles" but the comparison is `bp_cnt >= 6'h1` (line 151) instead of `bp_cnt >= 6'h3F`.
- **Expected**: `bp_cnt >= 6'h3F` for a 64-cycle threshold.
- **Root cause**: Line 151 in `ouch_engine.sv` — threshold constant is wrong (`6'h1` vs `6'h3F`).
- **found_at**: 2026-05-15T00:22:00Z

## Bug 8: `lliu_top_v2` — `pipeline_hold` never asserted

- **Test**: hft_base_test — Pipeline operation
- **Observed**: `pipeline_hold` is hardcoded to `1'b0` (line 556). The spec states it should be `core_features_valid | in_flight`, which would back-pressure the ITCH parser while an inference is in progress. Without this, multiple inferences could overlap, corrupting the held price/side/sym_id registers.
- **Expected**: `assign pipeline_hold = core_features_valid | in_flight;`
- **Root cause**: Line 556 in `lliu_top_v2.sv` — `1'b0` is a debugging override that was never reverted.
- **found_at**: 2026-05-15T00:24:00Z

## Bug 9: `kc705_top` — `fifo_almost_full` threshold too high

- **Test**: hft_base_test — Drop-on-full policy
- **Observed**: `fifo_almost_full` is asserted when `fifo_s_depth >= 8'd127` (line 480), meaning the FIFO must be completely full (127 out of 128 entries) before frames start being dropped. The spec says the threshold should be 64 (`fifo_s_depth >= 8'd64`) to provide headroom for one maximum ITCH-message burst.
- **Expected**: `fifo_s_depth >= 8'd64`
- **Root cause**: Line 480 in `kc705_top.sv` — threshold is `8'd127` instead of `8'd64`.
- **found_at**: 2026-05-15T00:26:00Z
