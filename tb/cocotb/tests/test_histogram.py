"""test_histogram.py — Block-level tests for latency_histogram.sv.

DUT: latency_histogram
Clock: 3.2 ns (312.5 MHz)
Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.9

The histogram computes delta = t_end[9:0] − t_start_r[9:0] (10-bit unsigned
subtraction, so wrap-around is valid) and increments bin[delta[4:0]] when
delta ≤ 31, otherwise overflow_bin.

Bin read is combinatorial (axil_bin_data = hist_bins[axil_bin_addr]);
overflow_bin is also combinatorial.  One settling clock is awaited after
setting the read address to guarantee stable values after any write activity.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def reset_dut(dut):
    """3.2 ns clock; 5 reset cycles + 1 settling cycle."""
    cocotb.start_soon(Clock(dut.clk, 3.2, unit='ns').start())
    dut.rst.value          = 1
    dut.t_start_valid.value = 0
    dut.t_end_valid.value  = 0
    dut.t_start.value      = 0
    dut.t_end.value        = 0
    dut.axil_bin_addr.value = 0
    dut.axil_clear.value   = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_measurement(dut, start_sub, end_sub):
    """Drive a latency measurement using only the 10-bit sub-counter fields.

    t_start and t_end are 74-bit ports; upper 64 bits are left as 0 since
    the histogram only uses [9:0] for the delta computation.
    """
    dut.t_start.value       = start_sub & 0x3FF
    dut.t_start_valid.value = 1
    await RisingEdge(dut.clk)
    dut.t_start_valid.value = 0

    dut.t_end.value       = end_sub & 0x3FF
    dut.t_end_valid.value = 1
    await RisingEdge(dut.clk)
    dut.t_end_valid.value = 0

    # One extra cycle for the pipeline assignment to settle.
    await RisingEdge(dut.clk)


async def read_bin(dut, bin_idx):
    """Set axil_bin_addr, advance one clock, return axil_bin_data.

    axil_bin_data is combinatorial but the one-cycle settle guarantees that
    any concurrent write from the previous clock has been committed first.
    """
    dut.axil_bin_addr.value = bin_idx & 0x1F
    await RisingEdge(dut.clk)
    return int(dut.axil_bin_data.value)


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_single_measurement_bin0(dut):
    """start=0, end=0 → delta=0 → bin[0] increments to 1."""
    await reset_dut(dut)

    await drive_measurement(dut, 0, 0)

    count = await read_bin(dut, 0)
    assert count == 1, f"bin[0] should be 1 after delta=0 measurement, got {count}"


@cocotb.test()
async def test_bin_selection(dut):
    """For each delta in [0, 1, 5, 10, 15, 31]: drive one measurement, verify bin[delta]==1."""
    await reset_dut(dut)

    deltas = [0, 1, 5, 10, 15, 31]
    for d in deltas:
        await drive_measurement(dut, 0, d)  # start=0, end=d → delta=d

    for d in deltas:
        count = await read_bin(dut, d)
        assert count == 1, f"bin[{d}] expected 1 after single measurement, got {count}"


@cocotb.test()
async def test_overflow_bin(dut):
    """start=0, end=32 → delta=32 > 31 → overflow_bin increments."""
    await reset_dut(dut)

    await drive_measurement(dut, 0, 32)

    # overflow_bin is combinatorial; settle one cycle after last measurement.
    await RisingEdge(dut.clk)
    overflow = int(dut.overflow_bin.value)
    assert overflow == 1, f"overflow_bin should be 1 after delta=32, got {overflow}"

    # bin[0] should NOT have incremented.
    count_b0 = await read_bin(dut, 0)
    assert count_b0 == 0, f"bin[0] must remain 0 for an overflow measurement, got {count_b0}"


@cocotb.test()
async def test_multiple_increments(dut):
    """Drive 10 measurements all with delta=5; bin[5] must reach 10."""
    await reset_dut(dut)

    for _ in range(10):
        await drive_measurement(dut, 0, 5)

    count = await read_bin(dut, 5)
    assert count == 10, f"bin[5] should be 10 after 10 measurements, got {count}"


@cocotb.test()
async def test_clear(dut):
    """Fill several bins and the overflow bin, then assert axil_clear; all must read 0."""
    await reset_dut(dut)

    # Fill bin[3] and bin[7], plus trigger an overflow.
    await drive_measurement(dut, 0, 3)
    await drive_measurement(dut, 0, 7)
    await drive_measurement(dut, 0, 32)  # overflow

    # Verify bins are non-zero before clear.
    assert await read_bin(dut, 3) == 1, "setup: bin[3] should be 1 before clear"
    assert await read_bin(dut, 7) == 1, "setup: bin[7] should be 1 before clear"
    await RisingEdge(dut.clk)
    assert int(dut.overflow_bin.value) == 1, "setup: overflow_bin should be 1 before clear"

    # Assert clear for exactly 1 cycle.
    dut.axil_clear.value = 1
    await RisingEdge(dut.clk)
    dut.axil_clear.value = 0

    # All histogram bins must now be 0.
    for idx in range(32):
        count = await read_bin(dut, idx)
        assert count == 0, f"bin[{idx}] should be 0 after axil_clear, got {count}"

    await RisingEdge(dut.clk)
    overflow = int(dut.overflow_bin.value)
    assert overflow == 0, f"overflow_bin should be 0 after axil_clear, got {overflow}"


@cocotb.test()
async def test_sub_counter_wrap(dut):
    """10-bit wrap-around: start=1020, end=5 → delta=(5−1020)&0x3FF=9 → bin[9]."""
    await reset_dut(dut)

    # Expected: (5 - 1020) mod 1024 = 9
    await drive_measurement(dut, 1020, 5)

    count = await read_bin(dut, 9)
    assert count == 1, \
        f"bin[9] should be 1 after wrap-around measurement (start=1020, end=5), got {count}"

    # Confirm bin[0] is untouched (delta != 0).
    count_b0 = await read_bin(dut, 0)
    assert count_b0 == 0, f"bin[0] must be 0 for a delta=9 measurement, got {count_b0}"
