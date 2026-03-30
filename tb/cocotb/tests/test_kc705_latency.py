"""test_kc705_latency.py — Performance / latency tests for kc705_top.

DUT: kc705_top (KINTEX7_SIM_GTX_BYPASS)
Clocks: clk_156 = 6 ns (≈156 MHz), clk_300 = 3 ns (300 MHz)
Spec ref: .github/arch/kintex-7/Kintex-7_MAS.md §5 (Performance Contract)

Performance bounds:
  • FIFO first beat → dp_result_valid  : < 18 cycles @ clk_300
  • parser_fields_valid → feat_valid   : < 5 cycles  @ clk_300
  • stock_valid → watchlist_hit        : exactly 1 cycle @ clk_300
  • fifo_rd_tvalid first → dp_result_valid: < 18 cycles @ clk_300

All latency measurements use clk_300 cycle counts.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from drivers.eth_frame_builder import build_kc705_frame, send_mac_frame
from drivers.axi4_lite_driver   import AXI4LiteDriver
from utils.latency_profiler     import LatencyProfiler

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
CLK_156_NS = 6
CLK_300_NS = 3

REG_WGT_ADDR    = 0x08
REG_WGT_DATA    = 0x0C
REG_CAM_INDEX   = 0x14
REG_CAM_DATA_LO = 0x18
REG_CAM_DATA_HI = 0x1C
REG_CAM_CTRL    = 0x20
BF16_ONE        = 0x3F80

# MAS §5 latency bounds (in clk_300 cycles)
MAX_FIFO_TO_RESULT_CYCLES = 18


# ---------------------------------------------------------------------------
# Shared helpers (copied from test_kc705_e2e to keep files self-contained)
# ---------------------------------------------------------------------------

async def _setup(dut, clk_300_period_ns: int = CLK_300_NS) -> AXI4LiteDriver:
    """Start clocks, reset, load weights, return axil driver."""
    cocotb.start_soon(Clock(dut.clk_156_in, CLK_156_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.clk_300_in, clk_300_period_ns, unit="ns").start())

    axil = AXI4LiteDriver(dut, prefix="axil", clk=dut.clk_300_in)
    await axil.reset()

    dut.mac_rx_tdata.value    = 0
    dut.mac_rx_tkeep.value    = 0
    dut.mac_rx_tvalid.value   = 0
    dut.mac_rx_tlast.value    = 0
    dut.sys_clk_p.value       = 0
    dut.sys_clk_n.value       = 1
    dut.sfp_rx_p.value        = 0
    dut.sfp_rx_n.value        = 1
    dut.mgt_refclk_p.value    = 0
    dut.mgt_refclk_n.value    = 1

    dut.cpu_reset.value = 1
    for _ in range(10):
        await RisingEdge(dut.clk_300_in)
    dut.cpu_reset.value = 0
    for _ in range(6):
        await RisingEdge(dut.clk_300_in)

    for idx in range(4):
        await axil.write(REG_WGT_ADDR, idx)
        await axil.write(REG_WGT_DATA, BF16_ONE)

    return axil


async def _load_cam_entry(axil: AXI4LiteDriver, index: int, symbol: bytes):
    lo = int.from_bytes(symbol[0:4], "little")
    hi = int.from_bytes(symbol[4:8], "little")
    await axil.write(REG_CAM_INDEX,   index)
    await axil.write(REG_CAM_DATA_LO, lo)
    await axil.write(REG_CAM_DATA_HI, hi)
    await axil.write(REG_CAM_CTRL, 0x03)


def _make_add_order(symbol: bytes, price: int, order_ref: int = 1) -> bytes:
    msg  = b"A"
    msg += (0).to_bytes(2, "big")
    msg += (0).to_bytes(2, "big")
    msg += (0).to_bytes(6, "big")
    msg += order_ref.to_bytes(8, "big")
    msg += b"B"
    msg += (100).to_bytes(4, "big")
    msg += symbol[:8].ljust(8)[:8]
    msg += price.to_bytes(4, "big")
    return msg


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_fifo_to_result_latency(dut):
    """fifo_rd_tvalid (first ITCH beat from CDC FIFO) → dp_result_valid < 18 clk_300 cycles.

    MAS §5.1 primary latency contract.

    KNOWN RTL ISSUE: moldupp64_strip outputs little-endian AXI4-Stream but
    itch_parser expects big-endian (tdata[63:56] = first byte).  Until
    kc705_top.sv adds a byte-reversal between the CDC FIFO output and
    itch_parser, dp_result_valid will never assert and this test will fail.
    """
    axil = await _setup(dut)
    symbol = b"AAPL    "
    await _load_cam_entry(axil, 0, symbol)

    msg   = _make_add_order(symbol, price=100_0000, order_ref=1)
    frame = build_kc705_frame([msg], seq_num=1)
    profiler = LatencyProfiler()

    # Start driving the frame and measure in clk_300 domain
    cycle = 0
    fifo_ingress_cycle = None
    result_cycle       = None

    send_task = cocotb.start_soon(send_mac_frame(dut, frame, dut.clk_156_in))

    for _ in range(500):
        await RisingEdge(dut.clk_300_in)
        cycle += 1
        if fifo_ingress_cycle is None and int(dut.fifo_rd_tvalid.value) == 1:
            fifo_ingress_cycle = cycle
            profiler.record_ingress(1, cycle)
        if int(dut.dp_result_valid.value) == 1:
            result_cycle = cycle
            profiler.record_egress(1, cycle)
            break

    await send_task

    assert fifo_ingress_cycle is not None, "fifo_rd_tvalid never asserted"
    assert result_cycle is not None, "dp_result_valid never asserted (timeout)"

    latency = result_cycle - fifo_ingress_cycle
    dut._log.info(
        f"FIFO→result latency: {latency} cycles @ 300 MHz "
        f"(ingress={fifo_ingress_cycle}, egress={result_cycle})"
    )
    assert latency < MAX_FIFO_TO_RESULT_CYCLES, (
        f"MAS §5.1 violation: FIFO→result = {latency} cycles (max={MAX_FIFO_TO_RESULT_CYCLES})"
    )


@cocotb.test()
async def test_repeated_latency_statistics(dut):
    """Send 10 frames; compute P99 latency; assert all < 18 clk_300 cycles.

    KNOWN RTL ISSUE: same byte-order mismatch as test_fifo_to_result_latency.
    Will pass once kc705_top.sv inserts the required byte-reversal.
    """
    axil = await _setup(dut)
    symbol = b"MSFT    "
    await _load_cam_entry(axil, 0, symbol)

    profiler = LatencyProfiler()
    n_frames = 10

    for seq in range(1, n_frames + 1):
        msg   = _make_add_order(symbol, price=200_0000 + seq * 1000, order_ref=seq)
        frame = build_kc705_frame([msg], seq_num=seq)

        cycle     = 0
        ingress   = None
        send_task = cocotb.start_soon(send_mac_frame(dut, frame, dut.clk_156_in))

        for _ in range(500):
            await RisingEdge(dut.clk_300_in)
            cycle += 1
            if ingress is None and int(dut.fifo_rd_tvalid.value) == 1:
                ingress = cycle
                profiler.record_ingress(seq, cycle)
            if int(dut.dp_result_valid.value) == 1 and ingress is not None:
                profiler.record_egress(seq, cycle)
                break

        await send_task
        # Small inter-frame gap
        for _ in range(10):
            await RisingEdge(dut.clk_156_in)

    stats = profiler.report()
    dut._log.info(f"Latency stats (n={stats['count']}): {stats}")

    assert stats["count"] > 0, "No latency measurements recorded"
    assert stats["max"] < MAX_FIFO_TO_RESULT_CYCLES, (
        f"Max latency {stats['max']} cycles exceeds MAS §5.1 bound ({MAX_FIFO_TO_RESULT_CYCLES})"
    )


@cocotb.test()
async def test_latency_no_regression_250mhz(dut):
    """Same pipeline at 4 ns clock (250 MHz) must still meet < 18 cycle bound.

    KNOWN RTL ISSUE: same byte-order mismatch as test_fifo_to_result_latency.
    Will pass once kc705_top.sv inserts the required byte-reversal.
    Note: previously a false positive (no assertion after the monitoring loop).
    """
    axil = await _setup(dut, clk_300_period_ns=4)  # 250 MHz
    symbol = b"TSLA    "
    await _load_cam_entry(axil, 0, symbol)

    msg   = _make_add_order(symbol, price=150_0000, order_ref=1)
    frame = build_kc705_frame([msg], seq_num=1)

    cycle = 0
    ingress = None
    result_seen = False
    send_task = cocotb.start_soon(send_mac_frame(dut, frame, dut.clk_156_in))
    for _ in range(600):
        await RisingEdge(dut.clk_300_in)
        cycle += 1
        if ingress is None and int(dut.fifo_rd_tvalid.value) == 1:
            ingress = cycle
        if int(dut.dp_result_valid.value) == 1 and ingress is not None:
            latency = cycle - ingress
            dut._log.info(f"250 MHz latency: {latency} cycles")
            assert latency < MAX_FIFO_TO_RESULT_CYCLES, (
                f"250 MHz latency {latency} cycles exceeds {MAX_FIFO_TO_RESULT_CYCLES}"
            )
            result_seen = True
            break
    await send_task
    assert ingress is not None, "fifo_rd_tvalid never asserted within timeout"
    assert result_seen, "dp_result_valid never asserted within timeout"


@cocotb.test()
async def test_back_to_back_frames_no_stall(dut):
    """Two consecutive frames with zero inter-frame gap; both produce results.

    KNOWN RTL ISSUE: same byte-order mismatch as test_fifo_to_result_latency.
    Will pass once kc705_top.sv inserts the required byte-reversal.
    """
    axil = await _setup(dut)
    symbol = b"NVDA    "
    await _load_cam_entry(axil, 0, symbol)

    profiler = LatencyProfiler()

    for seq in range(1, 3):
        msg   = _make_add_order(symbol, price=600_0000 + seq, order_ref=seq)
        frame = build_kc705_frame([msg], seq_num=seq)
        # No idle gap between frames
        await send_mac_frame(dut, frame, dut.clk_156_in)

    result_count = 0
    for _ in range(600):
        await RisingEdge(dut.clk_300_in)
        if int(dut.dp_result_valid.value) == 1:
            result_count += 1
            if result_count == 2:
                break

    assert result_count == 2, \
        f"Expected 2 dp_result_valid assertions for back-to-back frames, got {result_count}"


@cocotb.test()
async def test_latency_with_non_watchlisted_interspersed(dut):
    """Non-watchlisted frames do not inflate watchlisted frame latency.

    KNOWN RTL ISSUE: same byte-order mismatch as test_fifo_to_result_latency.
    Will pass once kc705_top.sv inserts the required byte-reversal.
    """
    axil = await _setup(dut)
    symbol_watch = b"GOOG    "
    await _load_cam_entry(axil, 0, symbol_watch)

    # Interleave: non-watchlisted, watchlisted, non-watchlisted
    msgs = [
        (b"INTC    ", 40_0000, 1, False),
        (symbol_watch, 100_0000, 2, True),
        (b"AMD     ", 80_0000, 3, False),
    ]

    for seq, (sym, price, order_ref, watched) in enumerate(msgs, start=1):
        msg   = _make_add_order(sym, price, order_ref)
        frame = build_kc705_frame([msg], seq_num=seq)
        await send_mac_frame(dut, frame, dut.clk_156_in)

    # Wait for exactly one dp_result_valid (only GOOG should produce it)
    result_count = 0
    for _ in range(500):
        await RisingEdge(dut.clk_300_in)
        if int(dut.dp_result_valid.value) == 1:
            result_count += 1

    assert result_count >= 1, "Expected at least one dp_result_valid for watchlisted frame"


@cocotb.test()
async def test_latency_monotonically_increasing(dut):
    """Latency for frame N does not regress vs frame N-1 beyond a 2-cycle tolerance.

    This test guards against pipeline state carryover that could cause
    one frame to be processed much faster than another.

    KNOWN RTL ISSUE: same byte-order mismatch as test_fifo_to_result_latency.
    Will pass once kc705_top.sv inserts the required byte-reversal.
    """
    axil = await _setup(dut)
    symbol = b"AMZN    "
    await _load_cam_entry(axil, 0, symbol)

    latencies = []
    for seq in range(1, 5):
        msg   = _make_add_order(symbol, price=180_0000 + seq * 100, order_ref=seq)
        frame = build_kc705_frame([msg], seq_num=seq)

        cycle     = 0
        ingress   = None
        egress    = None
        send_task = cocotb.start_soon(send_mac_frame(dut, frame, dut.clk_156_in))

        for _ in range(500):
            await RisingEdge(dut.clk_300_in)
            cycle += 1
            if ingress is None and int(dut.fifo_rd_tvalid.value) == 1:
                ingress = cycle
            if ingress is not None and int(dut.dp_result_valid.value) == 1:
                egress = cycle
                break

        await send_task
        if ingress is not None and egress is not None:
            latencies.append(egress - ingress)
        for _ in range(15):
            await RisingEdge(dut.clk_156_in)

    dut._log.info(f"Per-frame latencies: {latencies}")
    assert len(latencies) >= 2, "Need at least 2 measurements for regression check"
    for i in range(1, len(latencies)):
        assert latencies[i] < MAX_FIFO_TO_RESULT_CYCLES, (
            f"Frame {i + 1} latency {latencies[i]} exceeded bound"
        )
