"""Pipeline stress tests — verify data integrity under various send pacing.

Tests exercise the DUT's natural backpressure handling (tready deasserts
when the pipeline is busy) by injecting messages at different rates.
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
from stimulus.backpressure_gen import BackpressureGenerator
from scoreboard.scoreboard import Scoreboard
from checkers.axi4_stream_checker import AXI4StreamChecker
from checkers.axi4_lite_checker import AXI4LiteChecker
from checkers.parser_checker import ParserChecker
from checkers.dot_product_checker import DotProductChecker


# Register addresses
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
    """Wait for result_ready to clear (new inference in-flight), then re-assert."""
    # Phase 1: wait for result_ready to de-assert
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if not (status & 0x1):
            break
        await RisingEdge(axil.clk)
    # Phase 2: wait for fresh result_ready
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if status & 0x1:
            result_bits = await axil.read(REG_RESULT)
            return bits_to_float32(result_bits)
        await RisingEdge(axil.clk)
    raise TimeoutError("New inference result not ready within timeout")


async def run_stress(dut, bp_pattern, count, weights, seed=42, **bp_kwargs):
    """Core stress loop: send `count` messages with the given backpressure pattern."""
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

    bp = BackpressureGenerator(dut, pattern=bp_pattern, seed=seed, **bp_kwargs)
    sb = Scoreboard(tolerance=0.05)

    last_price = 0
    buy_flow = 0

    for i in range(count):
        price = 1000 + i * 100
        side = 'B' if i % 2 == 0 else 'S'
        msg = encode_add_order(order_ref=i + 1, side=side, price=price)

        price_delta = price - last_price
        side_enc = 1 if side == 'B' else -1
        buy_flow += side_enc
        features_int = [price_delta, side_enc, buy_flow, price]
        last_price = price

        expected = golden_inference(features_int, weights)
        sb.add_expected(expected)

        await axis.send(msg)
        await bp.inter_message_delay()

        if i == 0:
            result = await wait_for_result(axil)
        else:
            result = await wait_for_new_result(axil)

        sb.add_actual(result)

    sb.check()

    dut._log.info(sb.report())
    dut._log.info(stream_chk.report())
    dut._log.info(axil_chk.report())

    return sb


@cocotb.test()
async def test_periodic_stall(dut):
    """Periodic stalls between sends — verify no data loss."""
    weights = [0.5, -1.0, 0.25, 2.0]
    sb = await run_stress(dut, bp_pattern='periodic', count=20, weights=weights,
                          ready_cycles=3, stall_cycles=5)
    assert sb.passed, f"Scoreboard failed:\n{sb.report()}"


@cocotb.test()
async def test_random_backpressure(dut):
    """Random delays over 50 messages with scoreboard check."""
    weights = [1.0, 1.0, 1.0, 1.0]
    sb = await run_stress(dut, bp_pattern='random', count=50, weights=weights,
                          max_delay=15, seed=99)
    assert sb.passed, f"Scoreboard failed:\n{sb.report()}"


@cocotb.test()
async def test_pipeline_drain(dut):
    """Back-to-back messages with no inter-message delay (max throughput)."""
    weights = [2.0, -0.5, 1.0, 0.25]
    sb = await run_stress(dut, bp_pattern='none', count=30, weights=weights)
    assert sb.passed, f"Scoreboard failed:\n{sb.report()}"
