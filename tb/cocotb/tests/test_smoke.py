"""End-to-end smoke test — ITCH message in → inference result out via lliu_top.

Exercises the full pipeline: AXI4-Stream ingress → parser → field extract →
feature extractor → dot-product engine → output buffer → AXI4-Lite readout.
"""

import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from drivers.axi4_stream_driver import AXI4StreamDriver
from drivers.axi4_lite_driver import AXI4LiteDriver
from utils.itch_decoder import encode_add_order
from stimulus.weight_loader import load_weights, float_to_bfloat16
from scoreboard.scoreboard import Scoreboard
from checkers.axi4_stream_checker import AXI4StreamChecker
from checkers.axi4_lite_checker import AXI4LiteChecker
from checkers.parser_checker import ParserChecker
from checkers.dot_product_checker import DotProductChecker


# ---- Register addresses ----
REG_CTRL   = 0x00
REG_STATUS = 0x04
REG_RESULT = 0x10


def bfloat16_to_float(b: int) -> float:
    fp32_bits = (b & 0xFFFF) << 16
    return struct.unpack('>f', struct.pack('>I', fp32_bits))[0]


def bits_to_float32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def int_to_bf16_ref(val: int) -> int:
    """Reference int-to-bfloat16 matching RTL."""
    if val == 0:
        return 0x0000
    sign = 1 if val < 0 else 0
    mag = abs(val)
    bit_pos = mag.bit_length() - 1
    exp_val = 127 + bit_pos
    if bit_pos >= 7:
        man_val = (mag >> (bit_pos - 7)) & 0x7F
    else:
        man_val = (mag << (7 - bit_pos)) & 0x7F
    return (sign << 15) | (exp_val << 7) | man_val


def golden_inference(features_int, weights_float):
    """Compute expected inference result matching RTL semantics.

    features_int: list of ints to be converted to bfloat16
    weights_float: list of floats to be converted to bfloat16
    """
    acc = 0.0
    for f_int, w_f in zip(features_int, weights_float):
        f_bf16 = int_to_bf16_ref(f_int)
        w_bf16 = float_to_bfloat16(w_f)
        f_val = bfloat16_to_float(f_bf16)
        w_val = bfloat16_to_float(w_bf16)
        acc += f_val * w_val
    return acc


async def reset_dut(dut, cycles=10):
    """Assert reset for N cycles."""
    dut.rst.value = 1
    dut.s_axis_tdata.value = 0
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    dut.s_axil_awaddr.value = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wdata.value = 0
    dut.s_axil_wstrb.value = 0
    dut.s_axil_wvalid.value = 0
    dut.s_axil_bready.value = 0
    dut.s_axil_araddr.value = 0
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def wait_for_result(axil, timeout_cycles=200):
    """Poll STATUS register until result_ready, then read RESULT."""
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if status & 0x1:  # result_ready bit
            result_bits = await axil.read(REG_RESULT)
            return bits_to_float32(result_bits)
        await RisingEdge(axil.clk)
    raise TimeoutError("Inference result not ready within timeout")


async def wait_for_new_result(axil, timeout_cycles=300):
    """Wait for pipeline to go busy then come back to result_ready."""
    # First wait for busy to assert (sequencer active)
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if status & 0x2:  # busy bit
            break
        await RisingEdge(axil.clk)
    # Then wait for busy to deassert and result to be ready
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if (not (status & 0x2)) and (status & 0x1):
            result_bits = await axil.read(REG_RESULT)
            return bits_to_float32(result_bits)
        await RisingEdge(axil.clk)
    raise TimeoutError("New inference result not ready within timeout")


@cocotb.test()
async def test_single_inference(dut):
    """Full pipeline: load weights → send Add Order → read result."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    # Start protocol checkers
    stream_chk = AXI4StreamChecker(dut)
    axil_chk = AXI4LiteChecker(dut)
    parser_chk = ParserChecker(dut, parser_path=dut.u_parser)
    dp_chk = DotProductChecker(dut, dp_path=dut.u_dp_engine)
    await stream_chk.start()
    await axil_chk.start()
    await parser_chk.start()
    await dp_chk.start()

    # --- Load weights ---
    weights = [0.5, -1.0, 0.25, 2.0]
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    # --- Send one Add Order ---
    price = 15000
    side = 'B'
    order_ref = 42
    msg = encode_add_order(order_ref=order_ref, side=side, price=price)
    await axis.send(msg)

    # --- Wait for inference result ---
    result = await wait_for_result(axil)

    # --- Golden model ---
    # First order: last_price=0, so price_delta=15000
    # side=buy → +1, flow=0+1=1, norm_price=15000
    features_int = [15000, 1, 1, 15000]
    expected = golden_inference(features_int, weights)

    sb = Scoreboard(tolerance=0.05)
    sb.add_expected(expected)
    sb.add_actual(result)
    sb.check()

    dut._log.info(sb.report())
    dut._log.info(stream_chk.report())
    dut._log.info(axil_chk.report())
    dut._log.info(parser_chk.report())
    dut._log.info(dp_chk.report())
    assert sb.passed, f"Scoreboard failed: expected={expected}, got={result}"


@cocotb.test()
async def test_two_sequential_inferences(dut):
    """Two Add Orders back-to-back, verify both results."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    # Start protocol checkers
    stream_chk = AXI4StreamChecker(dut)
    axil_chk = AXI4LiteChecker(dut)
    parser_chk = ParserChecker(dut, parser_path=dut.u_parser)
    dp_chk = DotProductChecker(dut, dp_path=dut.u_dp_engine)
    await stream_chk.start()
    await axil_chk.start()
    await parser_chk.start()
    await dp_chk.start()

    weights = [1.0, 1.0, 1.0, 1.0]
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    # --- First order ---
    msg1 = encode_add_order(order_ref=1, side='B', price=10000)
    await axis.send(msg1)
    result1 = await wait_for_result(axil)

    # First: delta=10000, side=+1, flow=1, price=10000 → sum ≈ 20002
    features1 = [10000, 1, 1, 10000]
    expected1 = golden_inference(features1, weights)

    # --- Second order (after first completes) ---
    await ClockCycles(dut.clk, 10)

    msg2 = encode_add_order(order_ref=2, side='S', price=11000)
    await axis.send(msg2)

    # Use wait_for_new_result since output_buffer still has first result
    result2 = await wait_for_new_result(axil)

    # Second: delta=1000, side=-1, flow=1-1=0, price=11000 → sum = 1000 - 1 + 0 + 11000
    features2 = [1000, -1, 0, 11000]
    expected2 = golden_inference(features2, weights)

    sb = Scoreboard(tolerance=0.05)
    sb.add_expected(expected1)
    sb.add_actual(result1)
    sb.add_expected(expected2)
    sb.add_actual(result2)
    sb.check()

    dut._log.info(sb.report())
    dut._log.info(stream_chk.report())
    dut._log.info(axil_chk.report())
    dut._log.info(parser_chk.report())
    dut._log.info(dp_chk.report())
    assert sb.passed, f"Scoreboard failed:\n{sb.report()}"
