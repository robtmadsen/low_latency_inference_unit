# Phase 4 — Injected Bugs

DUT: `kc705_top` system (15 files: `kc705_top.sv`, `eth_axis_rx_wrap.sv`,
`moldupp64_strip.sv`, `itch_parser_v2.sv`, `symbol_filter.sv`, `order_book.sv`,
`risk_check.sv`, `strategy_arbiter.sv`, `ouch_engine.sv`,
`feature_extractor_v2.sv`, `lliu_top_v2.sv`,
`bfloat16_mul.sv`, `dot_product_engine.sv`, `output_buffer.sv`, `weight_mem.sv`)

Each bug is injected in isolation (one buggy copy of the full DUT per bug).
Golden-model reference: `tb/cocotb/models/golden_model.py`

---

## BUG-001 · `kc705_top.sv` — CDC byte-swap bypass

**Type:** CDC / Data corruption  
**File:** `rtl/kc705_top.sv`  
**Change:** In the `lliu_top_v2` instantiation connect `itch_300_tdata` directly
instead of the byte-swapped version.

```diff
-        .s_axis_tdata   (itch_300_tdata_swapped),
+        .s_axis_tdata   (itch_300_tdata),
```

**Effect:** `itch_parser_v2` receives little-endian bytes across the entire
stream. Every message-type byte, field boundary, and price/shares field is
byte-reversed. Most ITCH message types are unrecognised and silently drained; the
rare coincidental match produces entirely wrong field values. Failure rate is 100%
and systematic.

---

## BUG-002 · `kc705_top.sv` — FIFO almost-full threshold too high

**Type:** Backpressure / Threshold error  
**File:** `rtl/kc705_top.sv`  
**Change:** Raise the `axis_async_fifo` back-pressure assertion point from 64 to
127 — leaving only one free slot before the FIFO is full.

```diff
-    assign fifo_almost_full = (fifo_s_depth >= 8'd64);
+    assign fifo_almost_full = (fifo_s_depth >= 8'd127);
```

**Effect:** `eth_axis_rx_wrap` withholds the drop signal until the CDC FIFO is
virtually full. A moderate burst overflows the FIFO silently at the Forencich
`axis_async_fifo` level without incrementing `dropped_frames`. The testbench
`dropped_frames` counter stays 0 while frames are lost, breaking any drop-audit
check.

---

## BUG-003 · `bfloat16_mul.sv` — Exponent bias off by one

**Type:** Arithmetic constant error / Inference score corruption  
**File:** `rtl/bfloat16_mul.sv`  
**Change:** Change the bias subtraction from 127 to 128.

```diff
-    assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd127;
+    assign exp_sum = {2'b0, a_exp} + {2'b0, b_exp} - 10'd128;
```

**Effect:** Every bfloat16 multiplication produces a result whose exponent is one
too small, effectively halving every product. The dot-product engine accumulates
these halved values, so the inference score from every `lliu_core` instance is
systematically 2× too small. A golden-model comparison will observe every
`dp_result` value failing a near-equality check. Threshold-based downstream logic
(`strategy_arbiter` score gate, `risk_check` kill-switch) may fire or suppress
trades incorrectly depending on operand magnitudes.

---

## BUG-004 · `dot_product_engine.sv` — Drain phase exits one cycle too early

**Type:** Off-by-one / Pipeline timing error  
**File:** `rtl/dot_product_engine.sv`  
**Change:** Reduce `DRAIN_EXIT_VAL` by 1 so the drain FSM exits before the last
accumulator's `acc_en_d4` has fired.

```diff
-    localparam logic [4:0] DRAIN_EXIT_VAL = DRAIN_LAST_EN[4:0] + 5'd5;
+    localparam logic [4:0] DRAIN_EXIT_VAL = DRAIN_LAST_EN[4:0] + 5'd4;
```

**Effect:** The `S_DRAIN → S_DONE` transition occurs one cycle before `acc_en_d4`
fires for the last accumulator (`acc[NUM_ACCS_USED-1]`). That accumulator's
partial sum is never merged into `merge_out`. For `VEC_LEN=32` (`NUM=5`) the
contributions of elements at indices 4, 9, 14, 19, 24, 29 — six out of
thirty-two terms — are silently dropped. The final dot product is wrong for any
non-zero weight/feature at those positions. A golden-model comparison on the
`result` output will fail for virtually any non-trivial weight vector.

---

## BUG-005 · `eth_axis_rx_wrap.sv` — Drop-decision mux polarity swapped

**Type:** Logic inversion / Protocol error  
**File:** `rtl/eth_axis_rx_wrap.sv`  
**Change:** Swap the two branches of the `drop_decision` mux.

```diff
-    assign drop_decision = frame_active ? drop_current : fifo_almost_full;
+    assign drop_decision = frame_active ? fifo_almost_full : drop_current;
```

**Effect:** During a frame (`frame_active=1`) the drop decision is re-evaluated
every beat from live `fifo_almost_full` instead of using the committed
`drop_current` latch. The drop state can flip mid-frame: earlier beats may be
forwarded while later beats are discarded (or vice versa), delivering a partial
frame to the Forencich `eth_axis_rx` parser and corrupting all subsequent frame
synchronisation.

---

## BUG-006 · `feature_extractor_v2.sv` — Rolling window shift direction reversed

**Type:** Memory array ordering / Structural logic error  
**File:** `rtl/feature_extractor_v2.sv`  
**Change:** Reverse the 8-entry shift-register direction so the newest message
lands at index 7 (oldest slot) instead of index 0.

```diff
-                    for (int k = 7; k >= 1; k--) begin
-                        buy_vol_win[k]  <= buy_vol_win[k-1];
-                        sell_vol_win[k] <= sell_vol_win[k-1];
-                        px_vol_win[k]   <= px_vol_win[k-1];
-                        msg_lcnt_win[k] <= msg_lcnt_win[k-1];
-                    end
-                    buy_vol_win[0]  <= side_s05 ? shares_s05 : 24'h0;
-                    sell_vol_win[0] <= side_s05 ? 24'h0 : shares_s05;
-                    px_vol_win[0]   <= msg_pxvol;
-                    msg_lcnt_win[0] <= local_cnt;
+                    for (int k = 0; k <= 6; k++) begin
+                        buy_vol_win[k]  <= buy_vol_win[k+1];
+                        sell_vol_win[k] <= sell_vol_win[k+1];
+                        px_vol_win[k]   <= px_vol_win[k+1];
+                        msg_lcnt_win[k] <= msg_lcnt_win[k+1];
+                    end
+                    buy_vol_win[7]  <= side_s05 ? shares_s05 : 24'h0;
+                    sell_vol_win[7] <= side_s05 ? 24'h0 : shares_s05;
+                    px_vol_win[7]   <= msg_pxvol;
+                    msg_lcnt_win[7] <= local_cnt;
```

**Effect:** The running sums subtract `win[7]` each cycle. After the reversal,
`win[7]` holds the value just written in the *previous* cycle rather than the
oldest of the 8 entries. On message N the sum correctly adds the new contribution
but subtracts the N-1 contribution immediately. From message 2 onward the rolling
buy/sell volume sums always equal only the single most recent value instead of
the 8-message window. Features [28] (`rolling_buy_vol`), [29] (`rolling_sell_vol`),
[30] (`vwap_approx`), and [31] (`msg_arrival_period`) are all wrong after the
first message. A golden-model comparison on any of these four features fails from
the second ITCH message onward.

---

## BUG-007 · `moldupp64_strip.sv` — expected_seq_num advances by 1 instead of msg_count

**Type:** Off-by-one / Protocol error  
**File:** `rtl/moldupp64_strip.sv`  
**Change:** Replace `header_msg_count_b2` with the literal `64'd1` in the
sequence-number advancement.

```diff
-                    expected_seq_num <= header_seq_num_b2 + {48'b0, header_msg_count_b2};
+                    expected_seq_num <= header_seq_num_b2 + 64'd1;
```

**Effect:** MoldUDP64 packs multiple ITCH messages per datagram. After each
datagram the expected sequence number should advance by `msg_count`. With `+1`
the parser expects seq N+1 but the next datagram carries seq N+msg_count —
everything after the first datagram is flagged out-of-order and silently dropped.
In a continuous feed all messages after the very first datagram are lost.

---

## BUG-008 · `moldupp64_strip.sv` — S_DROP exits without waiting for tlast

**Type:** FSM error / Protocol violation  
**File:** `rtl/moldupp64_strip.sv`  
**Change:** Remove the `s_tlast` guard in S_DROP so the state machine returns to
S_HEADER_B0 after the very first accepted beat.

```diff
             S_DROP: begin
                 s_tready = 1'b1;
                 m_tvalid = 1'b0;
-                if (s_tvalid && s_tlast) begin
-                    state_next = S_HEADER_B0;
-                end
+                if (s_tvalid) begin
+                    state_next = S_HEADER_B0;
+                end
             end
```

**Effect:** On the first beat of a dropped datagram (out-of-order or malformed
header) the parser immediately returns to S_HEADER_B0, treating the remaining
payload beats as new datagram headers. Those beats produce phantom datagrams with
garbage sequence numbers and message counts, cascading into permanently corrupted
session state for all subsequent datagrams.

---

## BUG-009 · `itch_parser_v2.sv` — Price field shifted by one byte

**Type:** Off-by-one / Field extraction error  
**File:** `rtl/itch_parser_v2.sv`  
**Change:** Shift all four price byte indices up by 1 for Add Order / Trade message
types.

```diff
-                        price <= {msg_buf[32], msg_buf[33], msg_buf[34], msg_buf[35]};
+                        price <= {msg_buf[33], msg_buf[34], msg_buf[35], msg_buf[36]};
```

**Effect:** For 'A' (Add Order), 'F' (Add Order with MPID), 'C' (Cross Trade), and
'P' (Trade) messages the extracted price is shifted right by one byte in the
message body. The resulting value is the concatenation of the last byte of the
stock field and the first three bytes of the actual price — entirely wrong. The
order book updates BBO with corrupted prices; all downstream features and risk
checks use these values.

---

## BUG-010 · `itch_parser_v2.sv` — ACCUMULATE→EMIT transition uses strict greater-than

**Type:** Off-by-one / FSM timing  
**File:** `rtl/itch_parser_v2.sv`  
**Change:** Replace `>=` with `>` in the accumulation-complete check.

```diff
-                        if ({10'b0, byte_cnt} + 16'd8 >= msg_len) begin
+                        if ({10'b0, byte_cnt} + 16'd8 > msg_len) begin
```

**Effect:** For messages whose body length is an exact multiple of 8 bytes above 6
(i.e., `msg_len` = 14, 22, 30, 38 …) the parser accumulates one extra beat after
the message is complete. The first 8 bytes of the next message are loaded into the
current message buffer, corrupting field extraction and losing stream alignment.
All subsequent messages in that ITCH session are misaligned.

---

## BUG-011 · `symbol_filter.sv` — CAM entries can never be invalidated

**Type:** Missing condition / Configuration logic error  
**File:** `rtl/symbol_filter.sv`  
**Change:** Always write `1'b1` to `cam_valid[gi]` regardless of `cam_wr_en_bit`.

```diff
-                    cam_valid[gi] <= cam_wr_en_bit;
+                    cam_valid[gi] <= 1'b1;
```

**Effect:** An AXI4-Lite write intended to remove a symbol from the watchlist
(`cam_wr_en_bit = 0`) instead marks the entry valid. The CAM never shrinks;
symbols once added are permanent. A test that adds a ticker, removes it, then
sends a message for that ticker will incorrectly observe `watchlist_hit` and
forward the message to feature extraction. The only way to clear the CAM is a
full chip reset.

---

## BUG-012 · `order_book.sv` — BBO bid improvement condition inverted

**Type:** Logic inversion / BBO maintenance error  
**File:** `rtl/order_book.sv`  
**Change:** Invert the bid-improvement comparison in S_SCAN_BOOK2.

```diff
-            bbo_bid_better_r <= op_price > bbo_bid_price_snap_r;
+            bbo_bid_better_r <= op_price < bbo_bid_price_snap_r;
```

**Effect:** A new bid order improves the BBO only when its price is *lower* than
the current BBO — the opposite of correct behaviour. The BBO bid therefore tracks
the worst bid in the book. All downstream features derived from `bbo_bid_price`
(spread, mid-price, order-vs-bid, inference scores) use a systematically wrong
value. Price signals are inverted relative to market reality.

---

## BUG-013 · `output_buffer.sv` — result_ready never asserts

**Type:** Missing assignment / Handshake error  
**File:** `rtl/output_buffer.sv`  
**Change:** Assign `result_ready_reg` to `1'b0` instead of `1'b1` when a valid
result arrives.

```diff
-            result_ready_reg <= 1'b1;
+            result_ready_reg <= 1'b0;
```

**Effect:** `result_ready` is permanently 0 regardless of how many valid results
arrive at `result_in`. Any AXI4-Lite polling loop that waits for `result_ready`
before reading `result_out` will spin forever — the readout path hangs
indefinitely. The `result_out` register is still updated on each `result_valid`
strobe, so a test that blindly reads `result_out` without checking the ready flag
would pass, masking the bug under naive test patterns. Any test that implements
the correct handshake will time out.

---

## BUG-014 · `risk_check.sv` — Fat-finger ceiling uses ≥ instead of >

**Type:** Off-by-one / Risk threshold error  
**File:** `rtl/risk_check.sv`  
**Change:** Change the fat-finger comparison from strict greater-than to
greater-than-or-equal.

```diff
-        block_fat_c0 = score_valid && ({8'h0, proposed_shares} > max_qty);
+        block_fat_c0 = score_valid && ({8'h0, proposed_shares} >= max_qty);
```

**Effect:** Orders for exactly `max_qty` shares are incorrectly classified as
fat-finger violations and blocked. The spec says "shares > max_qty must be
blocked"; the bug blocks "shares ≥ max_qty". A boundary test that sends an order
at the configured maximum quantity will observe rejection when it should pass.
Tests at `max_qty − 1` are unaffected, masking the bug unless an at-boundary test
exists.

---

## BUG-015 · `weight_mem.sv` — Read address off by one

**Type:** Memory array index error / Wrong-address read  
**File:** `rtl/weight_mem.sv`  
**Change:** Increment the read address by 1 before indexing `mem`.

```diff
-        rd_data <= mem[rd_addr];
+        rd_data <= mem[rd_addr + 1];
```

**Effect:** Element $i$ of the dot-product engine receives `weight[i+1 mod DEPTH]`
instead of `weight[i]`. The address arithmetic wraps silently (no X or out-of-bounds
error in simulation) so every inference result is wrong for any non-uniform weight
vector — `w[0]` is used for element `DEPTH-1`, and `w[k+1]` is used for every
other element. A golden-model comparison on `dp_result` fails for all weight
vectors except those where all adjacent weights are equal (i.e., constant weight
vectors). Any standard verification sequence that loads non-trivial weights will
detect the bug immediately.

---

## BUG-016 · `strategy_arbiter.sv` — Score threshold gates at strict > instead of ≥

**Type:** Off-by-one / Gating logic  
**File:** `rtl/strategy_arbiter.sv`  
**Change:** Replace `>=` with `>` in the score-threshold gate.

```diff
-            gated_valid[i] = core_valids[i] && (core_scores[i] >= score_thresh);
+            gated_valid[i] = core_valids[i] && (core_scores[i] > score_thresh);
```

**Effect:** A core whose score exactly equals `score_thresh` is masked out and
never enters the tournament. With the default `score_thresh = 0.0` (float32
zero), a core that produces a zero dot-product result (cold start, all-zero
weights) will never fire even though 0.0 ≥ 0.0 should pass. Tests that configure
`score_thresh` to a specific value and send inputs producing exactly that score
will observe `best_valid = 0`, suppressing the trade signal entirely.

---

## BUG-017 · `ouch_engine.sv` — Shares and price swapped in beat assembly

**Type:** Wrong field assignment / Protocol error  
**File:** `rtl/ouch_engine.sv`  
**Change:** Swap `latch_shares` and `latch_price` between beat-2 and beat-3.

```diff
-                    beat_buf[2] <= {{8'h0, latch_shares}, tmpl_rd_b2};
-                    beat_buf[3] <= {tmpl_rd_b3, latch_price};
+                    beat_buf[2] <= {{8'h0, latch_price[23:0]}, tmpl_rd_b2};
+                    beat_buf[3] <= {tmpl_rd_b3, {8'h0, latch_shares}};
```

**Effect:** Every generated OUCH Enter Order packet carries the shares quantity
in the price field and the price in the shares field. NASDAQ's order gateway
rejects all orders with a protocol violation. A testbench that decodes the raw
AXI4-S output bytes will observe the fields in wrong positions.

---

## BUG-018 · `ouch_engine.sv` — Back-pressure watchdog trips after 1 stalled cycle

**Type:** Timing / Back-pressure threshold  
**File:** `rtl/ouch_engine.sv`  
**Change:** Change the `tx_overflow` saturation check from full-counter saturation
to a 1-cycle threshold.

```diff
-                if (&bp_cnt) begin          // saturate at 63
+                if (bp_cnt >= 6'h1) begin   // trip after 1 stalled cycle
```

**Effect:** Any single cycle of downstream back-pressure (`m_axis_tready = 0`)
immediately sets `tx_ovf_r`, which propagates to `risk_check.tx_overflow` and
triggers the auto-kill. The system halts trading after the very first OUCH beat
that encounters back-pressure. The self-clear fires after 255 free cycles, so
trading resumes sporadically. Any test that exercises OUCH output with even
momentary back-pressure will observe `risk_pass` suppressed for hundreds of cycles
after each stall.

---

## BUG-019 · `feature_extractor_v2.sv` — Order-flow counter polarity inverted

**Type:** Logic inversion / Feature error  
**File:** `rtl/feature_extractor_v2.sv`  
**Change:** Swap the increment/decrement branches of `order_flow_cnt`.

```diff
-                if (side_s05)
-                    order_flow_cnt <= order_flow_cnt + 16'sd1;
-                else
-                    order_flow_cnt <= order_flow_cnt - 16'sd1;
+                if (side_s05)
+                    order_flow_cnt <= order_flow_cnt - 16'sd1;
+                else
+                    order_flow_cnt <= order_flow_cnt + 16'sd1;
```

**Effect:** Feature [2] (order_flow) decrements on buy orders and increments on
sells — exactly opposite the spec. A buy-dominated market produces a negative
order-flow signal instead of a positive one. Inference cores receive a
consistently wrong sign for this feature, producing systematic misdirection in
scoring. A test that sends a pure buy stream and verifies `feature[2] > 0` will
fail.

---

## BUG-020 · `lliu_top_v2.sv` — pipeline_hold always zero

**Type:** Missing condition / Protocol hazard  
**File:** `rtl/lliu_top_v2.sv`  
**Change:** Force `pipeline_hold` permanently to 0.

```diff
-    assign pipeline_hold = core_features_valid | in_flight;
+    assign pipeline_hold = 1'b0;
```

**Effect:** `itch_parser_v2` is never stalled during an in-flight inference. A
new ITCH message arriving while the 8 `lliu_core` instances are still processing
the previous feature vector fires a second `features_valid` pulse, which reloads
all 8 cores mid-inference. The second inference starts correctly but the first is
overwritten before completing. Under continuous ITCH traffic no inference ever
finishes; `best_valid` never asserts and no OUCH packets are generated. The bug is
invisible on single-message tests but reliable under back-to-back traffic.
