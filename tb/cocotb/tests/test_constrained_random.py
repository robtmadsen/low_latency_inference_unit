"""Constrained-random stimulus with scoreboard and functional coverage.

Runs random Add Orders through the full pipeline (lliu_top), checks each
inference result against the golden model, and tracks coverage bins for
price_range x side cross-coverage closure.
"""

import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

import sys
import os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from drivers.axi4_stream_driver import AXI4StreamDriver
from drivers.axi4_lite_driver import AXI4LiteDriver
from utils.itch_decoder import decode_add_order
from stimulus.weight_loader import load_weights, float_to_bfloat16
from stimulus.itch_random import ConstrainedRandomITCH
from scoreboard.scoreboard import Scoreboard
from coverage.functional_coverage import FunctionalCoverage
from coverage.coverage_report import format_coverage, save_coverage_json
from checkers.axi4_stream_checker import AXI4StreamChecker
from checkers.axi4_lite_checker import AXI4LiteChecker
from checkers.parser_checker import ParserChecker
from checkers.dot_product_checker import DotProductChecker


# ---- Register addresses ----
REG_STATUS = 0x04
REG_RESULT = 0x10


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


# Pipeline drain cycles: updated for new RTL (+fp32_acc stage A0.5, +DPE 2-stage mac_pipe)
PIPELINE_LATENCY = 35


async def wait_for_new_result(axil, timeout_cycles=500):
    """Consume stale result, drain pipeline, then read fresh inference result.

    Flushes any previous result from the output buffer so the DUT can accept
    the new result_valid.  Then waits PIPELINE_LATENCY cycles — enough for the
    longest inference path to complete — before polling result_ready.
    """
    # Step 1: consume stale result to free the output buffer
    status = await axil.read(REG_STATUS)
    if status & 0x1:
        _ = await axil.read(REG_RESULT)  # discard; clears output buffer

    # Step 2: wait for the inference pipeline to produce the next result
    await ClockCycles(axil.clk, PIPELINE_LATENCY)

    # Step 3: poll for fresh result_ready
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if status & 0x1:
            result_bits = await axil.read(REG_RESULT)
            return bits_to_float32(result_bits)
        await RisingEdge(axil.clk)
    raise TimeoutError("Inference result not ready within timeout")


async def wait_for_result(axil, timeout_cycles=500):
    """Poll until result_ready, then read."""
    for _ in range(timeout_cycles):
        status = await axil.read(REG_STATUS)
        if status & 0x1:
            result_bits = await axil.read(REG_RESULT)
            return bits_to_float32(result_bits)
        await RisingEdge(axil.clk)
    raise TimeoutError("Inference result not ready within timeout")


async def run_random_orders(dut, count, seed, weights):
    """Core loop: send random orders, collect results, check and track coverage."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    # Start checkers
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

    gen = ConstrainedRandomITCH(seed=seed)
    sb = Scoreboard(tolerance=0.05)
    cov = FunctionalCoverage()

    # Track RTL feature extractor state for golden model
    last_price = 0
    buy_flow = 0

    for i in range(count):
        msg = gen.generate_add_order()
        parsed = decode_add_order(msg)
        price = parsed['price']
        side = parsed['side']

        # Sample coverage
        cov.sample(msg_type=0x41, price=price, side=side)

        # Compute expected features matching RTL
        price_delta = price - last_price
        side_enc = 1 if side == 'B' else -1
        buy_flow += (1 if side == 'B' else -1)
        features_int = [price_delta, side_enc, buy_flow, price]
        last_price = price

        expected = golden_inference(features_int, weights)
        sb.add_expected(expected)

        await axis.send(msg)

        if i == 0:
            result = await wait_for_result(axil)
        else:
            result = await wait_for_new_result(axil)

        sb.add_actual(result)
        await ClockCycles(dut.clk, 5)

    sb.check()

    # Reports
    cov_data = cov.report()
    dut._log.info(format_coverage(cov_data))
    dut._log.info(sb.report())
    dut._log.info(stream_chk.report())
    dut._log.info(axil_chk.report())

    save_coverage_json(cov_data, "coverage_report.json")

    return sb, cov


@cocotb.test()
async def test_random_100(dut):
    """100 random Add Orders with scoreboard check."""
    weights = [0.5, -1.0, 0.25, 2.0]
    sb, cov = await run_random_orders(dut, count=100, seed=42, weights=weights)
    assert sb.passed, f"Scoreboard failed:\n{sb.report()}"


@cocotb.test()
async def test_random_coverage_closure(dut):
    """Run random orders targeting 100% coverage of price_range x side cross bins.

    Uses a rotating constraint strategy: cycles through penny/dollar/large
    price ranges with balanced buy/sell to hit all 6 cross bins.
    """
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    # Start checkers
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

    cov = FunctionalCoverage()
    sb = Scoreboard(tolerance=0.05)

    ranges = ['penny', 'dollar', 'large']
    last_price = 0
    buy_flow = 0
    msg_count = 0
    max_messages = 400  # increased: pipeline latency growth reduces msgs-per-sim-cycle

    first_result = True
    for iteration in range(max_messages):
        if (cov.cp_price_range.coverage_pct >= 100.0
                and cov.cp_side.coverage_pct >= 100.0
                and cov.cross_price_side.coverage_pct >= 100.0):
            break

        price_range = ranges[iteration % len(ranges)]
        side_bias = 0.0 if (iteration // len(ranges)) % 2 == 0 else 1.0

        gen = ConstrainedRandomITCH(seed=iteration + 1000)
        msg = gen.generate_add_order(price_range=price_range, side_bias=side_bias)
        parsed = decode_add_order(msg)
        price = parsed['price']
        side = parsed['side']

        cov.sample(msg_type=0x41, price=price, side=side)

        price_delta = price - last_price
        side_enc = 1 if side == 'B' else -1
        buy_flow += (1 if side == 'B' else -1)
        features_int = [price_delta, side_enc, buy_flow, price]
        last_price = price

        expected = golden_inference(features_int, weights)
        sb.add_expected(expected)

        await axis.send(msg)

        if first_result:
            result = await wait_for_result(axil)
            first_result = False
        else:
            result = await wait_for_new_result(axil)

        sb.add_actual(result)
        msg_count += 1
        await ClockCycles(dut.clk, 5)

    sb.check()

    cov_data = cov.report()
    dut._log.info(format_coverage(cov_data))
    dut._log.info(f"Coverage closed after {msg_count} messages")
    dut._log.info(sb.report())

    save_coverage_json(cov_data, "coverage_report.json")

    # Check only the coverpoints exercised by this lliu_top test.
    # KC705-era groups (seq_state, cam_result, drop_event, etc.) are only
    # reachable via kc705_top stimulus and are intentionally excluded here.
    core_covered = (
        cov.cp_price_range.coverage_pct >= 100.0
        and cov.cp_side.coverage_pct >= 100.0
        and cov.cross_price_side.coverage_pct >= 100.0
    )
    assert core_covered, (
        f"Core price_range × side coverage not closed after {msg_count} msgs: "
        f"price_range={cov.cp_price_range.coverage_pct:.1f}% "
        f"side={cov.cp_side.coverage_pct:.1f}% "
        f"cross={cov.cross_price_side.coverage_pct:.1f}%"
    )
    assert sb.passed, f"Scoreboard failed:\n{sb.report()}"
