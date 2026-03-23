"""Tests for bfloat16_mul arithmetic primitive."""

import cocotb
from cocotb.triggers import Timer
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from utils.bfloat16 import (
    float_to_bfloat16, bfloat16_mul_ref, bits_to_fp32
)


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
        await Timer(1, unit='ns')

        result_bits = int(dut.result.value)
        result_float = bits_to_fp32(result_bits)
        expected = bfloat16_mul_ref(a_float, b_float)

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
    await Timer(1, unit='ns')
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"0.0 * 5.0 should be 0.0, got {result}"

    # Nonzero × zero
    dut.a.value = float_to_bfloat16(5.0)
    dut.b.value = float_to_bfloat16(0.0)
    await Timer(1, unit='ns')
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"5.0 * 0.0 should be 0.0, got {result}"

    # Zero × zero
    dut.a.value = float_to_bfloat16(0.0)
    dut.b.value = float_to_bfloat16(0.0)
    await Timer(1, unit='ns')
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"0.0 * 0.0 should be 0.0, got {result}"

    # Large values
    dut.a.value = float_to_bfloat16(256.0)
    dut.b.value = float_to_bfloat16(256.0)
    await Timer(1, unit='ns')
    result = bits_to_fp32(int(dut.result.value))
    expected = bfloat16_mul_ref(256.0, 256.0)
    assert abs(result - expected) < 1.0, f"256*256: expected {expected}, got {result}"

    # Negative × positive
    dut.a.value = float_to_bfloat16(-4.0)
    dut.b.value = float_to_bfloat16(2.0)
    await Timer(1, unit='ns')
    result = bits_to_fp32(int(dut.result.value))
    assert result < 0, f"-4.0 * 2.0 should be negative, got {result}"

    dut._log.info("PASS: all special cases")
