"""Tests for bfloat16_mul and fp32_acc arithmetic primitives."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import struct
import sys
import os

# Add parent dir to path for utils imports
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from utils.bfloat16 import (
    float_to_bfloat16, bfloat16_to_float, bfloat16_mul_ref,
    fp32_to_bits, bits_to_fp32
)


# ─── bfloat16_mul tests ───

@cocotb.test()
async def test_bfloat16_mul_basic(dut):
    """Drive known operands, check product against Python reference."""
    test_cases = [
        (1.0, 1.0),
        (2.0, 3.0),
        (1.5, 2.5),
        (-1.0, 1.0),
        (-2.0, -3.0),
        (0.5, 0.25),
        (100.0, 0.01),
    ]

    for a_float, b_float in test_cases:
        a_bf16 = float_to_bfloat16(a_float)
        b_bf16 = float_to_bfloat16(b_float)

        dut.a.value = a_bf16
        dut.b.value = b_bf16
        await Timer(1, units='ns')  # combinational settle

        result_bits = dut.result.value.integer
        result_float = bits_to_fp32(result_bits)
        expected = bfloat16_mul_ref(a_float, b_float)

        # Allow small relative error due to mantissa truncation in RTL
        if expected == 0.0:
            assert result_float == 0.0, \
                f"Expected 0.0, got {result_float} for {a_float} * {b_float}"
        else:
            rel_err = abs(result_float - expected) / abs(expected)
            assert rel_err < 0.02, \
                f"{a_float} * {b_float}: expected {expected}, got {result_float} (rel_err={rel_err:.4f})"

        dut._log.info(f"PASS: bf16({a_float}) * bf16({b_float}) = {result_float} (expected {expected})")


@cocotb.test()
async def test_bfloat16_mul_special_cases(dut):
    """Test zero, large values, and sign combinations."""
    # Zero × nonzero
    dut.a.value = float_to_bfloat16(0.0)
    dut.b.value = float_to_bfloat16(5.0)
    await Timer(1, units='ns')
    result = bits_to_fp32(dut.result.value.integer)
    assert result == 0.0, f"0.0 * 5.0 should be 0.0, got {result}"

    # Nonzero × zero
    dut.a.value = float_to_bfloat16(5.0)
    dut.b.value = float_to_bfloat16(0.0)
    await Timer(1, units='ns')
    result = bits_to_fp32(dut.result.value.integer)
    assert result == 0.0, f"5.0 * 0.0 should be 0.0, got {result}"

    # Zero × zero
    dut.a.value = float_to_bfloat16(0.0)
    dut.b.value = float_to_bfloat16(0.0)
    await Timer(1, units='ns')
    result = bits_to_fp32(dut.result.value.integer)
    assert result == 0.0, f"0.0 * 0.0 should be 0.0, got {result}"

    # Large values
    dut.a.value = float_to_bfloat16(256.0)
    dut.b.value = float_to_bfloat16(256.0)
    await Timer(1, units='ns')
    result = bits_to_fp32(dut.result.value.integer)
    expected = bfloat16_mul_ref(256.0, 256.0)
    assert abs(result - expected) < 1.0, f"256*256: expected {expected}, got {result}"

    # Negative × positive
    dut.a.value = float_to_bfloat16(-4.0)
    dut.b.value = float_to_bfloat16(2.0)
    await Timer(1, units='ns')
    result = bits_to_fp32(dut.result.value.integer)
    assert result < 0, f"-4.0 * 2.0 should be negative, got {result}"

    dut._log.info("PASS: all special cases")


# ─── fp32_acc tests ───

@cocotb.test()
async def test_fp32_acc_accumulate(dut):
    """Accumulate N addends and check running sum."""
    clock = Clock(dut.clk, 10, units='ns')
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
    running_sum = 0.0

    for val in values:
        dut.addend.value = fp32_to_bits(val)
        dut.acc_en.value = 1
        await RisingEdge(dut.clk)
        running_sum += val

    dut.acc_en.value = 0
    await RisingEdge(dut.clk)  # let final accumulate land

    result = bits_to_fp32(dut.acc_out.value.integer)
    assert abs(result - 10.0) < 0.01, f"Expected 10.0, got {result}"
    dut._log.info(f"PASS: accumulate sum = {result}")


@cocotb.test()
async def test_fp32_acc_clear(dut):
    """Verify accumulator resets on clear signal."""
    clock = Clock(dut.clk, 10, units='ns')
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

    result_before = bits_to_fp32(dut.acc_out.value.integer)
    assert result_before != 0.0, f"Accumulator should be nonzero, got {result_before}"

    # Clear
    dut.acc_clear.value = 1
    await RisingEdge(dut.clk)
    dut.acc_clear.value = 0
    await RisingEdge(dut.clk)

    result_after = bits_to_fp32(dut.acc_out.value.integer)
    assert result_after == 0.0, f"Accumulator should be 0 after clear, got {result_after}"
    dut._log.info(f"PASS: clear works (was {result_before}, now {result_after})")
