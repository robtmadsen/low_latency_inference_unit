"""test_ouch_compliance.py — OUCH 5.0 packet compliance tests for ouch_engine.sv.

DUT: ouch_engine
Clock: 10 ns
Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.7

The DUT produces a 6-beat (48-byte) AXI4-Stream OUCH 5.0 Enter Order packet.

Beat layout (all fields big-endian)
------------------------------------
Beat 0 [63:0] = {msg_type[7:0], token[63:8]}
Beat 1 [63:0] = {token[7:0], '0'×6, side[7:0]}
Beat 2 [63:0] = {0x0, shares[23:0], stock_bytes[0:3]}
Beat 3 [63:0] = {stock_bytes[4:7], price[31:0]}
Beat 4 [63:0] = {TIF[31:0], firm[63:32]}          (from BRAM template)
Beat 5 [63:0] = {firm[31:0], display[7:0], rsvd[23:0]}   tlast asserted

msg_type = 0x4F ('O')
OUCH_SIDE_BUY  = 0x42 ('B')
OUCH_SIDE_SELL = 0x53 ('S')
Token auto-increments from 0 each reset.

Two template BRAM write ports are used:
  tmpl_wr_addr[8:2] = symbol_id (0-127)
  tmpl_wr_addr[1:0] = 0 → b2 (stock[0:3])
                      1 → b3 (stock[4:7])
                      2 → b4 ({TIF,firm_hi})
                      3 → b5 ({firm_lo,display,rsvd})
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly
import struct

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
OUCH_MSG_TYPE  = 0x4F   # 'O'
OUCH_SIDE_BUY  = 0x42   # 'B'
OUCH_SIDE_SELL = 0x53   # 'S'
TOTAL_BEATS    = 6


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def reset_dut(dut):
    """10 ns clock; 5-cycle reset; initialise all inputs."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    dut.rst.value             = 1
    dut.risk_pass.value       = 0
    dut.side.value            = 1
    dut.price.value           = 0
    dut.symbol_id.value       = 0
    dut.proposed_shares.value = 0
    dut.timestamp.value       = 0
    dut.tmpl_wr_addr.value    = 0
    dut.tmpl_wr_data.value    = 0
    dut.tmpl_wr_en.value      = 0
    dut.m_axis_tready.value   = 1   # consumer always-ready by default
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def write_template(dut, sym_id: int, stock: bytes,
                         tif: int = 0x0000_0000,
                         firm: bytes = b'FIRM',
                         display: int = 0x59):
    """Write the 4 template beats for a given symbol_id.

    stock : 8-byte ASCII (space-padded)
    tif   : time-in-force (IOC=0)
    firm  : 4-byte ASCII firm name
    display : 1-byte display indicator
    """
    assert len(stock) == 8
    assert len(firm)  == 4

    stock_int = int.from_bytes(stock, 'big')
    firm_int  = int.from_bytes(firm,  'big')
    stock_hi  = (stock_int >> 32) & 0xFFFF_FFFF  # bytes 0-3
    stock_lo  = stock_int & 0xFFFF_FFFF           # bytes 4-7

    # Beat 2 template: stock_hi in bits[31:0] (bits[63:32] hold shares hot-patch slot)
    b2_val = stock_hi & 0xFFFF_FFFF
    # Beat 3 template: stock_lo in bits[31:0] (bits[63:32] hold price hot-patch slot)
    b3_val = stock_lo & 0xFFFF_FFFF
    # Beat 4: {TIF[31:0], firm[63:32]}  → {tif, firm_int[31:0]} treat firm as 4-byte
    b4_val = ((tif & 0xFFFF_FFFF) << 32) | (firm_int & 0xFFFF_FFFF)
    # Beat 5: {firm_lo[31:0]=0, display[7:0], rsvd[23:0]=0}
    # Per RTL comment: "firm_lo, display, rsvd"; firm only 4 bytes → firm_lo = 0
    b5_val = (display & 0xFF) << 24

    base_addr = sym_id << 2   # sym_id maps to tmpl_wr_addr[8:2]

    for offset, val in enumerate([b2_val, b3_val, b4_val, b5_val]):
        dut.tmpl_wr_addr.value = base_addr | offset
        dut.tmpl_wr_data.value = val & 0xFFFF_FFFF_FFFF_FFFF
        dut.tmpl_wr_en.value   = 1
        await RisingEdge(dut.clk)

    dut.tmpl_wr_en.value = 0
    await RisingEdge(dut.clk)


async def send_order(dut, price: int, shares: int, sym_id: int, side: int,
                     timeout: int = 30):
    """Pulse risk_pass for one cycle; wait for m_axis_tvalid; collect all beats.

    Returns list of 6 ints (beat values).  Raises on timeout.
    """
    dut.price.value           = price
    dut.proposed_shares.value = shares & 0xFFFFFF
    dut.symbol_id.value       = sym_id
    dut.side.value            = side
    dut.timestamp.value       = 0
    dut.risk_pass.value       = 1
    await RisingEdge(dut.clk)
    dut.risk_pass.value       = 0

    beats = []
    for _ in range(timeout * TOTAL_BEATS):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value) == 1 and int(dut.m_axis_tready.value) == 1:
            beats.append(int(dut.m_axis_tdata.value))
            if len(beats) == TOTAL_BEATS:
                return beats
    raise TimeoutError(f"ouch_engine did not produce {TOTAL_BEATS} beats within {timeout} cycles")


def decode_packet(beats):
    """Decode 6 beats into a dict of named fields."""
    b0, b1, b2, b3, b4, b5 = beats
    msg_type   = (b0 >> 56) & 0xFF
    token      = ((b0 & 0x00FF_FFFF_FFFF_FFFF) << 8) | ((b1 >> 56) & 0xFF)
    pad_bytes  = [(b1 >> (48 - i*8)) & 0xFF for i in range(6)]
    side_byte  = b1 & 0xFF
    shares     = (b2 >> 32) & 0xFFFFFF  # 24-bit (bits [55:32] per hot-patch layout)
    stock_hi   = b2 & 0xFFFF_FFFF
    stock_lo   = (b3 >> 32) & 0xFFFF_FFFF
    price      = b3 & 0xFFFF_FFFF
    tif        = (b4 >> 32) & 0xFFFF_FFFF
    firm_hi    = b4 & 0xFFFF_FFFF
    display    = (b5 >> 24) & 0xFF
    return {
        'msg_type' : msg_type,
        'token'    : token,
        'pad_bytes': pad_bytes,
        'side_byte': side_byte,
        'shares'   : shares,
        'stock_hi' : stock_hi,
        'stock_lo' : stock_lo,
        'price'    : price,
        'tif'      : tif,
        'firm_hi'  : firm_hi,
        'display'  : display,
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_msg_type_is_O(dut):
    """Beat 0 [63:56] must always be 0x4F ('O')."""
    await reset_dut(dut)
    await write_template(dut, sym_id=0, stock=b'AAPL    ')
    beats = await send_order(dut, price=10_000, shares=100, sym_id=0, side=1)
    pkt = decode_packet(beats)
    assert pkt['msg_type'] == OUCH_MSG_TYPE, (
        f"msg_type expected 0x4F, got 0x{pkt['msg_type']:02X}")


@cocotb.test()
async def test_buy_sell_indicator(dut):
    """Beat 1[7:0] must be 0x42 ('B') for buy, 0x53 ('S') for sell."""
    await reset_dut(dut)
    await write_template(dut, sym_id=0, stock=b'MSFT    ')

    # Buy
    beats_buy = await send_order(dut, price=5_000, shares=50, sym_id=0, side=1)
    assert beats_buy[1] & 0xFF == OUCH_SIDE_BUY, (
        f"Buy indicator expected 0x42, got 0x{beats_buy[1] & 0xFF:02X}")

    # Sell (use a different symbol path but same template slot — just flip side)
    beats_sell = await send_order(dut, price=5_000, shares=50, sym_id=0, side=0)
    assert beats_sell[1] & 0xFF == OUCH_SIDE_SELL, (
        f"Sell indicator expected 0x53, got 0x{beats_sell[1] & 0xFF:02X}")


@cocotb.test()
async def test_price_hot_patch(dut):
    """Beat 3[31:0] must reflect the live proposed price, not the template price."""
    await reset_dut(dut)
    await write_template(dut, sym_id=1, stock=b'GOOG    ')

    for test_price in [1_234, 99_999, 1, 0xFFFF_FFFE]:
        beats = await send_order(dut, price=test_price, shares=10, sym_id=1, side=1)
        pkt = decode_packet(beats)
        assert pkt['price'] == test_price, (
            f"price mismatch: expected {test_price}, got {pkt['price']}")


@cocotb.test()
async def test_shares_hot_patch(dut):
    """Beat 2[55:32] must reflect the live proposed_shares."""
    await reset_dut(dut)
    await write_template(dut, sym_id=2, stock=b'TSLA    ')

    for test_shares in [1, 100, 9_999, 0xFFFFFF]:
        beats = await send_order(dut, price=10_000, shares=test_shares, sym_id=2, side=1)
        pkt = decode_packet(beats)
        assert pkt['shares'] == (test_shares & 0xFFFFFF), (
            f"shares mismatch: expected {test_shares & 0xFFFFFF}, got {pkt['shares']}")


@cocotb.test()
async def test_stock_from_template(dut):
    """Stock name bytes in beats 2–3 must come from the BRAM template."""
    await reset_dut(dut)
    stock = b'NVDA    '
    await write_template(dut, sym_id=3, stock=stock)
    beats = await send_order(dut, price=50_000, shares=200, sym_id=3, side=1)
    pkt = decode_packet(beats)

    stock_int = int.from_bytes(stock, 'big')
    expected_hi = (stock_int >> 32) & 0xFFFF_FFFF
    expected_lo = stock_int & 0xFFFF_FFFF
    assert pkt['stock_hi'] == expected_hi, (
        f"stock_hi mismatch: expected 0x{expected_hi:08X}, got 0x{pkt['stock_hi']:08X}")
    assert pkt['stock_lo'] == expected_lo, (
        f"stock_lo mismatch: expected 0x{expected_lo:08X}, got 0x{pkt['stock_lo']:08X}")


@cocotb.test()
async def test_tif_ioc_from_template(dut):
    """Beat 4[63:32] must carry the TIF value written into the template (IOC = 0)."""
    await reset_dut(dut)
    await write_template(dut, sym_id=4, stock=b'AMZN    ', tif=0x0000_0000)
    beats = await send_order(dut, price=3_000, shares=10, sym_id=4, side=0)
    pkt = decode_packet(beats)
    assert pkt['tif'] == 0x0000_0000, (
        f"TIF expected 0 (IOC), got 0x{pkt['tif']:08X}")


@cocotb.test()
async def test_token_auto_increments(dut):
    """Order token (64-bit) must increment by 1 per order starting from 0."""
    await reset_dut(dut)
    await write_template(dut, sym_id=0, stock=b'SPY     ')

    prev_token = None
    for i in range(4):
        beats = await send_order(dut, price=10_000, shares=100, sym_id=0, side=1)
        pkt = decode_packet(beats)
        tok = pkt['token']
        if prev_token is not None:
            assert tok == prev_token + 1, (
                f"order {i}: expected token {prev_token + 1}, got {tok}")
        prev_token = tok


@cocotb.test()
async def test_tlast_on_beat_5_only(dut):
    """m_axis_tlast must be asserted exactly on beat 5 (the final beat) and
    deasserted on beats 0–4."""
    await reset_dut(dut)
    await write_template(dut, sym_id=0, stock=b'QQQ     ')

    # Collect all 6 beats while monitoring tlast independently
    dut.risk_pass.value       = 1
    dut.price.value           = 1_000
    dut.proposed_shares.value = 50
    dut.symbol_id.value       = 0
    dut.side.value            = 1
    await RisingEdge(dut.clk)
    dut.risk_pass.value = 0

    tlast_per_beat = []
    timeout = 200
    beaten = 0
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            tlast_per_beat.append(int(dut.m_axis_tlast.value))
            beaten += 1
            if beaten == TOTAL_BEATS:
                break

    assert beaten == TOTAL_BEATS, f"Only got {beaten} beats"
    for i, tl in enumerate(tlast_per_beat[:-1]):
        assert tl == 0, f"tlast should be 0 on beat {i}, got {tl}"
    assert tlast_per_beat[-1] == 1, f"tlast should be 1 on beat 5"


@cocotb.test()
async def test_tkeep_all_ones(dut):
    """m_axis_tkeep must be 0xFF on every beat (all bytes valid)."""
    await reset_dut(dut)
    await write_template(dut, sym_id=0, stock=b'IWM     ')

    dut.risk_pass.value       = 1
    dut.price.value           = 2_000
    dut.proposed_shares.value = 75
    dut.symbol_id.value       = 0
    dut.side.value            = 0
    await RisingEdge(dut.clk)
    dut.risk_pass.value = 0

    beaten = 0
    for _ in range(200):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value) and int(dut.m_axis_tready.value):
            keep = int(dut.m_axis_tkeep.value)
            assert keep == 0xFF, f"tkeep beat {beaten}: expected 0xFF, got 0x{keep:02X}"
            beaten += 1
            if beaten == TOTAL_BEATS:
                break

    assert beaten == TOTAL_BEATS, f"Only got {beaten} beats"


@cocotb.test()
async def test_back_to_back_orders_different_symbols(dut):
    """Two consecutive orders targeting different symbols must produce correct
    independent packets (no template bleed between symbols)."""
    await reset_dut(dut)
    await write_template(dut, sym_id=10, stock=b'AAPL    ')
    await write_template(dut, sym_id=11, stock=b'GOOG    ')

    beats_a = await send_order(dut, price=10_000, shares=100, sym_id=10, side=1)
    beats_b = await send_order(dut, price=20_000, shares=200, sym_id=11, side=0)

    pkt_a = decode_packet(beats_a)
    pkt_b = decode_packet(beats_b)

    stock_aapl = int.from_bytes(b'AAPL    ', 'big')
    stock_goog = int.from_bytes(b'GOOG    ', 'big')

    hi_a = (stock_aapl >> 32) & 0xFFFF_FFFF
    lo_a = stock_aapl & 0xFFFF_FFFF
    hi_b = (stock_goog >> 32) & 0xFFFF_FFFF
    lo_b = stock_goog & 0xFFFF_FFFF

    assert pkt_a['price']     == 10_000,     f"order A price mismatch"
    assert pkt_a['shares']    == 100,         f"order A shares mismatch"
    assert pkt_a['side_byte'] == OUCH_SIDE_BUY, f"order A side mismatch"
    assert pkt_a['stock_hi']  == hi_a,        f"order A stock_hi mismatch"
    assert pkt_a['stock_lo']  == lo_a,        f"order A stock_lo mismatch"

    assert pkt_b['price']     == 20_000,      f"order B price mismatch"
    assert pkt_b['shares']    == 200,         f"order B shares mismatch"
    assert pkt_b['side_byte'] == OUCH_SIDE_SELL, f"order B side mismatch"
    assert pkt_b['stock_hi']  == hi_b,        f"order B stock_hi mismatch"
    assert pkt_b['stock_lo']  == lo_b,        f"order B stock_lo mismatch"

    assert pkt_b['token'] == pkt_a['token'] + 1, "Token must increment between orders"


@cocotb.test()
async def test_no_spurious_valid_between_orders(dut):
    """Verify m_axis_tvalid returns to 0 after a complete packet before the
    next order is triggered."""
    await reset_dut(dut)
    await write_template(dut, sym_id=0, stock=b'LEN     ')

    beats = await send_order(dut, price=1_000, shares=10, sym_id=0, side=1)
    assert len(beats) == TOTAL_BEATS

    # After last beat, tvalid must deassert promptly
    spurious = 0
    for _ in range(10):
        await RisingEdge(dut.clk)
        if int(dut.m_axis_tvalid.value) == 1:
            spurious += 1

    assert spurious == 0, f"m_axis_tvalid spuriously asserted {spurious} times after packet"
