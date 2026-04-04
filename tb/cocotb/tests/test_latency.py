"""Latency profiling tests — cycle-accurate pipeline latency and jitter measurement.

Measures end-to-end latency from AXI4-Stream ingress handshake to inference
result availability, using the LatencyProfiler utility.
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
from utils.itch_decoder import encode_add_order
from stimulus.weight_loader import load_weights, float_to_bfloat16
from stimulus.backpressure_gen import BackpressureGenerator
from utils.latency_profiler import LatencyProfiler


# ---- Register addresses ----
REG_CTRL   = 0x00
REG_STATUS = 0x04
REG_RESULT = 0x10

DEFAULT_MAX_END_TO_END_LATENCY = int(os.getenv("LLIU_MAX_LATENCY", "15"))


def bits_to_float32(bits: int) -> float:
    return struct.unpack('>f', struct.pack('>I', bits & 0xFFFFFFFF))[0]


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


async def get_cycle(dut):
    """Return the current simulation time in clock cycles (10 ns period)."""
    return int(cocotb.utils.get_sim_time(units='ns') // 10)


async def measure_feature_latency(dut, timeout_cycles=8):
    """Measure parser_fields_valid -> feat_valid latency using internal DUT signals."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.parser_fields_valid.value) == 1:
            start_cycle = await get_cycle(dut)
            break
    else:
        raise TimeoutError("parser_fields_valid did not assert within timeout")

    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.feat_valid.value) == 1:
            end_cycle = await get_cycle(dut)
            return end_cycle - start_cycle

    raise TimeoutError("feat_valid did not assert within timeout after parser_fields_valid")


async def measure_end_to_end_latency(dut, timeout_cycles=64):
    """Measure final AXIS beat accepted -> dp_result_valid using internal DUT signals."""
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if (
            int(dut.s_axis_tvalid.value) == 1
            and int(dut.s_axis_tready.value) == 1
            and int(dut.s_axis_tlast.value) == 1
        ):
            start_cycle = await get_cycle(dut)
            break
    else:
        raise TimeoutError("final AXI4-Stream beat was not accepted within timeout")

    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.dp_result_valid.value) == 1:
            end_cycle = await get_cycle(dut)
            return end_cycle - start_cycle

    raise TimeoutError("dp_result_valid did not assert within timeout after final AXI beat")


async def send_and_measure(dut, axis, axil, profiler, msg_id, msg,
                           first=False, timeout_cycles=300):
    """Send a message, record ingress/egress timestamps, return result."""
    # Record ingress at the clock edge where we start the send
    ingress_cycle = await get_cycle(dut)
    profiler.record_ingress(msg_id, ingress_cycle)

    await axis.send(msg)

    if first:
        # First message: poll until result_ready
        for _ in range(timeout_cycles):
            status = await axil.read(REG_STATUS)
            if status & 0x1:
                egress_cycle = await get_cycle(dut)
                profiler.record_egress(msg_id, egress_cycle)
                result_bits = await axil.read(REG_RESULT)
                return bits_to_float32(result_bits)
            await RisingEdge(dut.clk)
    else:
        # Subsequent messages: wait for busy then result_ready
        for _ in range(timeout_cycles):
            status = await axil.read(REG_STATUS)
            if status & 0x2:
                break
            await RisingEdge(dut.clk)
        for _ in range(timeout_cycles):
            status = await axil.read(REG_STATUS)
            if (not (status & 0x2)) and (status & 0x1):
                egress_cycle = await get_cycle(dut)
                profiler.record_egress(msg_id, egress_cycle)
                result_bits = await axil.read(REG_RESULT)
                return bits_to_float32(result_bits)
            await RisingEdge(dut.clk)

    raise TimeoutError(f"Inference result not ready within {timeout_cycles} cycles for msg {msg_id}")


@cocotb.test()
async def test_feature_latency_spec(dut):
    """Verify the parser_fields_valid -> feat_valid contract stays under 5 cycles."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    await axis.reset()
    await RisingEdge(dut.clk)

    latencies = []
    for index in range(8):
        msg = encode_add_order(
            order_ref=index + 1,
            side='B' if index % 2 == 0 else 'S',
            price=10_000 + index * 250,
        )
        await axis.send(msg)
        latency = await measure_feature_latency(dut)
        latencies.append(latency)
        await ClockCycles(dut.clk, 2)

    dut._log.info(f"Feature latency samples: {latencies}")
    assert max(latencies) < 5, f"parser_fields_valid -> feat_valid max latency {max(latencies)} cycles exceeds spec"


@cocotb.test()
async def test_end_to_end_latency_spec(dut):
    """Verify final AXIS beat accepted -> dp_result_valid stays under the configured limit."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    weights = [1.0, 1.0, 1.0, 1.0]
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    latencies = []
    for index in range(4):
        msg = encode_add_order(
            order_ref=index + 1,
            side='B' if index % 2 == 0 else 'S',
            price=10_000 + index * 250,
        )
        latency_task = cocotb.start_soon(measure_end_to_end_latency(dut))
        await axis.send(msg)
        latency = await latency_task
        latencies.append(latency)
        await ClockCycles(dut.clk, 4)

    dut._log.info(
        f"End-to-end latency samples: {latencies} (limit={DEFAULT_MAX_END_TO_END_LATENCY} cycles)"
    )
    assert max(latencies) < DEFAULT_MAX_END_TO_END_LATENCY, (
        f"final AXIS beat -> dp_result_valid max latency {max(latencies)} cycles exceeds "
        f"spec {DEFAULT_MAX_END_TO_END_LATENCY}"
    )


@cocotb.test()
async def test_latency_single(dut):
    """Single message — verify end-to-end pipeline latency is bounded."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    weights = [1.0, 1.0, 1.0, 1.0]
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    profiler = LatencyProfiler()

    msg = encode_add_order(order_ref=1, side='B', price=10000)
    await send_and_measure(dut, axis, axil, profiler, msg_id=0, msg=msg, first=True)

    stats = profiler.report()
    dut._log.info(profiler.format_report())
    dut._log.info(f"Single-message latency: {stats['min']} cycles")

    # Pipeline latency should be reasonable (parser + feature_extract + sequencer + dot_product)
    # Generous bound: < 50 cycles for full end-to-end through AXI polling
    assert stats['min'] > 0, "Latency must be positive"
    assert stats['min'] < 50, f"Single message latency {stats['min']} cycles exceeds 50 cycle bound"


@cocotb.test()
async def test_latency_sustained(dut):
    """100 back-to-back messages — report latency distribution."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    weights = [0.5, -1.0, 0.25, 2.0]
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    profiler = LatencyProfiler()
    num_messages = 100

    for i in range(num_messages):
        price = 1000 + i * 50
        side = 'B' if i % 2 == 0 else 'S'
        msg = encode_add_order(order_ref=i + 1, side=side, price=price)

        await send_and_measure(dut, axis, axil, profiler, msg_id=i, msg=msg,
                               first=(i == 0))
        # Small gap between messages
        await ClockCycles(dut.clk, 5)

    stats = profiler.report()
    dut._log.info(profiler.format_report())
    dut._log.info(profiler.histogram())

    assert stats['count'] == num_messages, f"Expected {num_messages} samples, got {stats['count']}"
    assert stats['min'] > 0, "All latencies must be positive"
    dut._log.info(f"Sustained: min={stats['min']} max={stats['max']} "
                  f"mean={stats['mean']:.1f} p99={stats['p99']}")


@cocotb.test()
async def test_latency_under_backpressure(dut):
    """Measure latency increase under periodic stall patterns."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    weights = [1.0, 1.0, 1.0, 1.0]
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    # --- Baseline: no backpressure ---
    profiler_base = LatencyProfiler()
    for i in range(20):
        price = 2000 + i * 100
        side = 'B' if i % 2 == 0 else 'S'
        msg = encode_add_order(order_ref=i + 1, side=side, price=price)
        await send_and_measure(dut, axis, axil, profiler_base, msg_id=i, msg=msg,
                               first=(i == 0))
        await ClockCycles(dut.clk, 5)

    base_stats = profiler_base.report()

    # --- Reset for backpressure run ---
    await reset_dut(dut)
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    # --- With backpressure: periodic stalls ---
    bp = BackpressureGenerator(dut, pattern='periodic', ready_cycles=2, stall_cycles=4)
    profiler_bp = LatencyProfiler()
    for i in range(20):
        price = 2000 + i * 100
        side = 'B' if i % 2 == 0 else 'S'
        msg = encode_add_order(order_ref=i + 1, side=side, price=price)
        await send_and_measure(dut, axis, axil, profiler_bp, msg_id=i, msg=msg,
                               first=(i == 0))
        await bp.inter_message_delay()

    bp_stats = profiler_bp.report()

    dut._log.info("=== Baseline (no backpressure) ===")
    dut._log.info(profiler_base.format_report())
    dut._log.info("=== With backpressure ===")
    dut._log.info(profiler_bp.format_report())

    assert base_stats['count'] == 20, "Baseline should have 20 samples"
    assert bp_stats['count'] == 20, "Backpressure run should have 20 samples"
    # Backpressure should not cause catastrophic latency increase
    assert bp_stats['max'] < base_stats['max'] * 10, \
        f"Backpressure max latency {bp_stats['max']} exceeds 10x baseline {base_stats['max']}"


@cocotb.test()
async def test_jitter(dut):
    """Verify latency stddev (jitter) is within bounds for deterministic pipeline."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    axis = AXI4StreamDriver(dut, prefix="s_axis")
    axil = AXI4LiteDriver(dut, prefix="s_axil")
    await axis.reset()
    await axil.reset()
    await RisingEdge(dut.clk)

    weights = [1.0, 1.0, 1.0, 1.0]
    await load_weights(axil, weights)
    await ClockCycles(dut.clk, 5)

    profiler = LatencyProfiler()
    num_messages = 50

    for i in range(num_messages):
        price = 5000 + i * 10
        side = 'B' if i % 2 == 0 else 'S'
        msg = encode_add_order(order_ref=i + 1, side=side, price=price)
        await send_and_measure(dut, axis, axil, profiler, msg_id=i, msg=msg,
                               first=(i == 0))
        # Uniform spacing between messages
        await ClockCycles(dut.clk, 10)

    stats = profiler.report()
    dut._log.info(profiler.format_report())

    assert stats['count'] == num_messages, f"Expected {num_messages} samples, got {stats['count']}"
    # For a deterministic pipeline with uniform input spacing, jitter should be low.
    # Allow some variance from AXI polling overhead.
    jitter = stats['stddev']
    dut._log.info(f"Jitter (stddev): {jitter:.2f} cycles")
    # Generous bound: stddev < 20 cycles (AXI polling adds variability)
    assert jitter < 20, f"Jitter {jitter:.2f} exceeds 20 cycle bound"
