"""test_kc705_e2e.py — End-to-end system tests for kc705_top.

DUT: kc705_top (KINTEX7_SIM_GTX_BYPASS)
Clocks: clk_156 = 6 ns (≈156 MHz), clk_300 = 3 ns (300 MHz)
Spec ref: .github/arch/kintex-7/Kintex-7_MAS.md

Testbench stimulus flows:
  Testbench → mac_rx_* (full Eth/IPv4/UDP/MoldUDP64 frames built by eth_frame_builder)
    → eth_axis_rx_wrap → udp_complete_64 → moldupp64_strip (all clk_156)
    → axis_async_fifo CDC → itch_parser → symbol_filter
    → feature_extractor → dot_product_engine → dp_result / dp_result_valid (clk_300)
  Testbench ↔ axil_* (AXI4-Lite driver) for setup (CAM, weights) and readback

Notes on timing:
  • cpu_reset is active-high; the DUT uses 2-FF synchronisers per clock domain
    so effective reset lasts at least 2 rising-clock-edges from deassertion.
  • After cpu_reset deasserts, allow at least 4 clk_300 cycles for rst_300 to clear.
  • Both clocks are free-running; the FIFO and CDC mean results may arrive many
    cycles after the last frame beat — allow generous timeouts.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
import struct
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from drivers.eth_frame_builder import build_kc705_frame, send_mac_frame
from drivers.axi4_lite_driver   import AXI4LiteDriver
from models.golden_model        import GoldenModel

# ---------------------------------------------------------------------------
# Register addresses (from lliu_pkg.sv)
# ---------------------------------------------------------------------------
REG_CTRL           = 0x00
REG_STATUS         = 0x04
REG_WGT_ADDR       = 0x08
REG_WGT_DATA       = 0x0C
REG_RESULT         = 0x10
REG_CAM_INDEX      = 0x14
REG_CAM_DATA_LO    = 0x18
REG_CAM_DATA_HI    = 0x1C
REG_CAM_CTRL       = 0x20
REG_DROPPED_FRAMES = 0x24
REG_DROPPED_DGRAMS = 0x28
REG_SEQ_LO         = 0x2C
REG_SEQ_HI         = 0x30
REG_GTX_LOCK       = 0x34

# Clocks
CLK_156_NS = 6
CLK_300_NS = 3

# Default weights (bfloat16 bit patterns of 1.0 = 0x3F80)
BF16_ONE = 0x3F80
DEFAULT_WEIGHTS = [BF16_ONE] * 4   # 4 weights, all 1.0


# ---------------------------------------------------------------------------
# Shared fixture
# ---------------------------------------------------------------------------

async def _setup(dut) -> AXI4LiteDriver:
    """Start clocks, assert reset, load default weights into DUT, return axil driver."""
    # Start both clocks independently
    cocotb.start_soon(Clock(dut.clk_156_in, CLK_156_NS, unit="ns").start())
    cocotb.start_soon(Clock(dut.clk_300_in, CLK_300_NS, unit="ns").start())

    axil = AXI4LiteDriver(dut, prefix="axil", clk=dut.clk_300_in)
    await axil.reset()

    # Tie testbench-driven inputs
    dut.mac_rx_tdata.value  = 0
    dut.mac_rx_tkeep.value  = 0
    dut.mac_rx_tvalid.value = 0
    dut.mac_rx_tlast.value  = 0

    # Assert reset (active-high)
    dut.cpu_reset.value = 1
    # Board-level differential stubs (not used in sim but must be driven)
    dut.sys_clk_p.value       = 0
    dut.sys_clk_n.value       = 1
    dut.sfp_rx_p.value        = 0
    dut.sfp_rx_n.value        = 1
    dut.mgt_refclk_p.value    = 0
    dut.mgt_refclk_n.value    = 1

    # 10 clk_300 cycles of reset
    for _ in range(10):
        await RisingEdge(dut.clk_300_in)
    dut.cpu_reset.value = 0
    # Additional settling cycles for 2-FF synchronisers
    for _ in range(6):
        await RisingEdge(dut.clk_300_in)

    # Load weights via AXI4-Lite
    for idx, wgt in enumerate(DEFAULT_WEIGHTS):
        await axil.write(REG_WGT_ADDR, idx)
        await axil.write(REG_WGT_DATA, wgt)

    return axil


async def _load_cam_entry(axil: AXI4LiteDriver, index: int, symbol: bytes):
    """Program one 8-byte symbol into the watchlist CAM at the given index.

    symbol: exactly 8 bytes (space-padded ASCII ticker, e.g. b'AAPL    ')
    """
    assert len(symbol) == 8
    lo = int.from_bytes(symbol[0:4], "little")
    hi = int.from_bytes(symbol[4:8], "little")
    await axil.write(REG_CAM_INDEX,   index)
    await axil.write(REG_CAM_DATA_LO, lo)
    await axil.write(REG_CAM_DATA_HI, hi)
    # Bit[0]=wr_valid (self-clearing), Bit[1]=en_bit (entry enabled)
    await axil.write(REG_CAM_CTRL, 0x03)


def _make_add_order(
    stock: bytes,
    price: int,
    order_ref: int = 1,
    side: bytes = b"B",
) -> bytes:
    """Build a 36-byte ITCH 5.0 Add Order message body."""
    msg  = b"A"
    msg += (0).to_bytes(2, "big")          # stock_locate
    msg += (0).to_bytes(2, "big")          # tracking_number
    msg += (0).to_bytes(6, "big")          # timestamp
    msg += order_ref.to_bytes(8, "big")    # order_reference_number
    msg += side                            # buy_sell_indicator
    msg += (100).to_bytes(4, "big")        # shares
    msg += stock[:8].ljust(8)[:8]          # stock (8-byte space-padded)
    msg += price.to_bytes(4, "big")        # price
    assert len(msg) == 36
    return msg


async def _wait_dp_result(dut, timeout_cyc: int = 200) -> int | None:
    """Wait for dp_result_valid; return dp_result or None on timeout."""
    for _ in range(timeout_cyc):
        await RisingEdge(dut.clk_300_in)
        if int(dut.dp_result_valid.value) == 1:
            return int(dut.dp_result.value)
    return None


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_gtx_lock_read(dut):
    """AXIL_REG_GTX_LOCK[0] reads as 1 in simulation (tied high in kc705_top)."""
    axil = await _setup(dut)
    lock = await axil.read(REG_GTX_LOCK)
    assert lock & 0x1, f"GTX_LOCK bit should be 1 in sim, got 0x{lock:08x}"


@cocotb.test()
async def test_cam_write_readback(dut):
    """Write a symbol to the CAM via AXI4-Lite; verify DROPPED_DGRAMS stays 0."""
    axil = await _setup(dut)
    await _load_cam_entry(axil, 0, b"AAPL    ")
    # The CAM is write-only in this RTL, but dropped_dgrams = 0 confirms no errors
    dg = await axil.read(REG_DROPPED_DGRAMS)
    assert dg == 0, f"dropped_datagrams should be 0, got {dg}"


@cocotb.test()
async def test_e2e_watchlisted_symbol(dut):
    """Watchlisted Add Order traverses full pipeline and produces dp_result_valid.

    KNOWN RTL ISSUE (as of kc705 migration):
      ``moldupp64_strip`` outputs AXI4-Stream in little-endian byte order
      (byte 0 → tdata[7:0]), but ``itch_parser`` expects big-endian
      (tdata[63:56] = first byte).  Until ``kc705_top.sv`` inserts a 64-bit
      byte-reversal between the CDC FIFO output and ``itch_parser`` input,
      this test will fail because the parser reads garbage from each beat
      and never asserts ``dp_result_valid``.

      Diagnostic signals confirm the frame IS processed through
      ``eth_axis_rx_wrap`` → ``udp_complete_64`` → ``moldupp64_strip``
      (dropped_frames=0, dropped_datagrams=0, expected_seq_num advances).
    """
    axil = await _setup(dut)

    # Program AAPL into CAM slot 0
    symbol = b"AAPL    "
    await _load_cam_entry(axil, 0, symbol)

    # Build and send frame
    msg    = _make_add_order(symbol, price=100_0000, order_ref=1)
    frame  = build_kc705_frame([msg], seq_num=1, msg_count=1)
    await send_mac_frame(dut, frame, dut.clk_156_in)

    result = await _wait_dp_result(dut, timeout_cyc=400)

    # Diagnostics on failure — helps distinguish pipeline stage
    if result is None:
        df  = await axil.read(REG_DROPPED_FRAMES)
        ddg = await axil.read(REG_DROPPED_DGRAMS)
        seq = await axil.read(REG_SEQ_LO)
        dut._log.warning(
            f"DIAG: dropped_frames={df} dropped_datagrams={ddg} "
            f"expected_seq_lo={seq:#010x}"
        )

    assert result is not None, "dp_result_valid never asserted after watchlisted frame"


@cocotb.test()
async def test_e2e_non_watchlisted_symbol(dut):
    """Non-watchlisted frame passes through parser but produces no dp_result_valid."""
    axil = await _setup(dut)

    # Program AAPL only; send MSFT (not in CAM)
    await _load_cam_entry(axil, 0, b"AAPL    ")

    msg   = _make_add_order(b"MSFT    ", price=200_0000, order_ref=2)
    frame = build_kc705_frame([msg], seq_num=1, msg_count=1)
    await send_mac_frame(dut, frame, dut.clk_156_in)

    # Allow generous settling time
    result = await _wait_dp_result(dut, timeout_cyc=200)
    assert result is None, \
        "dp_result_valid should NOT assert for non-watchlisted symbol"


@cocotb.test()
async def test_e2e_golden_model_comparison(dut):
    """dp_result matches the golden model for a known Add Order.

    KNOWN RTL ISSUE: same byte-order mismatch as test_e2e_watchlisted_symbol.
    Will pass once kc705_top.sv inserts a byte-reversal before itch_parser.
    """
    axil = await _setup(dut)

    symbol = b"TSLA    "
    price  = 150_0000    # 150.0000 in ITCH 4-decimal fixed-point
    order_ref = 42

    await _load_cam_entry(axil, 1, symbol)

    msg   = _make_add_order(symbol, price=price, order_ref=order_ref)
    frame = build_kc705_frame([msg], seq_num=1, msg_count=1)
    await send_mac_frame(dut, frame, dut.clk_156_in)

    result_raw = await _wait_dp_result(dut, timeout_cyc=400)
    assert result_raw is not None, "dp_result_valid timed out"

    # Golden model computation (all weights = 1.0)
    gm = GoldenModel()
    fields   = gm.parse_add_order(msg)
    features = gm.extract_features(fields["price"], fields["order_ref"], fields["side"])
    import numpy as np
    weights  = np.array([1.0, 1.0, 1.0, 1.0], dtype=np.float32)
    expected = gm.inference(features, weights)

    # Unpack the 32-bit result as a float and compare with tolerance
    result_float = struct.unpack(">f", struct.pack(">I", result_raw))[0]
    assert abs(result_float - expected) < 0.5, (
        f"Golden model mismatch: expected {expected:.4f}, got {result_float:.4f}"
    )


@cocotb.test()
async def test_e2e_two_sequential_frames(dut):
    """Two consecutive valid frames both trigger dp_result_valid.

    KNOWN RTL ISSUE: same byte-order mismatch as test_e2e_watchlisted_symbol.
    Will pass once kc705_top.sv inserts a byte-reversal before itch_parser.
    """
    axil = await _setup(dut)

    symbol = b"NVDA    "
    await _load_cam_entry(axil, 2, symbol)

    result_count = 0
    for seq, price in [(1, 100_0000), (2, 101_0000)]:
        msg   = _make_add_order(symbol, price=price, order_ref=seq)
        frame = build_kc705_frame([msg], seq_num=seq, msg_count=1)
        await send_mac_frame(dut, frame, dut.clk_156_in)
        result = await _wait_dp_result(dut, timeout_cyc=400)
        if result is not None:
            result_count += 1
        # Brief gap between frames
        for _ in range(10):
            await RisingEdge(dut.clk_156_in)

    assert result_count == 2, f"Expected 2 dp_result_valid assertions, got {result_count}"


@cocotb.test()
async def test_e2e_seq_gap_drops_frame(dut):
    """Sequence-number gap → moldupp64_strip drops the datagram; dropped_dgrams++."""
    axil = await _setup(dut)

    symbol = b"GOOG    "
    await _load_cam_entry(axil, 3, symbol)

    # Send valid seq=1
    msg   = _make_add_order(symbol, price=100_0000, order_ref=1)
    frame = build_kc705_frame([msg], seq_num=1)
    await send_mac_frame(dut, frame, dut.clk_156_in)
    for _ in range(20):
        await RisingEdge(dut.clk_300_in)

    # Now send seq=5 (gap: seq 2-4 missing)
    frame_gap = build_kc705_frame([msg], seq_num=5)
    await send_mac_frame(dut, frame_gap, dut.clk_156_in)
    for _ in range(30):
        await RisingEdge(dut.clk_300_in)

    # Verify dropped_datagrams count via AXI4-Lite
    dg = await axil.read(REG_DROPPED_DGRAMS)
    assert dg >= 1, f"dropped_datagrams should be ≥1 after gap, got {dg}"


@cocotb.test()
async def test_e2e_monitoring_seq_num(dut):
    """expected_seq_num[31:0] is visible via AXI4-Lite after processing a frame."""
    axil = await _setup(dut)

    symbol = b"AMZN    "
    await _load_cam_entry(axil, 4, symbol)

    msg   = _make_add_order(symbol, price=180_0000, order_ref=1)
    frame = build_kc705_frame([msg], seq_num=1, msg_count=1)
    await send_mac_frame(dut, frame, dut.clk_156_in)

    # Allow CDC re-sample and pipeline settling
    for _ in range(40):
        await RisingEdge(dut.clk_300_in)

    seq_lo = await axil.read(REG_SEQ_LO)
    # After one accepted datagram with msg_count=1, expected_seq_num should be 2
    assert seq_lo == 2, f"REG_SEQ_LO should be 2, got {seq_lo}"


@cocotb.test()
async def test_e2e_soft_reset_clears_state(dut):
    """Soft-reset via CTRL[1] clears in-flight inference state."""
    axil = await _setup(dut)

    # Assert soft_reset bit
    await axil.write(REG_CTRL, 0x02)  # bit[1] = soft_reset
    for _ in range(8):
        await RisingEdge(dut.clk_300_in)

    # Release soft_reset
    await axil.write(REG_CTRL, 0x00)
    for _ in range(4):
        await RisingEdge(dut.clk_300_in)

    # After soft_reset, dp_result_valid should be deasserted
    for _ in range(8):
        await RisingEdge(dut.clk_300_in)
    assert int(dut.dp_result_valid.value) == 0, \
        "dp_result_valid should be 0 after soft_reset"


@cocotb.test()
async def test_e2e_multi_symbol_cam(dut):
    """Multiple symbols in CAM; only matching symbol triggers inference.

    KNOWN RTL ISSUE: same byte-order mismatch as test_e2e_watchlisted_symbol.
    Will pass once kc705_top.sv inserts a byte-reversal before itch_parser.
    """
    axil = await _setup(dut)

    await _load_cam_entry(axil, 0, b"AAPL    ")
    await _load_cam_entry(axil, 1, b"META    ")
    await _load_cam_entry(axil, 2, b"NFLX    ")

    # Watchlisted symbol → should trigger
    msg_a = _make_add_order(b"META    ", price=300_0000, order_ref=1)
    frame_a = build_kc705_frame([msg_a], seq_num=1)
    await send_mac_frame(dut, frame_a, dut.clk_156_in)
    result_meta = await _wait_dp_result(dut, timeout_cyc=400)
    assert result_meta is not None, "META (watchlisted) should produce dp_result_valid"

    for _ in range(10):
        await RisingEdge(dut.clk_156_in)

    # Non-watchlisted symbol → should NOT trigger
    msg_b = _make_add_order(b"INTC    ", price=40_0000, order_ref=2)
    frame_b = build_kc705_frame([msg_b], seq_num=2)
    await send_mac_frame(dut, frame_b, dut.clk_156_in)
    result_intc = await _wait_dp_result(dut, timeout_cyc=150)
    assert result_intc is None, "INTC (not watchlisted) should NOT produce dp_result_valid"
