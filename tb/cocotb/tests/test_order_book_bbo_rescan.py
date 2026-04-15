"""test_order_book_bbo_rescan.py — Phase 2 BBO full-rescan tests for order_book.sv.

DUT: order_book
Clock: 10 ns
Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.3, §7

Phase 1 BBO rule (still in RTL): delete/cancel resets BBO to 0 when the
removed order was at the BBO price.  There is no L2 rescan — the next-best
price level is lost.

These tests document the gap and verify BBO eventually converges to the
correct value after new Add orders arrive.  They also verify that orders on
the *opposite* side of the book are never affected by an operation on one side.

All tests use drive_op / read_bbo helpers imported from test_order_book to
avoid duplication.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from models.order_book_model import OrderBookModel

# ---------------------------------------------------------------------------
# Constants — ITCH message type bytes
# ---------------------------------------------------------------------------
MSG_ADD    = 0x41  # 'A'
MSG_DELETE = 0x44  # 'D'
MSG_CANCEL = 0x58  # 'X'


# ---------------------------------------------------------------------------
# Helpers (same as test_order_book to keep the file self-contained)
# ---------------------------------------------------------------------------

async def reset_dut(dut):
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
                   price, shares, side, sym_id, timeout=50):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.book_ready.value == 1:
            break
    dut.msg_type.value      = msg_type_byte
    dut.order_ref.value     = order_ref
    dut.new_order_ref.value = new_order_ref
    dut.price.value         = price
    dut.shares.value        = shares & 0xFFFFFF
    dut.side.value          = side
    dut.sym_id.value        = sym_id
    dut.fields_valid.value  = 1
    await RisingEdge(dut.clk)
    dut.fields_valid.value  = 0
    bbo_seen = False
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.bbo_valid.value == 1:
            bbo_seen = True
        if dut.book_ready.value == 1:
            return bbo_seen
    return False


async def read_bbo(dut, sym_id):
    dut.bbo_query_sym.value = sym_id
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
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
async def test_opposite_side_unaffected_by_bid_delete(dut):
    """Deleting the BBO bid must not disturb the ask side.

    Add a bid and an ask.  Delete the bid (which resets bid BBO to 0 under
    Phase-1 rules).  Confirm ask BBO is unchanged.
    """
    await reset_dut(dut)

    # Bid: ref=1, price=1000, shares=200
    await drive_op(dut, MSG_ADD, 1, 0, 1000, 200, 1, 0)
    # Ask: ref=2, price=1100, shares=300
    await drive_op(dut, MSG_ADD, 2, 0, 1100, 300, 0, 0)

    bid_p, ask_p, bid_s, ask_s = await read_bbo(dut, 0)
    assert bid_p == 1000, f"Pre-delete bid price expected 1000, got {bid_p}"
    assert ask_p == 1100, f"Pre-delete ask price expected 1100, got {ask_p}"

    # Delete the bid
    await drive_op(dut, MSG_DELETE, 1, 0, 1000, 200, 1, 0)

    bid_p2, ask_p2, bid_s2, ask_s2 = await read_bbo(dut, 0)
    assert bid_p2 == 0,    f"Post-delete bid price should be 0 (Phase-1 reset), got {bid_p2}"
    assert ask_p2 == 1100, f"Ask price must be unchanged after bid delete, got {ask_p2}"
    assert ask_s2 == 300,  f"Ask size must be unchanged, got {ask_s2}"


@cocotb.test()
async def test_bid_bbo_recovers_after_new_add(dut):
    """After a bid-BBO reset, a new Add must restore the BBO correctly.

    Phase-1 gap: no L2 rescan means the second-best price is lost.
    After deleting the BBO order and adding a new one, the BBO should
    reflect the new order's price.
    """
    await reset_dut(dut)

    # Add two bids: best at 2000, second at 1800
    await drive_op(dut, MSG_ADD, 10, 0, 2000, 500, 1, 1)
    await drive_op(dut, MSG_ADD, 11, 0, 1800, 300, 1, 1)

    bid_p, _, _, _ = await read_bbo(dut, 1)
    assert bid_p == 2000, f"Expected best bid 2000, got {bid_p}"

    # Delete the best bid — BBO resets to 0 (Phase-1 limitation; second-best lost)
    await drive_op(dut, MSG_DELETE, 10, 0, 2000, 500, 1, 1)

    bid_p2, _, _, _ = await read_bbo(dut, 1)
    assert bid_p2 == 0, f"Phase-1: BBO should reset to 0 after best-bid delete, got {bid_p2}"

    # Add a new bid at 1900 — BBO should recover to 1900
    await drive_op(dut, MSG_ADD, 12, 0, 1900, 400, 1, 1)

    bid_p3, _, bid_s3, _ = await read_bbo(dut, 1)
    assert bid_p3 == 1900, f"BBO should recover to 1900 after new add, got {bid_p3}"
    assert bid_s3 == 400,  f"BBO size should be 400, got {bid_s3}"


@cocotb.test()
async def test_ask_bbo_resets_on_delete_at_bbo_price(dut):
    """Deleting the BBO ask at its current price resets ask BBO to 0."""
    await reset_dut(dut)

    await drive_op(dut, MSG_ADD, 20, 0, 500, 100, 0, 2)  # ask side (side=0)
    bid_p, ask_p, _, ask_s = await read_bbo(dut, 2)
    assert ask_p == 500, f"Expected ask BBO 500, got {ask_p}"
    assert ask_s == 100

    await drive_op(dut, MSG_DELETE, 20, 0, 500, 100, 0, 2)
    _, ask_p2, _, ask_s2 = await read_bbo(dut, 2)
    assert ask_p2 == 0, f"Ask BBO should reset to 0 after delete, got {ask_p2}"
    assert ask_s2 == 0


@cocotb.test()
async def test_cancel_partial_does_not_reset_bbo(dut):
    """A partial cancel (type X) that does not fully remove the BBO order
    should NOT reset the BBO price under Phase-1 rules.

    The RTL resets BBO only when the *price* matches; a partial cancel at
    that price still leaves shares > 0 so the BBO price stays, but the
    size register is not individually decremented in Phase-1 (size is only
    set on Add operations).

    This test verifies that BBO price survives a partial cancel on a
    different-price order (non-BBO order) — i.e. cancel of a non-BBO order
    leaves BBO intact.
    """
    await reset_dut(dut)

    # BBO bid at price 3000
    await drive_op(dut, MSG_ADD, 30, 0, 3000, 200, 1, 3)
    # Second bid at price 2500 (below BBO)
    await drive_op(dut, MSG_ADD, 31, 0, 2500, 100, 1, 3)

    bid_p, _, _, _ = await read_bbo(dut, 3)
    assert bid_p == 3000, f"BBO bid should be 3000, got {bid_p}"

    # Cancel the non-BBO order (ref=31, price=2500) — BBO should not change
    await drive_op(dut, MSG_CANCEL, 31, 0, 2500, 50, 1, 3)

    bid_p2, _, _, _ = await read_bbo(dut, 3)
    assert bid_p2 == 3000, f"BBO must be unchanged after cancel of non-BBO order, got {bid_p2}"


@cocotb.test()
async def test_multi_symbol_isolation(dut):
    """Operations on sym_id=0 must not bleed into sym_id=1 or sym_id=10."""
    await reset_dut(dut)

    # Populate three symbols
    await drive_op(dut, MSG_ADD, 40, 0, 100, 10, 1, 0)
    await drive_op(dut, MSG_ADD, 41, 0, 200, 20, 1, 1)
    await drive_op(dut, MSG_ADD, 42, 0, 300, 30, 1, 10)

    bid0, _, _, _ = await read_bbo(dut, 0)
    bid1, _, _, _ = await read_bbo(dut, 1)
    bid10, _, _, _ = await read_bbo(dut, 10)
    assert bid0  == 100, f"sym0 expected 100, got {bid0}"
    assert bid1  == 200, f"sym1 expected 200, got {bid1}"
    assert bid10 == 300, f"sym10 expected 300, got {bid10}"

    # Delete sym0's order; sym1 and sym10 must be untouched
    await drive_op(dut, MSG_DELETE, 40, 0, 100, 10, 1, 0)

    bid0b, _, _, _ = await read_bbo(dut, 0)
    bid1b, _, _, _ = await read_bbo(dut, 1)
    bid10b, _, _, _ = await read_bbo(dut, 10)
    assert bid0b  == 0,   f"sym0 should be 0 after delete, got {bid0b}"
    assert bid1b  == 200, f"sym1 must be unchanged, got {bid1b}"
    assert bid10b == 300, f"sym10 must be unchanged, got {bid10b}"


@cocotb.test()
async def test_bbo_model_agrees_on_stress(dut):
    """50-operation stress: Python OrderBookModel and DUT BBO must agree on
    every Add operation.  Deletes at the BBO price reset to 0 (Phase-1).
    """
    import random
    random.seed(0xBB0_BE21)  # fixed seed for reproducibility

    await reset_dut(dut)
    model = OrderBookModel()

    active = {}   # order_ref → (price, shares, side, sym_id)
    ref_ctr = 0x1000

    for _ in range(50):
        sym = random.randint(0, 9)  # small symbol set for fast query verification

        if active and random.random() < 0.3:
            # Delete a randomly chosen active order
            ref = random.choice(list(active))
            price, shares, side, sym_id = active.pop(ref)
            await drive_op(dut, MSG_DELETE, ref, 0, price, shares, side, sym_id)
            model.delete(ref)
        else:
            # Add a new order
            ref_ctr += 1
            price  = random.randint(1, 9999)
            shares = random.randint(1, 500)
            side   = random.randint(0, 1)
            active[ref_ctr] = (price, shares, side, sym)
            await drive_op(dut, MSG_ADD, ref_ctr, 0, price, shares, side, sym)
            model.add(ref_ctr, price, shares, side, sym)

        # Check BBO for the symbol just touched
        m_bid_p, m_ask_p, m_bid_s, m_ask_s = model.get_bbo(sym)
        d_bid_p, d_ask_p, d_bid_s, d_ask_s = await read_bbo(dut, sym)

        assert d_bid_p == m_bid_p, f"sym={sym} bid_price: DUT={d_bid_p} model={m_bid_p}"
        assert d_ask_p == m_ask_p, f"sym={sym} ask_price: DUT={d_ask_p} model={m_ask_p}"
        assert d_bid_s == m_bid_s, f"sym={sym} bid_size:  DUT={d_bid_s} model={m_bid_s}"
        assert d_ask_s == m_ask_s, f"sym={sym} ask_size:  DUT={d_ask_s} model={m_ask_s}"
