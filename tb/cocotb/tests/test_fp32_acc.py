"""Tests for fp32_acc accumulator."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from utils.bfloat16 import fp32_to_bits, bits_to_fp32


@cocotb.test()
async def test_fp32_acc_accumulate(dut):
    """Accumulate N addends sequentially and check running sum.

    The 5-stage pipeline (A0, A1, B1, B2, C) requires one acc_en pulse
    followed by 5 flush cycles per addend so that Stage C commits the
    partial result to acc_reg before the next addend reads acc_fb.
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

    PIPELINE_STAGES = 5  # A0, A1, B1, B2, C

    # Accumulate sequentially: 1.0 + 2.0 + 3.0 + 4.0 = 10.0
    values = [1.0, 2.0, 3.0, 4.0]
    for val in values:
        dut.addend.value = fp32_to_bits(val)
        dut.acc_en.value = 1
        await RisingEdge(dut.clk)          # Stage A0 latches addend + acc_fb
        dut.acc_en.value = 0
        for _ in range(PIPELINE_STAGES):   # flush: A1, B1, B2, C
            await RisingEdge(dut.clk)

    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
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

    PIPELINE_STAGES = 5  # A0, A1, B1, B2, C

    # Accumulate sequentially: 5.0 + 10.0 = 15.0
    for val in [5.0, 10.0]:
        dut.addend.value = fp32_to_bits(val)
        dut.acc_en.value = 1
        await RisingEdge(dut.clk)
        dut.acc_en.value = 0
        for _ in range(PIPELINE_STAGES):
            await RisingEdge(dut.clk)

    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    result_before = bits_to_fp32(int(dut.acc_out.value))
    assert result_before != 0.0, f"Accumulator should be nonzero, got {result_before}"
    await RisingEdge(dut.clk)  # exit ReadOnly before next write

    # Clear
    dut.acc_clear.value = 1
    await RisingEdge(dut.clk)
    dut.acc_clear.value = 0
    await RisingEdge(dut.clk)

    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    result_after = bits_to_fp32(int(dut.acc_out.value))
    assert result_after == 0.0, f"Accumulator should be 0 after clear, got {result_after}"
    dut._log.info(f"PASS: clear works (was {result_before}, now {result_after})")


@cocotb.test()
async def test_fp32_acc_forwarding_mux(dut):
    """Verify acc_reg feedback is stable across many sequential acc_en pulses.

    The 5-stage pipeline (A0, A1, B1, B2, C) provides acc_reg as feedback
    (acc_fb) to Stage A0.  After each flush the committed value must be
    available to the next addend.  Eight addends test that the feedback path
    does not drift or corrupt intermediate results:
      1+2+3+4+5+6+7+8 = 36.
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

    PIPELINE_STAGES = 5  # A0, A1, B1, B2, C

    values = [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0]
    expected = sum(values)  # 36.0

    for val in values:
        dut.addend.value = fp32_to_bits(val)
        dut.acc_en.value = 1
        await RisingEdge(dut.clk)
        dut.acc_en.value = 0
        for _ in range(PIPELINE_STAGES):
            await RisingEdge(dut.clk)

    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    result = bits_to_fp32(int(dut.acc_out.value))
    assert abs(result - expected) / expected < 0.01, (
        f"Expected {expected}, got {result} — acc_reg feedback may be broken"
    )
    dut._log.info(f"PASS: sequential feedback sum = {result}")
