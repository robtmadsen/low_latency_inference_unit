# Bugs Found During Phase 4 Verification

## Bug 1: Order Book BBO Bid Comparison Inverted (CRITICAL — FIXED)

**File:** `rtl/order_book.sv` line 450  
**Severity:** Critical — blocked all OUCH output  
**found_at:** 2026-05-13T10:15:00Z

**Symptom:** `bbo_bid_price` was always 0 after buy orders. The risk_check module blocked all
orders with reason=1 (price-band violation) because `held_ref_r=0` produced `band_thresh=0`,
making any nonzero `price_diff` a violation.

**Root Cause:** The bid-side BBO comparison used `<` instead of `>` and was missing the
zero-check for the initial case (the ask side had it correctly).

**Before:**
```systemverilog
bbo_bid_better_r <= (op_price < bbo_bid_price_snap_r);
```

**After:**
```systemverilog
bbo_bid_better_r <= (bbo_bid_price_snap_r == 32'h0 ||
                     op_price > bbo_bid_price_snap_r);
```

**Impact:** Without this fix, no OUCH packets were ever generated. The entire inference pipeline
was functionally dead in simulation.

---

## Bug 2: Parser Price Field Off-by-One (HIGH — FIXED)

**File:** `rtl/itch_parser_v2.sv` line 211  
**Severity:** High — incorrect price extraction for A/F/C/P message types  
**found_at:** 2026-05-13T10:45:00Z

**Root Cause:** Price bytes were extracted from `msg_buf[33..36]` instead of the correct
ITCH 5.0 offset `msg_buf[32..35]`.

**Before:**
```systemverilog
price <= {msg_buf[33], msg_buf[34], msg_buf[35], msg_buf[36]};
```

**After:**
```systemverilog
price <= {msg_buf[32], msg_buf[33], msg_buf[34], msg_buf[35]};
```

**Impact:** All prices for Add Order, Add Order MPID, Order Executed with Price, and Trade
messages were shifted by one byte, producing garbage price values.

---

## Bug 3: Parser Accumulate Transition Off-by-One (MEDIUM — FIXED)

**File:** `rtl/itch_parser_v2.sv` line 173  
**Severity:** Medium — could cause premature or missed S_EMIT transitions  
**found_at:** 2026-05-13T11:00:00Z

**Root Cause:** The S_ACCUMULATE→S_EMIT transition used strict greater-than (`>`) instead
of greater-than-or-equal (`>=`) for the byte count comparison.

**Before:**
```systemverilog
if ({10'b0, byte_cnt} + 16'd8 > msg_len) begin
```

**After:**
```systemverilog
if ({10'b0, byte_cnt} + 16'd8 >= msg_len) begin
```

**Impact:** For message lengths that are exact multiples of 8 after the initial 6-byte
offset, the parser would consume one extra beat before emitting.

---

## Bug 4: eth_axis_rx_wrap Drop Decision Operand Swap (LOW — NOT FIXED)

**File:** `rtl/eth_axis_rx_wrap.sv` line 73  
**Severity:** Low — affects frame drop logic under backpressure  
**Status:** Documented only, not fixed (wrapper around external IP)  
**found_at:** 2026-05-13T11:30:00Z

**Observation:** The `drop_decision` signal appears to swap operands:
```systemverilog
assign drop_decision = frame_active ? fifo_almost_full : drop_current;
```

Expected behavior: during an active frame, the drop decision should be held (`drop_current`);
before a new frame starts, it should check FIFO occupancy (`fifo_almost_full`). The current
logic does the reverse.

---

## Bug 5: Replace Message Side Always Sell (DESIGN LIMITATION — DOCUMENTED)

**File:** `rtl/itch_parser_v2.sv` (side extraction), `rtl/order_book.sv` lines 599-608  
**Severity:** Design limitation — Replace orders always create sell-side entries  
**found_at:** 2026-05-13T12:00:00Z

**Observation:** The parser does not extract a side field for Replace ('U') messages — it
defaults to `side <= 1'b0` (sell). The ITCH 5.0 Replace message does not include a side field;
the side should be inherited from the original order's ref_mem entry. The order book uses
`op_side` (from parser, always 0) for the new entry rather than `op_ref_side` (from ref_mem).

**Impact:** Replacing a buy order creates a sell-side book entry. Lines 601-603 (Replace
buy-side BBO update) are dead code. The BBO bid update path after Replace is never exercised.

---

## Bug 6: Forencich Stack Drops 8-byte UDP Payloads (EXTERNAL — WORKAROUND)

**Component:** Forencich verilog-ethernet `udp_complete_64.v` / `ip_complete_64.v`  
**Severity:** Low — affects simulation only  
**Status:** Worked around with direct injection MUX (`sim_itch_inject`)  
**found_at:** 2026-05-13T11:15:00Z

**Observation:** Short UDP payloads (single 64-bit beat) are silently dropped by the
Forencich IP stack, likely due to pipeline minimum-length assumptions. MoldUDP64 datagrams
with a single short ITCH message produce exactly this scenario.

**Workaround:** Added `sim_itch_inject` bypass MUX in `kc705_top.sv` that injects ITCH
streams directly into the parser, bypassing Ethernet/IP/UDP/MoldUDP64 entirely.

---

## Bug 7: PCIe DMA snap_done/snap_valid Timing Race (HIGH — NOT FIXED)

**File:** `rtl/pcie_dma_engine.sv` lines 258-263, `rtl/snapshot_mux.sv` lines 151-153  
**Severity:** High — DMA engine hangs in DMA_CAPT_WAIT state permanently  
**Status:** Documented, not fixed  
**found_at:** 2026-05-13T16:45:00Z

**Root Cause:** In `snapshot_mux.sv`, when the last symbol's ask beat is sent (line 152),
`snap_done` is registered (`snap_done <= 1'b1`) and `state` transitions to `S_IDLE` on the
same posedge. Since `snap_valid` is combinational from `state`:

```systemverilog
assign snap_valid = (state == S_SEND_BID) | (state == S_SEND_ASK);
```

On the cycle after `snap_done` is committed, `state` is already `S_IDLE`, so `snap_valid = 0`.

In `pcie_dma_engine.sv`, the staging capture logic (line 259) checks:
```systemverilog
else if (capt_active_sys && snap_valid) begin
    ...
    if (snap_done) begin   // line 261 — NEVER TRUE
        capt_done_sys <= 1'b1;
    end
end
```

The `snap_done = 1` cycle always coincides with `snap_valid = 0`, so the outer condition
`capt_active_sys && snap_valid` is FALSE. The inner `snap_done` check is never reached.

**Impact:**
- `capt_done_sys` never fires → `capt_done_uc` (CDC) never fires
- DMA FSM hangs in `DMA_CAPT_WAIT` indefinitely after first DMA trigger
- Lines 262-263, 315, 566-567, 572-574, 581 are unreachable dead code
- The entire DMA-to-host transfer path (TLP generation) is never triggered naturally

**Suggested Fix:** Change the staging capture to check `snap_done` independently of `snap_valid`:
```systemverilog
else if (capt_active_sys) begin
    if (snap_valid) begin
        staging_mem[stg_wr_ptr] <= snap_data;
        stg_wr_ptr <= stg_wr_ptr + 10'h1;
    end
    if (snap_done) begin
        capt_active_sys <= 1'b0;
        capt_done_sys   <= 1'b1;
    end
end
```

---

## Bug 8: PCIe DMA CDC Rising-Edge Only Detection (LOW — DOCUMENTED)

**File:** `rtl/pcie_dma_engine.sv` lines 287-297  
**Severity:** Low — every other DMA trigger is lost  
**Status:** Documented  
**found_at:** 2026-05-13T17:00:00Z

**Observation:** The DMA FSM toggles `snap_req_level_uc` on each trigger (0→1→0→1...),
but the sys_clk CDC uses rising-edge detection:

```systemverilog
snap_req_sys_pulse <= snap_req_sync_sc[1] & ~snap_req_prev_sc;
```

This only fires on 0→1 transitions. The 1→0 transitions produce no pulse. Thus, only
odd-numbered DMA triggers (1st, 3rd, 5th, ...) actually initiate a snapshot capture.

**Suggested Fix:** Use XOR-based edge detection (detects both edges):
```systemverilog
snap_req_sys_pulse <= snap_req_sync_sc[1] ^ snap_req_prev_sc;
```
