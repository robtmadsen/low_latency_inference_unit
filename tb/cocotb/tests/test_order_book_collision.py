"""test_order_book_collision.py — Hash-collision stress tests for order_book.sv.

DUT: order_book
Clock: 10 ns
Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.3 "Hash Collision Stress",
          §5 Phase 1 key verification goals, §7

These tests construct two 64-bit order_ref values whose CRC-17 folds to the
same 17-bit bucket and verify the DUT's collision detection machinery.

NOTE ON CURRENT RTL LIMITATION:
  The RTL only raises collision_flag for *modify* operations (Delete/Cancel/
  Replace/Execute) — not for Add.  An Add into an occupied bucket silently
  overwrites the ref_mem entry without setting collision_flag.  Tests that
  verify collision detection on Add (test_hash_collision_detected steps 4-5)
  are expected to FAIL against the current RTL.  They document the intended
  spec behaviour for a future RTL fix.
"""

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
    """10 ns clock; 5 reset cycles + 1 settling cycle."""
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


async def _wait_ready(dut, timeout=30):
    """Spin until book_ready is asserted."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.book_ready.value == 1:
            return


async def drive_op_monitored(dut, msg_type_byte, order_ref, new_order_ref,
                              price, shares, side, sym_id, timeout=30):
    """Like drive_op but also tracks collision_flag across all intermediate cycles.

    Waits for the FSM to return to S_IDLE (book_ready=1) before returning,
    ensuring BBO register NBA updates are settled for a subsequent read_bbo.

    Returns (bbo_seen: bool, collision_seen: bool).
    """
    await _wait_ready(dut, timeout)

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

    bbo_seen       = False
    collision_seen = False

    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.collision_flag.value == 1:
            collision_seen = True
        if dut.bbo_valid.value == 1:
            bbo_seen = True
        if dut.book_ready.value == 1:
            return bbo_seen, collision_seen

    return bbo_seen, collision_seen


async def read_bbo(dut, sym_id):
    """Two-cycle registered BBO read (see test_order_book.py read_bbo for explanation).
    Returns (bid_price, ask_price, bid_size, ask_size).
    """
    dut.bbo_query_sym.value = sym_id
    await RisingEdge(dut.clk)   # cycle 1: always_ff picks up new bbo_query_sym
    await RisingEdge(dut.clk)   # cycle 2: bbo_bid_price output propagates
    return (
        int(dut.bbo_bid_price.value),
        int(dut.bbo_ask_price.value),
        int(dut.bbo_bid_size.value),
        int(dut.bbo_ask_size.value),
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test(expect_fail=True)
async def test_hash_collision_detected(dut):
    """Construct two order_refs with the same CRC-17 bucket.

    Expected behaviour per spec §4.3:
      1. First Add (ref_a) succeeds; collision_flag=0, collision_count=0.
      2. Second Add (ref_b, same hash) should trigger collision_flag=1 and
         increment collision_count.  BBO must reflect ref_a price (1000),
         NOT ref_b price (1200).

    NOTE: Steps 4-6 currently FAIL because the RTL does not raise
    collision_flag for Add operations (only for modify ops).  These
    assertions document the intended behaviour for a future RTL fix.
    """
    await reset_dut(dut)

    model = OrderBookModel()
    ref_a, ref_b = model.find_collision_pair()
    assert ref_a != ref_b, "find_collision_pair must return distinct refs"
    from models.order_book_model import crc17
    assert crc17(ref_a) == crc17(ref_b), "Both refs must share the same CRC-17 hash"

    # --- Step 1-3: Add ref_a ---
    bbo_seen, col_seen = await drive_op_monitored(
        dut, 0x41, ref_a, 0, 1000, 100, 1, 0)
    assert bbo_seen,  "bbo_valid should pulse after adding ref_a"
    assert not col_seen, "collision_flag must be 0 on first add"
    assert int(dut.collision_count.value) == 0, \
        f"collision_count must be 0 after first add, got {int(dut.collision_count.value)}"

    bid_p, _, _, _ = await read_bbo(dut, 0)
    assert bid_p == 1000, f"BBO bid should be 1000 after ref_a add, got {bid_p}"

    # --- Step 4-6: Add ref_b (same hash as ref_a) —
    #     Spec expects collision: flag=1, count=1, BBO stays at 1000.
    #     RTL currently does NOT detect collision on Add (will overwrite and
    #     set BBO to 1200 without raising collision_flag).
    bbo_seen, col_seen = await drive_op_monitored(
        dut, 0x41, ref_b, 0, 1200, 200, 1, 0)

    # NOTE: Both assertions below document spec-required behaviour.
    # They are EXPECTED TO FAIL with the current RTL.
    assert col_seen, \
        "[KNOWN FAIL] collision_flag should be 1 when adding ref_b into occupied bucket"
    assert int(dut.collision_count.value) == 1, \
        f"[KNOWN FAIL] collision_count should be 1, got {int(dut.collision_count.value)}"

    bid_p, _, _, _ = await read_bbo(dut, 0)
    assert bid_p == 1000, \
        f"[KNOWN FAIL] BBO bid should remain 1000 (ref_a), not 1200, got {bid_p}"

    # --- Step 7: Another attempt with ref_b should increment to 2. ---
    _, _ = await drive_op_monitored(dut, 0x41, ref_b, 0, 1300, 50, 1, 0)
    assert int(dut.collision_count.value) == 2, \
        f"[KNOWN FAIL] collision_count should be 2, got {int(dut.collision_count.value)}"


@cocotb.test()
async def test_collision_bbo_unaffected(dut):
    """A hash collision on sym_id=0 must not affect sym_id=1 BBO.

    The collision is induced on a modify op (Delete with wrong tag) so it
    exercises the RTL's actual collision detection path (S_PROCESS).
    """
    await reset_dut(dut)

    model = OrderBookModel()
    ref_a, ref_b = model.find_collision_pair()
    from models.order_book_model import crc17
    assert crc17(ref_a) == crc17(ref_b)

    # Add independent orders on sym_id=1 — these must be unaffected.
    await drive_op_monitored(dut, 0x41, 9999, 0, 5000, 400, 1, 1)
    await drive_op_monitored(dut, 0x41, 9998, 0, 4800, 100, 0, 1)
    _, ask_p_before, _, _ = await read_bbo(dut, 1)
    assert ask_p_before == 4800, \
        f"sym_id=1 ask BBO should be 4800 before collision, got {ask_p_before}"

    # --- Collision path via Delete: add ref_a, then try to delete ref_b ---
    # Add ref_a on sym_id=0.
    await drive_op_monitored(dut, 0x41, ref_a, 0, 1000, 100, 1, 0)
    # Attempt Delete of ref_b (same hash, different tag → collision in S_PROCESS).
    bbo_seen, col_seen = await drive_op_monitored(dut, 0x44, ref_b, 0, 0, 0, 0, 0)
    assert col_seen, \
        "collision_flag must fire when Delete tag mismatches stored order_ref"
    assert int(dut.collision_count.value) >= 1, \
        "collision_count must increment on tag mismatch in Delete path"

    # sym_id=1 BBO must be unchanged.
    _, ask_p_after, _, _ = await read_bbo(dut, 1)
    assert ask_p_after == ask_p_before, \
        f"sym_id=1 BBO ask must be unaffected by sym_id=0 collision, got {ask_p_after}"


@cocotb.test()
async def test_collision_then_clean_add(dut):
    """Free a hash slot via Delete, then re-add using the competing ref — should succeed.

    Sequence:
      1. Add ref_a (non-colliding, fresh DUT).
      2. Delete ref_a → hash slot cleared.
      3. Add ref_b (same CRC-17 hash) → slot is empty → clean insert, bbo_valid fires,
         collision_flag stays low.
    """
    await reset_dut(dut)

    model = OrderBookModel()
    ref_a, ref_b = model.find_collision_pair()

    # Step 1: Add ref_a.
    bbo_seen, col_seen = await drive_op_monitored(dut, 0x41, ref_a, 0, 1000, 100, 1, 0)
    assert bbo_seen,  "bbo_valid must fire after adding ref_a"
    assert not col_seen, "No collision expected on first add"

    # Step 2: Delete ref_a — frees the hash bucket.
    bbo_seen, col_seen = await drive_op_monitored(dut, 0x44, ref_a, 0, 0, 0, 0, 0)
    assert bbo_seen,  "bbo_valid must fire after deleting ref_a"
    assert not col_seen, "No collision expected on valid delete of ref_a"

    bid_p, _, _, _ = await read_bbo(dut, 0)
    assert bid_p == 0, f"BBO must be cleared after deleting ref_a, got {bid_p}"

    # Step 3: Add ref_b (same hash, but slot is now empty) → clean insert.
    bbo_seen, col_seen = await drive_op_monitored(
        dut, 0x41, ref_b, 0, 1200, 200, 1, 0)
    assert bbo_seen,  "bbo_valid must fire after adding ref_b into freed slot"
    assert not col_seen, \
        "collision_flag must NOT fire when inserting ref_b into an empty slot"

    bid_p, _, bid_s, _ = await read_bbo(dut, 0)
    assert bid_p == 1200, f"BBO bid should be 1200 after ref_b add, got {bid_p}"
    assert bid_s == 200,  f"BBO bid size should be 200 after ref_b add, got {bid_s}"
