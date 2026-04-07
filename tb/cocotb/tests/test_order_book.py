"""test_order_book.py — Block-level functional tests for order_book.sv.

DUT: order_book
Clock: 10 ns (100 MHz — well within 300/312.5 MHz timing budget)
Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.3, §5 Phase 1, §7

Tests drive the parsed-ITCH input bus directly (bypass itch_parser_v2) and
verify BBO outputs via the registered bbo_query_sym interface.

All BBO checks use Phase-1 simplified logic:
  Add  : best-price wins (bid: highest; ask: lowest / first).
  Del/X: reset BBO to 0 if deleted order was at current BBO price.
  No full L2 rescan (deferred to Phase 2).
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from models.order_book_model import OrderBookModel


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def reset_dut(dut):
    """10 ns clock; hold reset for 5 cycles then release with 1 settling cycle."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.rst.value           = 1
    dut.fields_valid.value  = 0
    dut.msg_type.value      = 0
    dut.order_ref.value     = 0
    dut.new_order_ref.value = 0
    dut.price.value         = 0
    dut.shares.value        = 0
    dut.side.value          = 0
    dut.sym_id.value        = 0
    dut.bbo_query_sym.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_op(dut, msg_type_byte, order_ref, new_order_ref,
                   price, shares, side, sym_id, timeout=30):
    """Wait for book_ready, drive fields_valid for 1 cycle, then wait until
    the FSM returns to IDLE (book_ready=1), tracking the bbo_valid pulse.

    Waiting for the full S_IDLE return (rather than the transient bbo_valid
    pulse at S_UPDATE) ensures all non-blocking BBO register updates have
    propagated before read_bbo samples them — required for correct Verilator
    simulation with variable-index array NBA writes.

    Returns True when bbo_valid was observed during the operation,
    False for no-op msg_types or collision drops.
    """
    # Wait until the FSM is idle.
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.book_ready.value == 1:
            break

    dut.msg_type.value      = msg_type_byte
    dut.order_ref.value     = order_ref
    dut.new_order_ref.value = new_order_ref
    dut.price.value         = price
    dut.shares.value        = shares & 0xFFFFFF  # only [23:0] used by RTL
    dut.side.value          = side
    dut.sym_id.value        = sym_id
    dut.fields_valid.value  = 1
    await RisingEdge(dut.clk)
    dut.fields_valid.value  = 0

    # Poll until FSM returns to IDLE, capturing the bbo_valid pulse en-route.
    bbo_seen = False
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.bbo_valid.value == 1:
            bbo_seen = True
        if dut.book_ready.value == 1:
            return bbo_seen
    return False


async def read_bbo(dut, sym_id):
    """Drive bbo_query_sym, advance two clocks, return registered BBO tuple.

    Returns (bid_price, ask_price, bid_size, ask_size).

    Two rising edges are required in Verilator/cocotb:
      Cycle 1 (bbo_query_sym write → taken into account by always_ff):
        In cocotb, Python signal writes in a RisingEdge callback land in the
        *same* delta cycle as the edge that just fired.  The always_ff at that
        edge has already evaluated, so bbo_query_sym is invisible to it.
        The NEXT rising edge (cycle 1 here) is the first edge that sees the
        updated bbo_query_sym and latches bbo_bid_price_r[sym_id].
      Cycle 2 (bbo_bid_price output register propagates):
        The registered bbo_bid_price output reflects the newly-latched
        bbo_bid_price_r value only after cycle 2.
    """
    dut.bbo_query_sym.value = sym_id
    await RisingEdge(dut.clk)   # cycle 1: always_ff sees new bbo_query_sym
    await RisingEdge(dut.clk)   # cycle 2: bbo_bid_price output latched
    return (
        int(dut.bbo_bid_price.value),
        int(dut.bbo_ask_price.value),
        int(dut.bbo_bid_size.value),
        int(dut.bbo_ask_size.value),
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_add_order_basic(dut):
    """Add one bid and one ask to sym_id=0; verify BBO reflects both sides."""
    await reset_dut(dut)

    # --- Bid: price=1000, shares=500 ---
    got_valid = await drive_op(dut, 0x41, 1, 0, 1000, 500, 1, 0)
    assert got_valid, "bbo_valid should pulse after Add bid"

    bid_p, ask_p, bid_s, ask_s = await read_bbo(dut, 0)
    assert bid_p == 1000, f"BBO bid price expected 1000, got {bid_p}"
    assert bid_s == 500,  f"BBO bid size expected 500, got {bid_s}"
    assert ask_p == 0,    f"BBO ask price should still be 0, got {ask_p}"

    # --- Ask: price=1200, shares=300 ---
    got_valid = await drive_op(dut, 0x41, 2, 0, 1200, 300, 0, 0)
    assert got_valid, "bbo_valid should pulse after Add ask"

    bid_p, ask_p, bid_s, ask_s = await read_bbo(dut, 0)
    assert bid_p == 1000, f"BBO bid price should remain 1000, got {bid_p}"
    assert ask_p == 1200, f"BBO ask price expected 1200, got {ask_p}"
    assert ask_s == 300,  f"BBO ask size expected 300, got {ask_s}"


@cocotb.test()
async def test_delete_order(dut):
    """Add an order at BBO price, delete it, verify BBO resets to 0."""
    await reset_dut(dut)

    # Add a bid that becomes the BBO.
    await drive_op(dut, 0x41, 10, 0, 2000, 100, 1, 1)
    bid_p, _, _, _ = await read_bbo(dut, 1)
    assert bid_p == 2000, f"BBO bid should be 2000 after add, got {bid_p}"

    # Delete the same order.
    got_valid = await drive_op(dut, 0x44, 10, 0, 0, 0, 0, 1)
    assert got_valid, "bbo_valid should pulse after Delete"

    bid_p, ask_p, bid_s, ask_s = await read_bbo(dut, 1)
    assert bid_p == 0, f"BBO bid price should be 0 after delete, got {bid_p}"
    assert bid_s == 0, f"BBO bid size should be 0 after delete, got {bid_s}"


@cocotb.test()
async def test_replace_order(dut):
    """Add an order, replace with new_order_ref at a higher price; verify BBO updates."""
    await reset_dut(dut)

    # Add original bid: ref=20, price=500, shares=200, bid, sym=2
    await drive_op(dut, 0x41, 20, 0, 500, 200, 1, 2)
    bid_p, _, _, _ = await read_bbo(dut, 2)
    assert bid_p == 500, f"Initial BBO bid should be 500, got {bid_p}"

    # Replace: old_ref=20 → new_ref=21, new price=700, new shares=150, same side, same sym
    got_valid = await drive_op(dut, 0x55, 20, 21, 700, 150, 1, 2)
    assert got_valid, "bbo_valid should pulse after Replace"

    bid_p, _, bid_s, _ = await read_bbo(dut, 2)
    assert bid_p == 700, f"BBO bid price should be 700 after replace, got {bid_p}"
    assert bid_s == 150, f"BBO bid size should be 150 after replace, got {bid_s}"


@cocotb.test()
async def test_cancel_order(dut):
    """Partial cancel leaves BBO unchanged; full cancel resets BBO to 0."""
    await reset_dut(dut)

    # Add 1000-share bid at price 3000, sym=3
    await drive_op(dut, 0x41, 30, 0, 3000, 1000, 1, 3)
    bid_p, _, bid_s, _ = await read_bbo(dut, 3)
    assert bid_p == 3000, f"BBO bid should be 3000 after add, got {bid_p}"

    # Cancel 500 shares — shares > 0 after cancel; Phase-1 BBO stays at original.
    got_valid = await drive_op(dut, 0x58, 30, 0, 0, 500, 1, 3)
    assert got_valid, "bbo_valid should pulse after partial Cancel"

    bid_p, _, _, _ = await read_bbo(dut, 3)
    assert bid_p == 3000, \
        f"BBO bid price should remain 3000 after partial cancel (Phase-1 no-rescan), got {bid_p}"

    # Cancel the remaining 500 shares — shares hit 0, BBO should reset.
    got_valid = await drive_op(dut, 0x58, 30, 0, 0, 500, 1, 3)
    assert got_valid, "bbo_valid should pulse after final Cancel"

    bid_p, _, bid_s, _ = await read_bbo(dut, 3)
    assert bid_p == 0, f"BBO bid price should be 0 after full cancel, got {bid_p}"
    assert bid_s == 0, f"BBO bid size should be 0 after full cancel, got {bid_s}"


@cocotb.test()
async def test_execute_order(dut):
    """Partial execute leaves BBO; full execute resets BBO."""
    await reset_dut(dut)

    # Add 1000-share ask at price 2500, sym=4
    await drive_op(dut, 0x41, 40, 0, 2500, 1000, 0, 4)
    _, ask_p, _, ask_s = await read_bbo(dut, 4)
    assert ask_p == 2500, f"BBO ask should be 2500 after add, got {ask_p}"

    # Execute 600 shares — partial fill, BBO price unchanged.
    got_valid = await drive_op(dut, 0x45, 40, 0, 0, 600, 0, 4)
    assert got_valid, "bbo_valid should pulse after partial Execute"

    _, ask_p, _, _ = await read_bbo(dut, 4)
    assert ask_p == 2500, \
        f"BBO ask price should remain 2500 after partial execute, got {ask_p}"

    # Execute remaining 400 shares — full fill, BBO resets.
    got_valid = await drive_op(dut, 0x45, 40, 0, 0, 400, 0, 4)
    assert got_valid, "bbo_valid should pulse after full Execute"

    _, ask_p, _, ask_s = await read_bbo(dut, 4)
    assert ask_p == 0, f"BBO ask price should be 0 after full execute, got {ask_p}"
    assert ask_s == 0, f"BBO ask size should be 0 after full execute, got {ask_s}"


@cocotb.test()
async def test_bbo_best_bid_wins(dut):
    """Add 3 bid orders at prices 100, 120, 110 to same sym; BBO bid must be 120."""
    await reset_dut(dut)

    await drive_op(dut, 0x41, 50, 0, 100, 100, 1, 5)
    await drive_op(dut, 0x41, 51, 0, 120, 100, 1, 5)
    await drive_op(dut, 0x41, 52, 0, 110, 100, 1, 5)

    bid_p, _, _, _ = await read_bbo(dut, 5)
    assert bid_p == 120, \
        f"BBO best bid should be 120 (highest bid), got {bid_p}"


@cocotb.test()
async def test_bbo_best_ask_wins(dut):
    """Add 3 ask orders at prices 200, 150, 175 to same sym; BBO ask must be 150."""
    await reset_dut(dut)

    await drive_op(dut, 0x41, 60, 0, 200, 100, 0, 6)
    await drive_op(dut, 0x41, 61, 0, 150, 100, 0, 6)
    await drive_op(dut, 0x41, 62, 0, 175, 100, 0, 6)

    _, ask_p, _, _ = await read_bbo(dut, 6)
    assert ask_p == 150, \
        f"BBO best ask should be 150 (lowest ask), got {ask_p}"


@cocotb.test()
async def test_stress_10k_adds_5k_deletes_2k_replaces(dut):
    """Spec-required stress test (§5 Phase 1 key verification goals):
    10 K adds → 5 K deletes → 2 K replaces, with BBO cross-check every N ops.

    The Python OrderBookModel drives both stimulus generation and golden
    comparison. Only non-colliding ops are sent to the DUT so the ref_mem
    stays consistent between model and hardware.
    """
    await reset_dut(dut)

    random.seed(42)
    model = OrderBookModel()
    order_refs = []   # list of (ref, price, shares, side, sym)

    # ------------------------------------------------------------------
    # 10 K Adds
    # ------------------------------------------------------------------
    for i in range(10_000):
        ref    = random.randint(1, 2**60)
        sym    = random.randint(0, 499)
        price  = random.randint(100, 100_000)
        shares = random.randint(100, 10_000)
        side   = random.randint(0, 1)

        result = model.add(ref, price, shares, side, sym)
        if not result['collision']:
            order_refs.append((ref, price, shares, side, sym))
            await drive_op(dut, 0x41, ref, 0, price, shares, side, sym)

        # Cross-check BBO every 500 successful add ops.
        if i % 500 == 499:
            mb, ma, mbs, mas = model.get_bbo(sym)
            bid_p, ask_p, bid_s, ask_s = await read_bbo(dut, sym)
            assert bid_p == mb, \
                f"BBO bid mismatch at add op {i}: DUT={bid_p} model={mb} sym={sym}"
            assert ask_p == ma, \
                f"BBO ask mismatch at add op {i}: DUT={ask_p} model={ma} sym={sym}"

    # ------------------------------------------------------------------
    # 5 K Deletes
    # ------------------------------------------------------------------
    live = list(order_refs)
    random.shuffle(live)
    deleted_set = set(id_tuple for id_tuple in live[:5_000])

    for i, (ref, price, shares, side, sym) in enumerate(live[:5_000]):
        model.delete(ref)
        await drive_op(dut, 0x44, ref, 0, 0, 0, 0, sym)

        if i % 250 == 249:
            mb, ma, mbs, mas = model.get_bbo(sym)
            bid_p, ask_p, bid_s, ask_s = await read_bbo(dut, sym)
            assert bid_p == mb, \
                f"BBO bid mismatch at delete op {i}: DUT={bid_p} model={mb} sym={sym}"
            assert ask_p == ma, \
                f"BBO ask mismatch at delete op {i}: DUT={ask_p} model={ma} sym={sym}"

    # ------------------------------------------------------------------
    # 2 K Replaces (from remaining live orders)
    # ------------------------------------------------------------------
    remaining = [x for x in order_refs if x not in deleted_set]
    random.shuffle(remaining)

    for i, (old_ref, old_price, old_shares, old_side, sym) in enumerate(remaining[:2_000]):
        new_ref    = random.randint(1, 2**60)
        new_price  = random.randint(100, 100_000)
        new_shares = random.randint(100, 10_000)

        model.replace(old_ref, new_ref, new_price, new_shares, old_side, sym)
        await drive_op(dut, 0x55, old_ref, new_ref, new_price, new_shares, old_side, sym)

        if i % 200 == 199:
            mb, ma, mbs, mas = model.get_bbo(sym)
            bid_p, ask_p, bid_s, ask_s = await read_bbo(dut, sym)
            assert bid_p == mb, \
                f"BBO bid mismatch at replace op {i}: DUT={bid_p} model={mb} sym={sym}"
            assert ask_p == ma, \
                f"BBO ask mismatch at replace op {i}: DUT={ask_p} model={ma} sym={sym}"
