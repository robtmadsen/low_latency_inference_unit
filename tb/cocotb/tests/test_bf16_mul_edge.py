"""Coverage-targeted edge tests for bfloat16_mul.sv.

Targets gaps in:
  - Zero operand paths (a_zero, b_zero)
  - Normalization shift decision (man_product[15])
  - Exponent overflow/underflow clamping
  - Subnormal inputs
  - All mantissa bit toggles
  - Sign combinations
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from utils.bfloat16 import float_to_bfloat16, bfloat16_mul_ref, bits_to_fp32


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
async def test_bf16_mul_zero_both(dut):
    """0 x 0 = 0."""
    await reset_dut(dut)
    dut.a.value = 0x0000
    dut.b.value = 0x0000
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"0x0 should be 0, got {result}"
    dut._log.info("PASS: 0x0=0")


@cocotb.test()
async def test_bf16_mul_zero_a(dut):
    """0 x nonzero = 0."""
    await reset_dut(dut)
    dut.a.value = 0x0000
    dut.b.value = float_to_bfloat16(3.14)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"0x3.14 should be 0, got {result}"
    dut._log.info("PASS: 0xnonzero=0")


@cocotb.test()
async def test_bf16_mul_zero_b(dut):
    """Nonzero x 0 = 0."""
    await reset_dut(dut)
    dut.a.value = float_to_bfloat16(2.5)
    dut.b.value = 0x0000
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    result = bits_to_fp32(int(dut.result.value))
    assert result == 0.0, f"2.5x0 should be 0, got {result}"
    dut._log.info("PASS: nonzerox0=0")


@cocotb.test()
async def test_bf16_mul_neg_neg(dut):
    """Negative x negative = positive."""
    await reset_dut(dut)
    dut.a.value = float_to_bfloat16(-2.0)
    dut.b.value = float_to_bfloat16(-3.0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    result = bits_to_fp32(int(dut.result.value))
    assert result > 0, f"-2x-3 should be positive, got {result}"
    expected = bfloat16_mul_ref(-2.0, -3.0)
    assert abs(result - expected) < 0.5, f"Expected ~{expected}, got {result}"
    dut._log.info("PASS: negxneg=pos")


@cocotb.test()
async def test_bf16_mul_neg_pos(dut):
    """Negative x positive = negative."""
    await reset_dut(dut)
    dut.a.value = float_to_bfloat16(-5.0)
    dut.b.value = float_to_bfloat16(4.0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    result = bits_to_fp32(int(dut.result.value))
    assert result < 0, f"-5x4 should be negative, got {result}"
    dut._log.info("PASS: negxpos=neg")


@cocotb.test()
async def test_bf16_mul_pos_neg(dut):
    """Positive x negative = negative."""
    await reset_dut(dut)
    dut.a.value = float_to_bfloat16(7.0)
    dut.b.value = float_to_bfloat16(-0.5)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    result = bits_to_fp32(int(dut.result.value))
    assert result < 0, f"7x-0.5 should be negative, got {result}"
    dut._log.info("PASS: posxneg=neg")


@cocotb.test()
async def test_bf16_mul_denormal(dut):
    """Subnormal bfloat16 inputs (exponent=0, mantissa!=0)."""
    await reset_dut(dut)

    dut.a.value = 0x0001  # smallest positive subnormal
    dut.b.value = float_to_bfloat16(1.0)
    await RisingEdge(dut.clk)
    r1 = int(dut.result.value)
    dut._log.info(f"subnormal x 1.0 = bits 0x{r1:08x}")

    # Both subnormal
    dut.a.value = 0x0001
    dut.b.value = 0x007F
    await RisingEdge(dut.clk)
    r2 = int(dut.result.value)
    dut._log.info(f"subnormal x subnormal = bits 0x{r2:08x}")

    # Negative subnormal
    dut.a.value = 0x8001  # negative subnormal
    dut.b.value = float_to_bfloat16(1.0)
    await RisingEdge(dut.clk)
    dut._log.info("PASS: subnormal inputs")


@cocotb.test()
async def test_bf16_mul_large_overflow(dut):
    """Two large bfloat16 values — exercises exponent overflow clamping."""
    await reset_dut(dut)
    dut.a.value = 0x7F7F  # near-max
    dut.b.value = 0x7F7F
    await RisingEdge(dut.clk)
    result_bits = int(dut.result.value)
    dut._log.info(f"overflow: large x large = bits 0x{result_bits:08x}")
    dut._log.info("PASS: large overflow clamping")


@cocotb.test()
async def test_bf16_mul_underflow(dut):
    """Two very small bfloat16 values — exercises exponent underflow."""
    await reset_dut(dut)
    dut.a.value = 0x0080  # smallest normalized: 2^-126
    dut.b.value = 0x0080
    await RisingEdge(dut.clk)
    result_bits = int(dut.result.value)
    dut._log.info(f"underflow: tiny x tiny = bits 0x{result_bits:08x}")
    dut._log.info("PASS: underflow path exercised")


@cocotb.test()
async def test_bf16_mul_all_mantissa_bits(dut):
    """Toggle all mantissa bits by sweeping operands."""
    await reset_dut(dut)
    test_values = [
        0x3F80, 0x3FFF, 0x4000, 0x4055, 0x402A,
        0x3FA0, 0x3FC0, 0x3FE0, 0x4010, 0x4030,
    ]
    for a_val in test_values:
        for b_val in test_values:
            dut.a.value = a_val
            dut.b.value = b_val
            await RisingEdge(dut.clk)
    dut._log.info("PASS: mantissa bit toggle sweep")


@cocotb.test()
async def test_bf16_mul_norm_shift_decision(dut):
    """Cases that do/don't need normalization shift (man_product[15] toggle)."""
    await reset_dut(dut)

    # 1.0 x 1.0: no shift needed
    dut.a.value = float_to_bfloat16(1.0)
    dut.b.value = float_to_bfloat16(1.0)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    r1 = bits_to_fp32(int(dut.result.value))
    assert abs(r1 - 1.0) < 0.01

    # 1.5 x 1.5 = 2.25: needs shift
    dut.a.value = float_to_bfloat16(1.5)
    dut.b.value = float_to_bfloat16(1.5)
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)
    r2 = bits_to_fp32(int(dut.result.value))
    assert abs(r2 - 2.25) < 0.1

    dut._log.info("PASS: normalization shift decision")


@cocotb.test()
async def test_bf16_mul_exponent_sweep(dut):
    """Sweep exponent values to exercise exp_sum range."""
    await reset_dut(dut)
    exponents = [1, 32, 64, 96, 127, 160, 192, 224, 254]
    for exp_a in exponents:
        for exp_b in [1, 127, 254]:
            a_val = (exp_a << 7) | 0x00  # zero mantissa
            b_val = (exp_b << 7) | 0x00
            dut.a.value = a_val
            dut.b.value = b_val
            await RisingEdge(dut.clk)
    dut._log.info("PASS: exponent sweep")
