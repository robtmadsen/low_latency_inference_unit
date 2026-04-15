"""test_tx_backpressure_kill.py — Backpressure soft-kill tests for ouch_engine.sv.

DUT: ouch_engine
Clock: 10 ns
Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.7

Backpressure soft-kill behaviour (from spec):
  • If m_axis_tready remains deasserted for > 64 consecutive cycles during
    SEND state, tx_overflow pulses high.
  • tx_overflow self-clears after m_axis_tready is asserted for ≥ 256
    consecutive cycles (backlog drained).

tx_overflow is wired back to risk_check which auto-asserts the kill switch.
These tests verify tx_overflow timing directly at the ouch_engine boundary.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

TOTAL_BEATS = 6


# ---------------------------------------------------------------------------
# Helpers (shared with test_ouch_compliance; kept self-contained)
# ---------------------------------------------------------------------------

async def reset_dut(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.rst.value             = 1
    dut.risk_pass.value       = 0
    dut.side.value            = 1
    dut.price.value           = 10_000
    dut.symbol_id.value       = 0
    dut.proposed_shares.value = 100
    dut.timestamp.value       = 0
    dut.tmpl_wr_addr.value    = 0
    dut.tmpl_wr_data.value    = 0
    dut.tmpl_wr_en.value      = 0
    dut.m_axis_tready.value   = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def write_template(dut, sym_id: int, stock: bytes = b'AAPL    ',
                         tif: int = 0, firm: bytes = b'FIRM',
                         display: int = 0x59):
    assert len(stock) == 8 and len(firm) == 4
    stock_int = int.from_bytes(stock, 'big')
    firm_int  = int.from_bytes(firm,  'big')
    b2_val = (stock_int >> 32) & 0xFFFF_FFFF
    b3_val = stock_int & 0xFFFF_FFFF
    b4_val = ((tif & 0xFFFF_FFFF) << 32) | (firm_int & 0xFFFF_FFFF)
    b5_val = (display & 0xFF) << 24
    base_addr = sym_id << 2
    for offset, val in enumerate([b2_val, b3_val, b4_val, b5_val]):
        dut.tmpl_wr_addr.value = base_addr | offset
        dut.tmpl_wr_data.value = val & 0xFFFF_FFFF_FFFF_FFFF
        dut.tmpl_wr_en.value   = 1
        await RisingEdge(dut.clk)
    dut.tmpl_wr_en.value = 0
    await RisingEdge(dut.clk)


async def trigger_order(dut, price=10_000, shares=100, sym_id=0, side=1):
    """Pulse risk_pass; do not drain the packet (leave tready=0)."""
    dut.price.value           = price
    dut.proposed_shares.value = shares & 0xFFFFFF
    dut.symbol_id.value       = sym_id
    dut.side.value            = side
    dut.timestamp.value       = 0
    dut.risk_pass.value       = 1
    await RisingEdge(dut.clk)
    dut.risk_pass.value       = 0


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_no_overflow_when_tready_asserted(dut):
    """tx_overflow must remain 0 when m_axis_tready is always 1."""
    await reset_dut(dut)
    await write_template(dut, sym_id=0)
    dut.m_axis_tready.value = 1

    await trigger_order(dut)

    # Watch for 120 cycles — well beyond any backpressure threshold
    for _ in range(120):
        await RisingEdge(dut.clk)
        await ReadOnly()
        assert int(dut.tx_overflow.value) == 0, "tx_overflow asserted unexpectedly"


@cocotb.test()
async def test_overflow_after_64_stalled_cycles(dut):
    """tx_overflow must assert when tready is held low during SEND for > 64 cycles.

    Sequence:
      1. Assert tready=0 (from the start) so the packet cannot drain.
      2. Trigger an order → DUT enters SEND state.
      3. Poll tx_overflow; it must assert at or before cycle 64 of stalling.
    """
    await reset_dut(dut)
    await write_template(dut, sym_id=0)

    # Block the consumer before triggering
    dut.m_axis_tready.value = 0
    await trigger_order(dut)

    # Poll tx_overflow; spec says it asserts after 64 consecutive stalled cycles
    overflow_cycle = None
    for cyc in range(120):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.tx_overflow.value) == 1 and overflow_cycle is None:
            overflow_cycle = cyc
            break

    assert overflow_cycle is not None, \
        "tx_overflow never asserted after 64 stalled cycles"
    assert overflow_cycle <= 70, \
        f"tx_overflow took {overflow_cycle} cycles; expected ≤70 (spec: 64 + FSM delay)"


@cocotb.test()
async def test_overflow_self_clears_after_256_free_cycles(dut):
    """tx_overflow must self-clear after m_axis_tready is held asserted for
    ≥ 256 consecutive cycles (backlog drained condition per spec §4.7).
    """
    await reset_dut(dut)
    await write_template(dut, sym_id=0)

    # Step 1: cause overflow (tready=0 for 70+ cycles)
    dut.m_axis_tready.value = 0
    await trigger_order(dut)

    for _ in range(80):
        await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.tx_overflow.value) == 1, "tx_overflow should be set before test proceeds"

    # Step 2: drain remaining beats and hold tready=1
    # Advance a clock edge out of ReadOnly before driving
    await RisingEdge(dut.clk)
    dut.m_axis_tready.value = 1

    clear_cycle = None
    for cyc in range(350):
        await RisingEdge(dut.clk)
        await ReadOnly()
        if int(dut.tx_overflow.value) == 0 and clear_cycle is None:
            clear_cycle = cyc
            break

    assert clear_cycle is not None, \
        "tx_overflow never self-cleared after 350 cycles of tready=1"
    assert clear_cycle <= 270, \
        f"tx_overflow persisted for {clear_cycle} cycles; spec says ≤ 256"


@cocotb.test()
async def test_valid_order_after_overflow_blocked(dut):
    """Orders triggered immediately after tx_overflow asserts are effectively
    blocked from draining until tready is re-asserted.  Once tready is
    restored, the in-flight beat stream completes correctly (tlast arrives).
    """
    await reset_dut(dut)
    await write_template(dut, sym_id=0)

    # Trigger an order with back-pressure to force overflow state
    dut.m_axis_tready.value = 0
    await trigger_order(dut)
    # Let overflow assert
    for _ in range(80):
        await RisingEdge(dut.clk)

    # Now re-enable consumer; outstanding beat stream should complete with tlast
    dut.m_axis_tready.value = 1

    tlast_seen = False
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            if int(dut.m_axis_tlast.value) == 1:
                tlast_seen = True
                break

    assert tlast_seen, "tlast must arrive after tready is restored"


@cocotb.test()
async def test_partial_stall_no_overflow(dut):
    """Brief stalls (< 64 consecutive cycles) must NOT trigger tx_overflow."""
    await reset_dut(dut)
    await write_template(dut, sym_id=0)

    await trigger_order(dut)

    # Toggle tready every 30 cycles; never holds low for 64+ cycles
    for i in range(4):
        dut.m_axis_tready.value = 0
        for _ in range(30):
            await RisingEdge(dut.clk)
            await ReadOnly()
            assert int(dut.tx_overflow.value) == 0, \
                f"tx_overflow must not assert during brief {30}-cycle stall (iteration {i})"
        # Advance a fresh clock edge before driving (out of ReadOnly)
        await RisingEdge(dut.clk)
        dut.m_axis_tready.value = 1
        await RisingEdge(dut.clk)
