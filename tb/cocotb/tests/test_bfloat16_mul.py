"""Tests for bfloat16_mul arithmetic primitive.

bfloat16_mul now has a registered output stage (1-cycle latency).
Each test must drive a clock, apply reset, and await one rising edge
before sampling `result`.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from utils.bfloat16 import (
    float_to_bfloat16, bfloat16_mul_ref, bits_to_fp32
)


async def reset_dut(dut):
    """Start a 10 ns clock, assert reset for 2 cycles, then deassert."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.rst.value = 1
    dut.a.value = 0
    dut.b.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_bfloat16_mul_basic(dut):
    """Drive known operands, check product against Python reference."""
    await reset_dut(dut)

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
        await RisingEdge(dut.clk)  # edge N: Stage1 FF latches a,b
        await RisingEdge(dut.clk)  # edge N+1: Stage2 FF latches Stage1 result
        await RisingEdge(dut.clk)  # edge N+2: read (active phase = post-NBA of edge N+1)
        await ReadOnly()            # settle registered FFs (cocotb v2 + Verilator)
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
        await RisingEdge(dut.clk)  # exit ReadOnly before next iteration's writes


@cocotb.test()
async def test_bfloat16_mul_special_cases(dut):
    """Test zero, large values, and sign combinations."""
    await reset_dut(dut)

    # Zero × nonzero
    dut.a.value = float_to_bfloat16(0.0)
    dut.b.value = float_to_bfloat16(5.0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"0.0 * 5.0 should be 0.0, got {result}"
    await RisingEdge(dut.clk)  # exit ReadOnly before next write

    # Nonzero × zero
    dut.a.value = float_to_bfloat16(5.0)
    dut.b.value = float_to_bfloat16(0.0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"5.0 * 0.0 should be 0.0, got {result}"
    await RisingEdge(dut.clk)  # exit ReadOnly before next write

    # Zero × zero
    dut.a.value = float_to_bfloat16(0.0)
    dut.b.value = float_to_bfloat16(0.0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"0.0 * 0.0 should be 0.0, got {result}"
    await RisingEdge(dut.clk)  # exit ReadOnly before next write

    # Large values
    dut.a.value = float_to_bfloat16(256.0)
    dut.b.value = float_to_bfloat16(256.0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    result = bits_to_fp32(int(dut.result.value))
    expected = bfloat16_mul_ref(256.0, 256.0)
    assert abs(result - expected) < 1.0, f"256*256: expected {expected}, got {result}"
    await RisingEdge(dut.clk)  # exit ReadOnly before next write

    # Negative × positive
    dut.a.value = float_to_bfloat16(-4.0)
    dut.b.value = float_to_bfloat16(2.0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    result = bits_to_fp32(int(dut.result.value))
    assert result < 0, f"-4.0 * 2.0 should be negative, got {result}"

    dut._log.info("PASS: all special cases")
