"""Tests for fp32_acc accumulator."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from utils.bfloat16 import fp32_to_bits, bits_to_fp32


@cocotb.test()
async def test_fp32_acc_accumulate(dut):
    """Accumulate N addends and check running sum."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())

    # Reset
    dut.rst.value = 1
    dut.acc_en.value = 0
    dut.acc_clear.value = 0
    dut.addend.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    # Accumulate: 1.0 + 2.0 + 3.0 + 4.0 = 10.0
    values = [1.0, 2.0, 3.0, 4.0]

    for val in values:
        dut.addend.value = fp32_to_bits(val)
        dut.acc_en.value = 1
        await RisingEdge(dut.clk)

    dut.acc_en.value = 0
    await RisingEdge(dut.clk)  # edge N+1: acc_en_d1 was 1, Stage 2 commits via NBA
    await RisingEdge(dut.clk)  # edge N+2: read in active phase after Stage 2 NBA settled

    result = bits_to_fp32(int(dut.acc_out.value))
    assert abs(result - 10.0) < 0.01, f"Expected 10.0, got {result}"
    dut._log.info(f"PASS: accumulate sum = {result}")


@cocotb.test()
async def test_fp32_acc_clear(dut):
    """Verify accumulator resets on clear signal."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())

    # Reset
    dut.rst.value = 1
    dut.acc_en.value = 0
    dut.acc_clear.value = 0
    dut.addend.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    # Accumulate some values
    for val in [5.0, 10.0]:
        dut.addend.value = fp32_to_bits(val)
        dut.acc_en.value = 1
        await RisingEdge(dut.clk)

    dut.acc_en.value = 0
    await RisingEdge(dut.clk)

    result_before = bits_to_fp32(int(dut.acc_out.value))
    assert result_before != 0.0, f"Accumulator should be nonzero, got {result_before}"

    # Clear
    dut.acc_clear.value = 1
    await RisingEdge(dut.clk)
    dut.acc_clear.value = 0
    await RisingEdge(dut.clk)

    result_after = bits_to_fp32(int(dut.acc_out.value))
    assert result_after == 0.0, f"Accumulator should be 0 after clear, got {result_after}"
    dut._log.info(f"PASS: clear works (was {result_before}, now {result_after})")


@cocotb.test()
async def test_fp32_acc_forwarding_mux(dut):
    """4 back-to-back acc_en pulses exercise the forwarding mux (acc_en_d2 path).

    When acc_en_d2 is asserted while a new acc_en is also high, Stage A must
    read partial_sum_r (the most recent uncommitted result) rather than acc_reg.
    A broken mux skips one addend and returns 7.0 instead of 10.0.
    """
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())

    # Reset
    dut.rst.value = 1
    dut.acc_en.value = 0
    dut.acc_clear.value = 0
    dut.addend.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)

    # Drive 4 consecutive acc_en=1 cycles with no idle gap: 1.0 + 2.0 + 3.0 + 4.0
    values = [1.0, 2.0, 3.0, 4.0]
    for val in values:
        dut.addend.value = fp32_to_bits(val)
        dut.acc_en.value = 1
        await RisingEdge(dut.clk)

    # Deassert and flush all 3 pipeline stages
    dut.acc_en.value = 0
    await RisingEdge(dut.clk)  # flush Stage A → Stage B
    await RisingEdge(dut.clk)  # flush Stage B → partial_sum_r
    await RisingEdge(dut.clk)  # flush Stage C → acc_reg / acc_out

    result = bits_to_fp32(int(dut.acc_out.value))
    assert abs(result - 10.0) / 10.0 < 0.01, (
        f"Expected 10.0, got {result} — forwarding mux may be broken"
    )
    dut._log.info(f"PASS: forwarding mux sum = {result}")
