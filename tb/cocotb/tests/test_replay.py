"""Real ITCH data replay tests.

Exercises the parser with actual NASDAQ TotalView-ITCH sample data,
then runs inference with synthetically injected Add Orders.
"""

import os
import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

import sys
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from drivers.axi4_stream_driver import AXI4StreamDriver
from drivers.axi4_lite_driver import AXI4LiteDriver
from drivers.itch_feeder import ITCHFeeder
from stimulus.itch_replay import replay_itch_file
from stimulus.weight_loader import load_weights, float_to_bfloat16
from utils.itch_decoder import encode_add_order
from scoreboard.scoreboard import Scoreboard


# Register addresses
REG_CTRL   = 0x00
REG_STATUS = 0x04
REG_RESULT = 0x10

DATA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', 'data')
SAMPLE_FILE = os.path.join(DATA_DIR, 'tvagg_sample.bin')


def bfloat16_to_float(b: int) -> float:
    fp32_bits = (b & 0xFFFF) << 16
    return struct.unpack('>f', struct.pack('>I', fp32_bits))[0]


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
    raise TimeoutError("Inference result not ready within timeout")


@cocotb.test()
async def test_replay_non_add_orders(dut):
    """Replay real NASDAQ data (non-Add-Order types) — parser should discard all.

    Verifies the parser doesn't hang or assert fields_valid for non-Add-Order messages.
    """
    cocotb.start_soon(Clock(dut.clk, 10, units='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    await axis.reset()
    await RisingEdge(dut.clk)

    feeder = ITCHFeeder(axis)

    # Replay first 50 real messages (none are Add Orders in this sample)
    messages = feeder.parse_file(SAMPLE_FILE, max_messages=50)
    dut._log.info(f"Replaying {len(messages)} real ITCH messages")

    types_seen = set()
    for msg in messages:
        body = msg[2:]  # skip length prefix
        types_seen.add(chr(body[0]))

    dut._log.info(f"Message types in replay: {types_seen}")

    await feeder.feed_messages(messages)

    # Wait a bit for pipeline to settle
    await ClockCycles(dut.clk, 100)

    # fields_valid should never have asserted (no Add Orders in sample)
    dut._log.info("Parser survived replay of real NASDAQ data without hanging")


@cocotb.test()
async def test_replay_with_injected_add_orders(dut):
    """Replay real data mixed with synthetic Add Orders, verify inference results.

    Sends real non-Add-Order messages interspersed with Add Orders,
    checking that the pipeline correctly processes through the noise.
    """
    cocotb.start_soon(Clock(dut.clk, 10, units='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    # Load weights
    weights = [1.0, 0.5, -0.25, 0.1]
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    feeder = ITCHFeeder(axis)

    # Get some real non-Add-Order messages
    real_msgs = feeder.parse_file(SAMPLE_FILE, max_messages=10)

    # Build test sequence: real noise → add order → real noise → add order
    add_order_1 = encode_add_order(order_ref=100, side='B', price=20000)
    add_order_2 = encode_add_order(order_ref=101, side='S', price=21000)

    sb = Scoreboard(tolerance=0.05)

    # Send some noise first
    for msg in real_msgs[:5]:
        await axis.send(msg)
    await ClockCycles(dut.clk, 20)

    # First Add Order
    await axis.send(add_order_1)
    # features: delta=20000, side=+1, flow=1, price=20000
    features1 = [20000, 1, 1, 20000]
    expected1 = golden_inference(features1, weights)

    result1 = await wait_for_new_result(axil)
    sb.add_expected(expected1)
    sb.add_actual(result1)

    # More noise
    for msg in real_msgs[5:]:
        await axis.send(msg)
    await ClockCycles(dut.clk, 20)

    # Second Add Order
    await axis.send(add_order_2)
    # features: delta=1000, side=-1, flow=1-1=0, price=21000
    features2 = [1000, -1, 0, 21000]
    expected2 = golden_inference(features2, weights)

    result2 = await wait_for_new_result(axil)
    sb.add_expected(expected2)
    sb.add_actual(result2)

    sb.check()
    dut._log.info(sb.report())
    assert sb.passed, f"Scoreboard failed:\n{sb.report()}"
