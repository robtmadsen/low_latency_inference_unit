"""Tests for dot_product_engine — full engine tests with golden model."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import random
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from utils.bfloat16 import float_to_bfloat16, bits_to_fp32, fp32_to_bits
from models.golden_model import GoldenModel
from checkers.dot_product_checker import DotProductChecker
import numpy as np


async def reset_dut(dut):
    """Apply reset for a few cycles."""
    dut.rst.value = 1
    dut.start.value = 0
    dut.feature_in.value = 0
    dut.feature_valid.value = 0
    dut.weight_in.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def run_inference(dut, features, weights):
    """Drive one dot-product inference and return the result."""
    vec_len = len(features)

    # Assert start for one cycle
    dut.start.value = 1
    await RisingEdge(dut.clk)
    dut.start.value = 0

    # Feed feature/weight pairs one per cycle
    for i in range(vec_len):
        dut.feature_in.value = float_to_bfloat16(features[i])
        dut.weight_in.value = float_to_bfloat16(weights[i])
        dut.feature_valid.value = 1
        await RisingEdge(dut.clk)

    dut.feature_valid.value = 0

    # Wait for result_valid.
    # FSM latency after last feature_valid: VEC_LEN*7 (MAC) + 1 (S_DONE) = 29 cycles
    # for VEC_LEN=4. Use 60 cycles as a safe timeout.
    for _ in range(60):
        await RisingEdge(dut.clk)
        if dut.result_valid.value == 1:
            return bits_to_fp32(int(dut.result.value))

    raise AssertionError("result_valid never asserted within 60 cycles")


@cocotb.test()
async def test_dot_product_basic(dut):
    """Load weights via direct port drive, compare result to golden model."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    dp_chk = DotProductChecker(dut)
    await dp_chk.start()

    gm = GoldenModel()
    features = [1.0, 2.0, 3.0, 4.0]
    weights = [0.5, -0.5, 0.25, -0.25]

    expected = gm.inference(np.array(features), np.array(weights))
    result = await run_inference(dut, features, weights)

    dut._log.info(f"Result: {result}, Expected: {expected}")
    assert abs(result - expected) < 0.1, \
        f"Dot product mismatch: got {result}, expected {expected}"
    dut._log.info(dp_chk.report())


@cocotb.test()
async def test_dot_product_sweep(dut):
    """Randomized weight/feature pairs, batch of 100, checked against golden model."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())

    dp_chk = DotProductChecker(dut)
    await dp_chk.start()

    rng = random.Random(42)
    gm = GoldenModel()
    vec_len = 4

    for trial in range(100):
        await reset_dut(dut)

        features = [rng.uniform(-10.0, 10.0) for _ in range(vec_len)]
        weights = [rng.uniform(-10.0, 10.0) for _ in range(vec_len)]

        expected = gm.inference(np.array(features), np.array(weights))
        result = await run_inference(dut, features, weights)

        if expected == 0.0:
            assert abs(result) < 0.1, \
                f"Trial {trial}: expected ~0, got {result}"
        else:
            rel_err = abs(result - expected) / max(abs(expected), 1e-6)
            assert rel_err < 0.05, \
                f"Trial {trial}: got {result}, expected {expected} (rel_err={rel_err:.4f})"

    dut._log.info(dp_chk.report())
    dut._log.info("PASS: 100 randomized dot products match golden model")


@cocotb.test()
async def test_dot_product_back_to_back(dut):
    """Two consecutive inferences without reset, verify accumulator clears."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    dp_chk = DotProductChecker(dut)
    await dp_chk.start()

    gm = GoldenModel()

    # First inference
    f1 = [1.0, 1.0, 1.0, 1.0]
    w1 = [1.0, 1.0, 1.0, 1.0]
    expected1 = gm.inference(np.array(f1), np.array(w1))
    result1 = await run_inference(dut, f1, w1)
    dut._log.info(f"Inference 1: {result1} (expected {expected1})")
    assert abs(result1 - expected1) < 0.1

    # Second inference (different values — accumulator should have cleared)
    f2 = [2.0, 0.0, 0.0, 0.0]
    w2 = [3.0, 0.0, 0.0, 0.0]
    expected2 = gm.inference(np.array(f2), np.array(w2))
    result2 = await run_inference(dut, f2, w2)
    dut._log.info(f"Inference 2: {result2} (expected {expected2})")
    assert abs(result2 - expected2) < 0.1, \
        f"Back-to-back: accumulator did not clear. Got {result2}, expected {expected2}"

    dut._log.info(dp_chk.report())
    dut._log.info("PASS: back-to-back inferences with accumulator clear")
