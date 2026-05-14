# Bugs Found in HFT SoC (kc705_top)

## Bug 1: itch_parser_v2 — sym_id always 0
**File:** `rtl/itch_parser_v2.sv`
**Severity:** Critical
**Description:** `parser_sym_id` is always driven to 0 regardless of the stock symbol in the ITCH message. All BBO queries, feature extraction, and downstream processing operate on symbol 0 only. Multi-symbol operation is broken.
**found_at:** 2026-05-14T02:00:00Z

## Bug 2: itch_parser_v2 — Price extraction off by 1 byte
**File:** `rtl/itch_parser_v2.sv`
**Severity:** High
**Description:** The parser reads price from `msg_buf[33:36]` instead of the correct `msg_buf[32:35]`. The resulting parser_price equals `(actual_price & 0x00FFFFFF) << 8`, introducing a 256x scaling error and losing the MSB of the price field.
**found_at:** 2026-05-14T02:00:00Z

## Bug 3: order_book — Bid BBO comparison inverted
**File:** `rtl/order_book.sv`
**Severity:** Critical
**Description:** The bid-side BBO update uses `<` instead of `>` when comparing new prices against the current best bid. This causes `bbo_bid_price` to always remain 0 (reset value), as every new bid price is greater than 0 but the comparison rejects it. Ask-side BBO works correctly.
**found_at:** 2026-05-14T02:00:00Z

## Bug 4: itch_parser_v2 — Accumulate transition uses `>` instead of `>=`
**File:** `rtl/itch_parser_v2.sv`, line 173
**Severity:** High
**Description:** The S_ACCUMULATE -> S_EMIT transition condition is `byte_cnt + 8 > msg_len` but should be `byte_cnt + 8 >= msg_len` (as stated in the comment on line 31). For messages whose body length + 2-byte prefix is exactly divisible by 8 (Execute: 30+2=32, Cancel: 23+2=25->rounded to next 8=32), the parser stays in S_ACCUMULATE when it should emit. The workaround is to pad ITCH messages with 8 extra trailing bytes to force an additional accumulate beat.
**found_at:** 2026-05-14T02:00:00Z

## Bug 5: moldupp64_strip — Sequence number advances by 1, not by msg_count
**File:** `rtl/moldupp64_strip.sv`, line 326
**Severity:** Medium
**Description:** `expected_seq_num` increments by +1 per datagram regardless of the message count field in the MoldUDP64 header. Multi-message datagrams will desynchronize the sequence counter, causing subsequent single-message datagrams to be silently dropped as out-of-order.
**found_at:** 2026-05-14T02:00:00Z

## Bug 6: pcie_dma_engine — snap_done timing bug
**File:** `rtl/pcie_dma_engine.sv`
**Severity:** High
**Description:** The staging buffer capture logic checks `if (snap_done)` only inside the `if (capt_active_sys && snap_valid)` block. However, `snap_done` (a registered pulse from snapshot_mux) fires exactly 1 cycle after `snap_valid` deasserts. When snap_done=1, snap_valid=0, so the condition `capt_active_sys && snap_valid` is false and snap_done is never observed. The DMA engine gets permanently stuck in DMA_CAPT_WAIT, never generating TLPs or completing a snapshot transfer.
**found_at:** 2026-05-14T02:00:00Z

## Bug 7: risk_check — ref_price_d 27-bit truncation causes incorrect band threshold
**File:** `rtl/risk_check.sv`, line 137
**Severity:** Medium
**Description:** `ref_price_d` is truncated to 27 bits (`ref_price[26:0]`), losing bit 27 for prices above ~$13,421 (scaled). For NASDAQ stocks priced above this threshold, the band threshold is computed from a truncated reference price, making the price band appear much narrower than configured. Orders that should pass the band check are incorrectly blocked. This interacts with Bug 3 (bid=0 halves ref_price) to further reduce the effective band.
**found_at:** 2026-05-14T10:00:00Z
