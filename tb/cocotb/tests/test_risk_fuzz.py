"""test_risk_fuzz.py — Fuzz and boundary tests for risk_check.sv.

DUT: risk_check
Clock: 10 ns (matches order_book test convention)
Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.6, §7

Three parallel risk rules, each verified independently and in combination:
  1. Price-band   : |price - ref_price| > band_bps × ref_price / 10000
  2. Fat-finger   : proposed_shares > max_qty
  3. Position-limit: cumulative net shares > pos_limit
  4. Kill switch  : AXI4-Lite write-one-to-set; gates all orders

Back-to-back ordering hazard note (spec §4.6): the position BRAM has a
1-cycle write latency.  Tests that need accurate position-limit checks on
consecutive same-symbol orders must wait at least 2 cycles between drives.
"""

import random
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

# ---------------------------------------------------------------------------
# DUT latency (spec §4.6): risk_pass / risk_blocked valid 2 cycles after
# score_valid.  We drive score_valid for 1 cycle, then advance 1 more clock
# edge (total 2 registered stages) and sample on ReadOnly (NBA settled).
# ---------------------------------------------------------------------------
RISK_LATENCY = 1  # extra cycles to wait AFTER the score_valid cycle


async def reset_dut(dut):
    """Start 10 ns clock; hold reset for 5 cycles; initialize all inputs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.rst.value             = 1
    dut.score_valid.value     = 0
    dut.side.value            = 1          # buy by default
    dut.price.value           = 10_000
    dut.symbol_id.value       = 0
    dut.proposed_shares.value = 100
    dut.tx_overflow.value     = 0
    dut.band_bps.value        = 200        # 2% band
    dut.max_qty.value         = 10_000
    dut.pos_limit.value       = 50_000
    dut.kill_sw.value         = 0
    dut.ref_price.value       = 10_000
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_order(dut, price, shares, ref_price, sym_id=0,
                      side=1, band_bps=None, max_qty=None,
                      pos_limit=None, kill_sw=None, tx_overflow=None):
    """Pulse score_valid for one cycle with the given parameters.

    Configures thresholds before pulsing if supplied.
    Returns (risk_pass, risk_blocked, block_reason) sampled RISK_LATENCY+1
    cycles later.
    """
    if band_bps   is not None: dut.band_bps.value   = band_bps
    if max_qty    is not None: dut.max_qty.value     = max_qty
    if pos_limit  is not None: dut.pos_limit.value   = pos_limit
    if kill_sw    is not None: dut.kill_sw.value     = kill_sw
    if tx_overflow is not None: dut.tx_overflow.value = tx_overflow

    dut.price.value           = price
    dut.proposed_shares.value = shares & 0xFFFFFF
    dut.ref_price.value       = ref_price
    dut.symbol_id.value       = sym_id
    dut.side.value            = side
    dut.score_valid.value     = 1
    await RisingEdge(dut.clk)
    dut.score_valid.value     = 0

    # Advance RISK_LATENCY cycles, then sample on ReadOnly (NBA settled)
    for _ in range(RISK_LATENCY):
        await RisingEdge(dut.clk)
    await ReadOnly()

    return (
        int(dut.risk_pass.value),
        int(dut.risk_blocked.value),
        int(dut.block_reason.value),
    )


# ---------------------------------------------------------------------------
# Price-band tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_price_band_pass(dut):
    """Price within band (0% deviation) must pass."""
    await reset_dut(dut)
    # price == ref_price  →  deviation = 0  → well within any band
    rpass, rblock, reason = await drive_order(
        dut, price=10_000, shares=100, ref_price=10_000, band_bps=200)
    assert rpass  == 1, f"Expected risk_pass, got pass={rpass} block={rblock}"
    assert rblock == 0


@cocotb.test()
async def test_price_band_just_under(dut):
    """Price deviation exactly at threshold boundary must pass.

    RTL: band_thresh = (ref_price * band_bps) >> 13  (≈ /10000, err < 2.4%)
    With ref=10000 and band_bps=200:
      band_thresh = (10000 * 200) >> 13 = 2000000 >> 13 = 244
    price_diff < 244 → pass.
    """
    await reset_dut(dut)
    rpass, rblock, _ = await drive_order(
        dut, price=10_000 + 243, shares=100, ref_price=10_000, band_bps=200)
    assert rpass == 1,  f"Price within band should pass; got pass={rpass}"
    assert rblock == 0


@cocotb.test()
async def test_price_band_violation(dut):
    """Price far outside band must be blocked; block_reason==2'b01."""
    await reset_dut(dut)
    # Deviation = 5000 >> well above 244 threshold
    rpass, rblock, reason = await drive_order(
        dut, price=15_000, shares=100, ref_price=10_000, band_bps=200)
    assert rblock == 1,    f"Expected risk_blocked, got block={rblock}"
    assert rpass  == 0
    assert reason == 0b01, f"block_reason should be 01 (price-band), got {reason:02b}"


@cocotb.test()
async def test_price_band_boundary_sweep(dut):
    """Sweep price from ref_price upward; verify first block at correct threshold."""
    await reset_dut(dut)
    ref = 20_000
    band = 100  # band_thresh = (20000 * 100) >> 13 = 2000000 >> 13 = 244
    first_block = None
    for delta in range(0, 500):
        rpass, rblock, _ = await drive_order(
            dut, price=ref + delta, shares=10, ref_price=ref, band_bps=band)
        if rblock and first_block is None:
            first_block = delta
            break
        # Inter-order gap: wait 2 extra cycles to avoid position-BRAM hazard
        await RisingEdge(dut.clk)
        await RisingEdge(dut.clk)

    assert first_block is not None, "Expected at least one blocked order in sweep"
    # Allow ±2 for RTL approximation error (2.4% max per spec comment)
    expected = (ref * band) >> 13
    assert abs(first_block - expected) <= 2, (
        f"First block at delta={first_block}, expected ≈{expected}")


# ---------------------------------------------------------------------------
# Fat-finger tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_fat_finger_pass(dut):
    """Shares below max_qty limit must pass."""
    await reset_dut(dut)
    rpass, rblock, _ = await drive_order(
        dut, price=10_000, shares=9_999, ref_price=10_000, max_qty=10_000)
    assert rpass == 1,  f"shares < max_qty should pass; got block={rblock}"
    assert rblock == 0


@cocotb.test()
async def test_fat_finger_equal_passes(dut):
    """Shares exactly equal to max_qty must pass (rule is strictly greater-than)."""
    await reset_dut(dut)
    rpass, rblock, _ = await drive_order(
        dut, price=10_000, shares=10_000, ref_price=10_000, max_qty=10_000)
    assert rpass == 1,  f"shares == max_qty should still pass; got block={rblock}"


@cocotb.test()
async def test_fat_finger_violation(dut):
    """Shares exceeding max_qty must be blocked; block_reason==2'b10."""
    await reset_dut(dut)
    rpass, rblock, reason = await drive_order(
        dut, price=10_000, shares=10_001, ref_price=10_000, max_qty=10_000)
    assert rblock == 1,    f"Expected blocked; got block={rblock}"
    assert rpass  == 0
    assert reason == 0b10, f"block_reason should be 10 (fat-finger), got {reason:02b}"


@cocotb.test()
async def test_fat_finger_max_shares(dut):
    """Maximum 24-bit shares (0xFFFFFF) with a strict max_qty must always block."""
    await reset_dut(dut)
    rpass, rblock, reason = await drive_order(
        dut, price=10_000, shares=0xFFFFFF, ref_price=10_000, max_qty=100)
    assert rblock == 1,    f"Max shares must be blocked; got block={rblock}"
    assert reason == 0b10, f"block_reason should be fat-finger, got {reason:02b}"


# ---------------------------------------------------------------------------
# Position-limit tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_position_limit_pass(dut):
    """First order within position limit must pass."""
    await reset_dut(dut)
    # Fresh reset → position BRAM is 0 for all symbols
    rpass, rblock, _ = await drive_order(
        dut, price=10_000, shares=1_000, ref_price=10_000,
        sym_id=5, pos_limit=50_000)
    assert rpass == 1,  f"First order within limit should pass; block={rblock}"
    assert rblock == 0


@cocotb.test()
async def test_position_limit_cumulates_and_blocks(dut):
    """Two orders on the same symbol: cumulative net exceeds pos_limit → block.

    Uses distinct symbols to avoid cross-contamination.  Waits 3 cycles
    between orders to ensure pos BRAM writeback from pass #1 is visible.
    """
    await reset_dut(dut)
    SYM = 7
    LIMIT = 500

    # Order 1: 400 shares — passes (net=400 ≤ 500)
    rpass1, rblock1, _ = await drive_order(
        dut, price=10_000, shares=400, ref_price=10_000, sym_id=SYM,
        pos_limit=LIMIT)
    assert rpass1 == 1 and rblock1 == 0, (
        f"First order should pass; got pass={rpass1} block={rblock1}")

    # Wait ≥2 extra cycles for BRAM writeback (spec §4.6 hazard note)
    for _ in range(3):
        await RisingEdge(dut.clk)

    # Order 2: 200 shares → net=600 > 500 → should be blocked
    rpass2, rblock2, reason2 = await drive_order(
        dut, price=10_000, shares=200, ref_price=10_000, sym_id=SYM)
    assert rblock2 == 1,     f"Second order should be blocked; got pass={rpass2}"
    assert reason2 == 0b11,  f"block_reason should be 11 (position-limit), got {reason2:02b}"


@cocotb.test()
async def test_position_limit_different_symbols_independent(dut):
    """Position limit for sym A must not affect sym B."""
    await reset_dut(dut)

    # Fill sym=20 to near-limit
    rpass_a, _, _ = await drive_order(
        dut, price=10_000, shares=9_000, ref_price=10_000,
        sym_id=20, pos_limit=10_000)
    assert rpass_a == 1, "sym=20 first order should pass"
    for _ in range(3):
        await RisingEdge(dut.clk)

    # sym=21 is untouched; first order should pass even with same pos_limit
    rpass_b, rblock_b, _ = await drive_order(
        dut, price=10_000, shares=9_000, ref_price=10_000,
        sym_id=21, pos_limit=10_000)
    assert rpass_b  == 1, f"sym=21 should be independent; got block={rblock_b}"
    assert rblock_b == 0


# ---------------------------------------------------------------------------
# Kill-switch tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_kill_switch_blocks_all(dut):
    """A risk_pass-eligible order must be blocked when kill_sw=1."""
    await reset_dut(dut)
    # Order that would otherwise pass all three rules
    rpass, rblock, reason = await drive_order(
        dut, price=10_000, shares=100, ref_price=10_000,
        kill_sw=1)
    assert rblock == 1, f"Kill switch must block all orders; got pass={rpass}"
    assert rpass  == 0
    # block_reason is 2'b00 for kill-switch (no rule code assigned per spec)
    assert reason == 0b00, f"Kill-switch block_reason should be 00, got {reason:02b}"


@cocotb.test()
async def test_kill_switch_deassert_allows_pass(dut):
    """Once kill_sw is deasserted, a clean order must pass."""
    await reset_dut(dut)
    dut.kill_sw.value = 1
    await RisingEdge(dut.clk)
    dut.kill_sw.value = 0
    await RisingEdge(dut.clk)

    rpass, rblock, _ = await drive_order(
        dut, price=10_000, shares=100, ref_price=10_000, sym_id=30)
    assert rpass  == 1, f"Order should pass after kill_sw cleared; block={rblock}"
    assert rblock == 0


# ---------------------------------------------------------------------------
# tx_overflow auto-kill test
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_tx_overflow_blocks_order(dut):
    """tx_overflow acts as an auto-kill; order must be blocked while high."""
    await reset_dut(dut)
    rpass, rblock, reason = await drive_order(
        dut, price=10_000, shares=100, ref_price=10_000,
        tx_overflow=1)
    assert rblock == 1, f"tx_overflow must block order; got pass={rpass}"
    assert rpass  == 0
    # tx_overflow shares the kill-switch path: block_reason == 00
    assert reason == 0b00

    # After clearing tx_overflow a clean order must pass
    await RisingEdge(dut.clk)   # advance out of ReadOnly phase first
    dut.tx_overflow.value = 0
    await RisingEdge(dut.clk)
    rpass2, rblock2, _ = await drive_order(
        dut, price=10_000, shares=100, ref_price=10_000, sym_id=40)
    assert rpass2  == 1, f"Order should pass after tx_overflow cleared; block={rblock2}"


# ---------------------------------------------------------------------------
# Combinational-rule interaction test
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_multiple_violations_any_blocks(dut):
    """When both price-band AND fat-finger rules fail, the order must be blocked."""
    await reset_dut(dut)
    # price way outside band AND shares >> max_qty
    rpass, rblock, _ = await drive_order(
        dut, price=99_999, shares=0xFFFFFF,
        ref_price=10_000, band_bps=200, max_qty=100)
    assert rblock == 1, f"Multiple violations must block; got pass={rpass}"
    assert rpass  == 0


@cocotb.test()
async def test_fuzz_random_100_orders(dut):
    """100 random orders against a Python reference model; verify every result."""
    random.seed(0xF122_F022)  # fixed seed for reproducibility
    await reset_dut(dut)

    # Fixed thresholds for this fuzz run
    BAND   = 500    # band_bps
    MAXQTY = 5_000
    PLIMIT = 20_000
    REF    = 50_000
    SYM    = 50     # use one symbol to test position accumulation

    net_pos = 0

    for _ in range(100):
        price  = random.randint(1, 100_000)
        shares = random.randint(1, 10_000)
        side   = 1  # buy only to accumulate position simply

        # ------ Python reference model ------
        band_thresh = (REF * BAND) >> 13
        price_diff  = abs(price - REF)
        band_fail   = price_diff > band_thresh
        fat_fail    = shares > MAXQTY
        pos_fail    = (net_pos + shares) > PLIMIT
        expect_pass = not (band_fail or fat_fail or pos_fail)

        rpass, rblock, _ = await drive_order(
            dut, price=price, shares=shares, ref_price=REF,
            sym_id=SYM, side=side,
            band_bps=BAND, max_qty=MAXQTY, pos_limit=PLIMIT,
            kill_sw=0, tx_overflow=0)

        assert (rpass == 1) == expect_pass, (
            f"price={price} shares={shares} net={net_pos}: "
            f"expected pass={expect_pass} but got pass={rpass} block={rblock} "
            f"(band_fail={band_fail} fat_fail={fat_fail} pos_fail={pos_fail})")

        if expect_pass:
            net_pos += shares

        # Wait for BRAM writeback before next order on same symbol
        for _ in range(3):
            await RisingEdge(dut.clk)
