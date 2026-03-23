"""Error injection tests — verify parser recovery from malformed ITCH data.

Sends intentionally invalid messages followed by valid Add Orders to verify
the parser does not hang or corrupt subsequent processing.
"""

import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from drivers.axi4_stream_driver import AXI4StreamDriver
from drivers.axi4_lite_driver import AXI4LiteDriver
from utils.itch_decoder import encode_add_order
from stimulus.weight_loader import load_weights, float_to_bfloat16
from stimulus.itch_adversarial import (
    generate_truncated_message,
    generate_malformed_type,
    generate_garbage,
)
from scoreboard.scoreboard import Scoreboard
from checkers.axi4_stream_checker import AXI4StreamChecker
from checkers.axi4_lite_checker import AXI4LiteChecker
from checkers.parser_checker import ParserChecker
from checkers.dot_product_checker import DotProductChecker


REG_CTRL   = 0x00
REG_STATUS = 0x04
REG_RESULT = 0x10


def bits_to_float32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


def int_to_bf16_ref(val: int) -> int:
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


def bfloat16_to_float(b: int) -> float:
    fp32_bits = (b & 0xFFFF) << 16
    return struct.unpack('>f', struct.pack('>I', fp32_bits))[0]


def golden_inference(features_int, weights_float):
    acc = 0.0
    for f_int, w_f in zip(features_int, weights_float):
        f_bf16 = int_to_bf16_ref(f_int)
        w_bf16 = float_to_bfloat16(w_f)
        f_val = bfloat16_to_float(f_bf16)
        w_val = bfloat16_to_float(w_bf16)
        acc += f_val * w_val
    return acc


async def reset_dut(dut, cycles=10):
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
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if status & 0x1:
            result_bits = await axil.read(REG_RESULT)
            return bits_to_float32(result_bits)
        await RisingEdge(axil.clk)
    raise TimeoutError("Inference result not ready within timeout")


async def wait_for_new_result(axil, timeout_cycles=300):
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if status & 0x2:
            break
        await RisingEdge(axil.clk)
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if (not (status & 0x2)) and (status & 0x1):
            result_bits = await axil.read(REG_RESULT)
            return bits_to_float32(result_bits)
        await RisingEdge(axil.clk)
    raise TimeoutError("New inference result not ready within timeout")


async def setup_test(dut, weights):
    """Common setup: clock, reset, drivers, checkers, weight load."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    stream_chk = AXI4StreamChecker(dut)
    axil_chk = AXI4LiteChecker(dut)
    parser_chk = ParserChecker(dut, parser_path=dut.u_parser)
    dp_chk = DotProductChecker(dut, dp_path=dut.u_dp_engine)
    await stream_chk.start()
    await axil_chk.start()
    await parser_chk.start()
    await dp_chk.start()

    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    return axis, axil


@cocotb.test()
async def test_truncated_message(dut):
    """Send a truncated message, then a valid Add Order — verify recovery."""
    weights = [1.0, 1.0, 1.0, 1.0]
    axis, axil = await setup_test(dut, weights)

    # Send truncated message (parser should discard)
    bad_msg = generate_truncated_message()
    await axis.send(bad_msg)
    await ClockCycles(dut.clk, 50)

    # Send valid Add Order — parser should recover
    price = 5000
    msg = encode_add_order(order_ref=1, side='B', price=price)
    await axis.send(msg)

    # Compute expected: first msg after reset, last_price=0
    features_int = [price, 1, 1, price]
    expected = golden_inference(features_int, weights)

    result = await wait_for_result(axil)

    sb = Scoreboard(tolerance=0.05)
    sb.add_expected(expected)
    sb.add_actual(result)
    sb.check()

    dut._log.info(sb.report())
    assert sb.passed, f"Parser failed to recover: {sb.report()}"


@cocotb.test()
async def test_malformed_type(dut):
    """Send invalid message type, then valid — verify parser discards cleanly."""
    weights = [0.5, -1.0, 0.25, 2.0]
    axis, axil = await setup_test(dut, weights)

    # Send message with bad type code
    bad_msg = generate_malformed_type()
    await axis.send(bad_msg)
    await ClockCycles(dut.clk, 50)

    # Send valid Add Order
    price = 12000
    msg = encode_add_order(order_ref=10, side='S', price=price)
    await axis.send(msg)

    features_int = [price, -1, -1, price]
    expected = golden_inference(features_int, weights)

    result = await wait_for_result(axil)

    sb = Scoreboard(tolerance=0.05)
    sb.add_expected(expected)
    sb.add_actual(result)
    sb.check()

    dut._log.info(sb.report())
    assert sb.passed, f"Parser failed to discard bad type: {sb.report()}"


@cocotb.test()
async def test_garbage_recovery(dut):
    """Send garbage bytes, then a valid message — verify recovery."""
    weights = [1.0, 1.0, 1.0, 1.0]
    axis, axil = await setup_test(dut, weights)

    # Send garbage
    garbage = generate_garbage(length=24)
    await axis.send(garbage)
    await ClockCycles(dut.clk, 50)

    # Send valid Add Order
    price = 8000
    msg = encode_add_order(order_ref=99, side='B', price=price)
    await axis.send(msg)

    features_int = [price, 1, 1, price]
    expected = golden_inference(features_int, weights)

    result = await wait_for_result(axil)

    sb = Scoreboard(tolerance=0.05)
    sb.add_expected(expected)
    sb.add_actual(result)
    sb.check()

    dut._log.info(sb.report())
    assert sb.passed, f"Parser failed to recover from garbage: {sb.report()}"
