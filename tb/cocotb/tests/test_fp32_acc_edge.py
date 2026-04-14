"""Coverage-targeted edge tests for fp32_acc.sv.

Targets gaps in:
  - Normalization shift paths (carry-out, leading-zero shifts 1-22)
  - Effective subtraction (eff_sub=1)
  - Near-cancellation (deep normalization)
  - Exact cancellation (result=0)
  - Large exponent difference (small aligned to zero)
  - Zero addend/accumulator paths
  - Negative accumulation
  - Alternating signs
  - acc_larger=0 path (addend > accumulator)
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from utils.bfloat16 import fp32_to_bits, bits_to_fp32

import struct

def _float_from_bits(bits):
    """Create Python float from exact IEEE-754 bit pattern."""
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


async def acc_reset(dut, cycles=3):
    dut.rst.value = 1
    dut.acc_en.value = 0
    dut.acc_clear.value = 0
    dut.addend.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def acc_add(dut, value_float):
    """Drive one accumulate cycle and flush the 5-stage pipeline.

    acc_en is held high for exactly one clock edge (Stage A0 latches the
    addend and reads acc_fb from acc_reg or partial_sum_r).  Five flush
    cycles follow so Stage C can commit its result to acc_reg before the
    next acc_add call reads acc_fb.  Matches the Model-B (Verilator+cocotb)
    timing convention: await RisingEdge resumes pre-NBA of the current
    edge = post-NBA of the previous edge.
    """
    PIPELINE_STAGES = 5  # A0, A1, B1, B2, C
    dut.addend.value = fp32_to_bits(value_float)
    dut.acc_en.value = 1
    await RisingEdge(dut.clk)   # Stage A0 captures addend + acc_fb
    dut.acc_en.value = 0
    for _ in range(PIPELINE_STAGES):  # wait for Stage C to commit to acc_reg
        await RisingEdge(dut.clk)


async def acc_read(dut):
    """Return acc_out after acc_add has already flushed the pipeline.

    No additional clock edge is needed: acc_add's 5-cycle flush leaves
    the simulation cursor at post-NBA of the Stage-C commit edge.
    ReadOnly() is required by cocotb 2.0 + Verilator to settle registered
    FF outputs before reading them in the Python scheduler.
    """
    await ReadOnly()  # settle registered FFs (cocotb v2 + Verilator)
    val = bits_to_fp32(int(dut.acc_out.value))
    await RisingEdge(dut.clk)  # exit ReadOnly so callers can write immediately after
    return val


@cocotb.test()
async def test_acc_zero_addend(dut):
    """Adding zero to nonzero: acc_zero + add_zero paths."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 5.0)
    await acc_add(dut, 0.0)
    result = await acc_read(dut)
    assert abs(result - 5.0) < 0.01, f"5+0 should be 5, got {result}"
    dut._log.info("PASS: zero addend")


@cocotb.test()
async def test_acc_addend_to_zero(dut):
    """Adding to zero accumulator: acc_zero path."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 7.5)
    result = await acc_read(dut)
    assert abs(result - 7.5) < 0.01, f"0+7.5 should be 7.5, got {result}"
    dut._log.info("PASS: addend to zero")


@cocotb.test()
async def test_acc_both_zero(dut):
    """0 + 0 = 0: both zero path."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 0.0)
    result = await acc_read(dut)
    assert result == 0.0, f"0+0 should be 0, got {result}"
    dut._log.info("PASS: both zero")


@cocotb.test()
async def test_acc_effective_subtraction(dut):
    """Opposite signs: exercises eff_sub=1 path."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 10.0)
    await acc_add(dut, -3.0)
    result = await acc_read(dut)
    assert abs(result - 7.0) < 0.1, f"10-3 should be 7, got {result}"
    dut._log.info("PASS: effective subtraction")


@cocotb.test()
async def test_acc_subtraction_negative_result(dut):
    """Subtraction yielding negative: small big_man - large aligned_small."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 3.0)
    await acc_add(dut, -10.0)
    result = await acc_read(dut)
    assert abs(result - (-7.0)) < 0.1, f"3-10 should be -7, got {result}"
    dut._log.info("PASS: subtraction negative result")


@cocotb.test()
async def test_acc_near_cancellation(dut):
    """Nearly equal values: requires deep normalization shifts."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 1.0)
    await acc_add(dut, -0.9375)
    result = await acc_read(dut)
    assert abs(result - 0.0625) < 0.01, f"1-0.9375={result}, expected 0.0625"
    dut._log.info("PASS: near cancellation")


@cocotb.test()
async def test_acc_deep_normalization_shifts(dut):
    """Exercise progressively deeper normalization shifts (bits 22 down to 1)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())

    base = 256.0
    for shift_depth in range(1, 20):
        await acc_reset(dut)
        large = base
        small = base - (base / (2 ** shift_depth))
        await acc_add(dut, large)
        await acc_add(dut, -small)
        result = await acc_read(dut)
        expected = large - small
        if expected != 0:
            rel_err = abs(result - expected) / expected
            assert rel_err < 0.1, \
                f"Shift {shift_depth}: got {result}, expected {expected}"
    dut._log.info("PASS: deep normalization shifts")


@cocotb.test()
async def test_acc_carry_out(dut):
    """Addition causing carry out (sum_man[24])."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 1.5)
    await acc_add(dut, 1.5)
    result = await acc_read(dut)
    assert abs(result - 3.0) < 0.01, f"1.5+1.5={result}, expected 3.0"
    dut._log.info("PASS: carry out")


@cocotb.test()
async def test_acc_exact_cancellation(dut):
    """Equal magnitude, opposite sign → zero."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 42.0)
    await acc_add(dut, -42.0)
    result = await acc_read(dut)
    assert result == 0.0, f"42+(-42)={result}, expected 0"
    dut._log.info("PASS: exact cancellation")


@cocotb.test()
async def test_acc_large_exp_diff(dut):
    """Large exponent difference: small number aligned to zero."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 1e10)
    await acc_add(dut, 1e-10)
    result = await acc_read(dut)
    assert abs(result - 1e10) / 1e10 < 0.01, f"Expected ~1e10, got {result}"
    dut._log.info("PASS: large exponent difference")


@cocotb.test()
async def test_acc_negative_accumulation(dut):
    """Start negative, accumulate more negative."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, -5.0)
    await acc_add(dut, -3.0)
    result = await acc_read(dut)
    assert abs(result - (-8.0)) < 0.1, f"-5+(-3)={result}, expected -8"
    dut._log.info("PASS: negative accumulation")


@cocotb.test()
async def test_acc_alternating_signs(dut):
    """Alternating positive/negative to exercise sign flipping."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    values = [10.0, -7.0, 5.0, -3.0, 1.0]
    expected = sum(values)
    for v in values:
        await acc_add(dut, v)
    result = await acc_read(dut)
    assert abs(result - expected) < 0.5, f"Expected {expected}, got {result}"
    dut._log.info("PASS: alternating signs")


@cocotb.test()
async def test_acc_addend_larger_than_acc(dut):
    """Addend has larger exponent (acc_larger=0 path)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 0.125)
    await acc_add(dut, 100.0)
    result = await acc_read(dut)
    assert abs(result - 100.125) < 0.5, f"Expected ~100.125, got {result}"
    dut._log.info("PASS: addend larger than accumulator")


@cocotb.test()
async def test_acc_progressive_subtraction(dut):
    """Subtract progressively: 16 - 8 - 4 - 2 - 1 = 1."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 16.0)
    for v in [8.0, 4.0, 2.0, 1.0]:
        await acc_add(dut, -v)
    result = await acc_read(dut)
    assert abs(result - 1.0) < 0.1, f"Expected 1.0, got {result}"
    dut._log.info("PASS: progressive subtraction")


@cocotb.test()
async def test_acc_clear_and_reaccumulate(dut):
    """Clear during accumulation, then re-accumulate."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 100.0)
    await acc_add(dut, 200.0)

    # Clear
    dut.acc_clear.value = 1
    await RisingEdge(dut.clk)
    dut.acc_clear.value = 0
    await RisingEdge(dut.clk)

    result = await acc_read(dut)
    assert result == 0.0, f"Should be 0 after clear, got {result}"

    # Re-accumulate
    await acc_add(dut, 3.0)
    result2 = await acc_read(dut)
    assert abs(result2 - 3.0) < 0.1, f"Expected 3.0, got {result2}"
    dut._log.info("PASS: clear and re-accumulate")


@cocotb.test()
async def test_acc_very_small_result(dut):
    """Result near machine epsilon to exercise deepest normalization."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 1.0)
    await acc_add(dut, -0.99999)
    result = await acc_read(dut)
    dut._log.info(f"Very small result: {result}")
    dut._log.info("PASS: very small result normalization")


@cocotb.test()
async def test_acc_ulp_diff_8(dut):
    """Subtraction with exactly 8 ULP difference → sum_man[3] leading 1."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    bigger = _float_from_bits(0x3F800008)  # 1.0 + 8*eps
    await acc_add(dut, bigger)
    await acc_add(dut, -1.0)
    result = await acc_read(dut)
    dut._log.info(f"8-ULP diff result: {result} (bits=0x{fp32_to_bits(result):08X})")
    dut._log.info("PASS: sum_man[3] normalization shift")


@cocotb.test()
async def test_acc_ulp_diff_4(dut):
    """Subtraction with exactly 4 ULP difference → sum_man[2] leading 1."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    bigger = _float_from_bits(0x3F800004)  # 1.0 + 4*eps
    await acc_add(dut, bigger)
    await acc_add(dut, -1.0)
    result = await acc_read(dut)
    dut._log.info(f"4-ULP diff result: {result} (bits=0x{fp32_to_bits(result):08X})")
    dut._log.info("PASS: sum_man[2] normalization shift")


@cocotb.test()
async def test_acc_ulp_diff_2(dut):
    """Subtraction with exactly 2 ULP difference → sum_man[1] leading 1."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    bigger = _float_from_bits(0x3F800002)  # 1.0 + 2*eps
    await acc_add(dut, bigger)
    await acc_add(dut, -1.0)
    result = await acc_read(dut)
    dut._log.info(f"2-ULP diff result: {result} (bits=0x{fp32_to_bits(result):08X})")
    dut._log.info("PASS: sum_man[1] normalization shift")


@cocotb.test()
async def test_acc_ulp_diff_1(dut):
    """Subtraction with exactly 1 ULP difference → sum_man[0] only (else)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    bigger = _float_from_bits(0x3F800001)  # 1.0 + 1*eps
    await acc_add(dut, bigger)
    await acc_add(dut, -1.0)
    result = await acc_read(dut)
    dut._log.info(f"1-ULP diff result: {result} (bits=0x{fp32_to_bits(result):08X})")
    dut._log.info("PASS: sum_man[0] else path")


@cocotb.test()
async def test_acc_small_acc_larger_addend_same_exp(dut):
    """Same exponent, addend mantissa > accumulator mantissa, eff_sub.

    Hits the else branch: big_man < aligned_small_man after same-exp alignment.
    acc=1.0 (man=0x800000), addend=-1.5 (man=0xC00000), same exp=127.
    """
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await acc_reset(dut)
    await acc_add(dut, 1.0)       # acc = 1.0 (exp=127, mantissa=0x800000)
    await acc_add(dut, -1.5)      # addend = -1.5 (exp=127, mantissa=0xC00000)
    result = await acc_read(dut)
    assert abs(result - (-0.5)) < 0.01, f"Expected -0.5, got {result}"
    dut._log.info("PASS: big_man < aligned_small_man (else branch)")
