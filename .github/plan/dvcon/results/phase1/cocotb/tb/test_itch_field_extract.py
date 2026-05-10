"""cocotb tests for itch_field_extract.

Each test runs a self-contained scenario. A scoreboard runs in a parallel
coroutine and checks every output field on every rising clock edge.
"""

import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ReadOnly, Timer

from reference_model import (
    ITCH_LEN,
    ITCH_MSG_ADD_ORDER,
    SIDE_BUY_BYTE,
    pack_msg,
    reference,
    reset_outputs,
    make_add_order,
    make_other,
)
from scoreboard import Scoreboard


CLK_PERIOD_NS = 10


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, unit="ns").start())


async def apply_reset(dut, sb, cycles=3):
    """Drive synchronous reset for `cycles` clocks; queue reset outputs."""
    dut.rst.value = 1
    dut.msg_valid.value = 0
    dut.msg_data.value = 0
    for _ in range(cycles):
        # The expected outputs latched on this rising edge are the reset values
        sb.expect(reset_outputs())
        await RisingEdge(dut.clk)
    dut.rst.value = 0


def drive_inputs(dut, msg_bytes, msg_valid):
    """Set msg_data / msg_valid combinationally for the upcoming clock edge."""
    dut.msg_data.value = pack_msg(msg_bytes)
    dut.msg_valid.value = 1 if msg_valid else 0


async def step(dut, sb, msg_bytes, msg_valid):
    """Drive one clock of inputs and queue the matching expected output."""
    drive_inputs(dut, msg_bytes, msg_valid)
    sb.expect(reference(msg_bytes, msg_valid))
    await RisingEdge(dut.clk)


async def drain(dut, cycles=2):
    """Let the scoreboard catch up after the last queued expect."""
    for _ in range(cycles):
        await RisingEdge(dut.clk)


async def common_setup(dut):
    """Start clock, build scoreboard, drive reset, return scoreboard."""
    await start_clock(dut)
    sb = Scoreboard(dut)
    cocotb.start_soon(sb.run())
    # Initial idle settle so the scoreboard task is alive before reset.
    await Timer(1, unit="ns")
    await apply_reset(dut, sb, cycles=3)
    return sb


# ------------------------------------------------------------------
# Tests
# ------------------------------------------------------------------


@cocotb.test()
async def test_reset_clears_outputs(dut):
    """Synchronous reset must drive every output to 0 on the next clock."""
    await start_clock(dut)
    sb = Scoreboard(dut)
    cocotb.start_soon(sb.run())
    await Timer(1, unit="ns")

    # First exercise some non-zero state combinationally...
    msg = make_add_order(
        order_ref=0xDEADBEEFCAFEBABE,
        side_byte=SIDE_BUY_BYTE,
        shares=100,
        stock=b"AAPL    ",
        price=0x12345678,
    )
    dut.rst.value = 0
    drive_inputs(dut, msg, msg_valid=1)
    sb.expect(reference(msg, True))
    await RisingEdge(dut.clk)

    # ...then assert reset and confirm outputs go to 0.
    dut.rst.value = 1
    dut.msg_valid.value = 0
    dut.msg_data.value = 0
    for _ in range(4):
        sb.expect(reset_outputs())
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    # Drain one more cycle so the scoreboard has time to compare.
    await RisingEdge(dut.clk)
    assert sb.checked >= 5, sb.summary()
    assert not sb.errors, sb.summary()


@cocotb.test()
async def test_add_order_buy(dut):
    """Single Add Order, buy side (0x42)."""
    sb = await common_setup(dut)

    msg = make_add_order(
        order_ref=0x0123456789ABCDEF,
        side_byte=SIDE_BUY_BYTE,
        shares=250,
        stock=b"MSFT    ",
        price=0x000186A0,  # 100.0 in fixed-point /10000
    )
    await step(dut, sb, msg, msg_valid=True)
    # idle one cycle to drain the pipeline
    await step(dut, sb, bytes(ITCH_LEN), msg_valid=False)
    await drain(dut)

    assert sb.checked >= 5, sb.summary()
    assert not sb.errors, sb.summary()


@cocotb.test()
async def test_add_order_sell(dut):
    """Single Add Order, sell side (0x53='S')."""
    sb = await common_setup(dut)

    msg = make_add_order(
        order_ref=0xFEEDFACECAFEF00D,
        side_byte=0x53,  # 'S'
        shares=999,
        stock=b"GOOG    ",
        price=0xDEADBEEF,
    )
    await step(dut, sb, msg, msg_valid=True)
    await step(dut, sb, bytes(ITCH_LEN), msg_valid=False)

    assert not sb.errors, sb.summary()


@cocotb.test()
async def test_add_order_side_byte_other_than_B(dut):
    """side must be 0 for any byte 19 != 0x42 (not just 'S')."""
    sb = await common_setup(dut)
    for sb_byte in (0x00, 0x20, 0x41, 0x43, 0x53, 0xFF):
        msg = make_add_order(
            order_ref=0xAABB_CCDD_EEFF_1122,
            side_byte=sb_byte,
            stock=b"TSLA    ",
            price=0x10000000,
        )
        await step(dut, sb, msg, msg_valid=True)
    await step(dut, sb, bytes(ITCH_LEN), msg_valid=False)
    await drain(dut)
    assert sb.checked > 0, sb.summary()
    assert not sb.errors, sb.summary()


@cocotb.test()
async def test_non_add_order_message_types(dut):
    """fields_valid must remain 0 for any message_type other than 0x41."""
    sb = await common_setup(dut)

    other_types = [
        0x00,
        0x40,  # one below 'A'
        0x42,  # 'B'
        0x46,  # 'F' Add Order MPID
        0x44,  # 'D' Order Delete
        0x55,  # 'U' Order Replace
        0x45,  # 'E' Order Exec
        0x43,  # 'C' Order Exec with price
        0x50,  # 'P' Trade
        0x58,  # 'X' Order Cancel
        0xFF,
    ]
    for i, t in enumerate(other_types):
        msg = make_other(t, payload_seed=i * 13)
        await step(dut, sb, msg, msg_valid=True)
    await step(dut, sb, bytes(ITCH_LEN), msg_valid=False)
    await drain(dut)
    assert sb.checked > 0, sb.summary()
    assert not sb.errors, sb.summary()


@cocotb.test()
async def test_msg_valid_low(dut):
    """fields_valid must remain 0 when msg_valid=0, even with 'A' bytes on bus."""
    sb = await common_setup(dut)

    msg = make_add_order(
        order_ref=0x1111_2222_3333_4444,
        side_byte=SIDE_BUY_BYTE,
        stock=b"AAPL    ",
        price=0xCAFEBABE,
    )
    # Drive an Add Order body but keep msg_valid=0.
    for _ in range(5):
        await step(dut, sb, msg, msg_valid=False)
    # Then quickly drive valid to confirm the path still wakes up.
    await step(dut, sb, msg, msg_valid=True)
    await step(dut, sb, bytes(ITCH_LEN), msg_valid=False)
    await drain(dut)
    assert sb.checked > 0, sb.summary()
    assert not sb.errors, sb.summary()


@cocotb.test()
async def test_back_to_back_valid_messages(dut):
    """msg_valid stays high for many consecutive cycles with varying data."""
    sb = await common_setup(dut)

    rng = random.Random(0xC0CDA)
    n = 32
    for i in range(n):
        side_byte = SIDE_BUY_BYTE if (i % 2 == 0) else 0x53
        msg = make_add_order(
            order_ref=rng.getrandbits(64),
            side_byte=side_byte,
            shares=rng.getrandbits(32),
            stock=bytes(rng.randint(0x41, 0x5A) for _ in range(8)),
            price=rng.getrandbits(32),
            stock_locate=rng.getrandbits(16),
            tracking_number=rng.getrandbits(16),
            timestamp=rng.getrandbits(48),
        )
        await step(dut, sb, msg, msg_valid=True)
    # one trailing idle cycle to drain the pipeline
    await step(dut, sb, bytes(ITCH_LEN), msg_valid=False)
    await drain(dut)
    assert sb.checked >= n, sb.summary()
    assert not sb.errors, sb.summary()


@cocotb.test()
async def test_mixed_random_stream(dut):
    """Random mix of Add Order, other types, and idle cycles."""
    sb = await common_setup(dut)
    rng = random.Random(0x5EED_F00D)

    for _ in range(80):
        kind = rng.choice(["addB", "addS", "addX", "other", "idle"])
        if kind == "addB":
            msg = make_add_order(
                order_ref=rng.getrandbits(64),
                side_byte=SIDE_BUY_BYTE,
                shares=rng.getrandbits(32),
                stock=bytes(rng.randint(0x41, 0x5A) for _ in range(8)),
                price=rng.getrandbits(32),
            )
            valid = True
        elif kind == "addS":
            msg = make_add_order(
                order_ref=rng.getrandbits(64),
                side_byte=0x53,
                shares=rng.getrandbits(32),
                stock=bytes(rng.randint(0x41, 0x5A) for _ in range(8)),
                price=rng.getrandbits(32),
            )
            valid = True
        elif kind == "addX":
            # Add Order with a non-B/S indicator — fields_valid still 1
            # because message_type is 'A'; side must be 0.
            msg = make_add_order(
                order_ref=rng.getrandbits(64),
                side_byte=rng.choice([0x00, 0x20, 0x41, 0x43, 0xFF]),
                shares=rng.getrandbits(32),
                stock=bytes(rng.randint(0x41, 0x5A) for _ in range(8)),
                price=rng.getrandbits(32),
            )
            valid = True
        elif kind == "other":
            msg = make_other(rng.choice([0x44, 0x45, 0x46, 0x50, 0x55, 0x58]),
                             payload_seed=rng.getrandbits(16))
            valid = True
        else:  # idle
            msg = bytes(rng.randint(0, 255) for _ in range(ITCH_LEN))
            valid = False
        await step(dut, sb, msg, msg_valid=valid)

    await step(dut, sb, bytes(ITCH_LEN), msg_valid=False)
    await drain(dut)
    assert sb.checked > 0, sb.summary()
    assert not sb.errors, sb.summary()


@cocotb.test()
async def test_reset_during_traffic(dut):
    """Reset asserted while a valid message is being driven clears the pipe."""
    sb = await common_setup(dut)

    msg = make_add_order(
        order_ref=0xAAAA_BBBB_CCCC_DDDD,
        side_byte=SIDE_BUY_BYTE,
        stock=b"NVDA    ",
        price=0x11223344,
    )
    # one valid cycle
    await step(dut, sb, msg, msg_valid=True)
    # assert reset, hold for 2 cycles; outputs latched at those edges go to 0
    dut.rst.value = 1
    dut.msg_valid.value = 1  # keep msg_valid high to prove reset wins
    dut.msg_data.value = pack_msg(msg)
    for _ in range(2):
        sb.expect(reset_outputs())
        await RisingEdge(dut.clk)
    dut.rst.value = 0

    # Resume normal traffic
    await step(dut, sb, msg, msg_valid=True)
    await step(dut, sb, bytes(ITCH_LEN), msg_valid=False)
    await drain(dut)
    assert sb.checked > 0, sb.summary()
    assert not sb.errors, sb.summary()
