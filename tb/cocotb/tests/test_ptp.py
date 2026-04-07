"""test_ptp.py — Block-level tests for ptp_core.sv.

DUT: ptp_core
Clock: 3.2 ns (312.5 MHz — matches §3.2 sys_clk)

Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.8, §5 Phase 1

ptp_core behaviour (from RTL):
  - ptp_counter increments by 1 every clock cycle.
  - ptp_sync_pulse fires for 1 cycle when sync_cnt == 1022 (registered).
    With reset releasing at the start of a cycle and 1 settling edge in
    reset_dut, sync_cnt reaches 1022 after ~1021 further iterations (0-indexed):
    first pulse at loop index ~1021, second at ~2045; period = 1024 cycles.
  - ptp_epoch latches ptp_counter_r when sync_cnt == 1023 (one cycle after pulse).

See test_timestamp_tap.py for timestamp_tap DUT tests.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


# ---------------------------------------------------------------------------
# Helpers — ptp_core
# ---------------------------------------------------------------------------

async def reset_dut(dut):
    """3.2 ns clock (312.5 MHz); assert reset for 5 cycles then settle 1 cycle."""
    cocotb.start_soon(Clock(dut.clk, 3.2, unit='ns').start())
    dut.rst.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)



# ---------------------------------------------------------------------------
# Tests — ptp_core
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_counter_monotonic(dut):
    """ptp_counter must increment strictly monotonically for 2048 cycles."""
    await reset_dut(dut)

    prev = int(dut.ptp_counter.value)
    for i in range(2048):
        await RisingEdge(dut.clk)
        cur = int(dut.ptp_counter.value)
        assert cur > prev, \
            f"Counter must be strictly monotonic: cycle {i}, prev={prev}, cur={cur}"
        prev = cur


@cocotb.test()
async def test_sync_pulse_period(dut):
    """ptp_sync_pulse must fire exactly twice in 2058 cycles, period = 1024 ± 1."""
    await reset_dut(dut)

    pulse_cycles = []
    for i in range(2058):
        await RisingEdge(dut.clk)
        if int(dut.ptp_sync_pulse.value) == 1:
            pulse_cycles.append(i)

    assert len(pulse_cycles) == 2, \
        f"Expected exactly 2 sync pulses in 2058 cycles, found {len(pulse_cycles)} at {pulse_cycles}"

    period = pulse_cycles[1] - pulse_cycles[0]
    assert abs(period - 1024) <= 1, \
        f"sync_pulse period should be 1024 ± 1 cycles, got {period}"


@cocotb.test()
async def test_epoch_latches_at_sync(dut):
    """ptp_epoch must capture the counter value that was current when sync_cnt==1023."""
    await reset_dut(dut)

    # Wait for the first sync pulse.
    saved_counter = None
    for _ in range(2048):
        await RisingEdge(dut.clk)
        if int(dut.ptp_sync_pulse.value) == 1:
            # ptp_counter holds the value at this cycle (before next increment).
            saved_counter = int(dut.ptp_counter.value)
            break

    assert saved_counter is not None, "ptp_sync_pulse did not fire within 2048 cycles"

    # One cycle later sync_cnt reaches 1023 and epoch_r is updated.
    await RisingEdge(dut.clk)
    epoch = int(dut.ptp_epoch.value)

    assert epoch == saved_counter, \
        (f"ptp_epoch should latch the counter value at sync: "
         f"expected {saved_counter}, got {epoch}")


@cocotb.test()
async def test_counter_after_reset(dut):
    """After mid-run reset, ptp_counter must return to 0 and sync_pulse must deassert."""
    await reset_dut(dut)

    # Run 100 cycles.
    for _ in range(100):
        await RisingEdge(dut.clk)

    counter_before = int(dut.ptp_counter.value)
    assert counter_before > 0, "Counter should be > 0 after 100 cycles"

    # Apply reset: assert rst=1 and wait TWO rising edges.
    # In cocotb+Verilator, NBA assignments become readable at the NEXT edge
    # (the first await applies NBA at edge N; the second reads edge N's post-NBA).
    dut.rst.value = 1
    await RisingEdge(dut.clk)  # edge N  : rst=1 latched; NBA: ptp_counter_r <= 0
    await RisingEdge(dut.clk)  # edge N+1: stable read point (post-NBA of edge N)

    counter_after = int(dut.ptp_counter.value)
    pulse_after   = int(dut.ptp_sync_pulse.value)

    assert counter_after == 0, \
        f"ptp_counter must be 0 immediately after reset edge, got {counter_after}"
    assert pulse_after == 0, \
        f"ptp_sync_pulse must be 0 in reset, got {pulse_after}"

    dut.rst.value = 0



