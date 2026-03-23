"""Tests for itch_parser — ITCH message parsing and field extraction."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
from drivers.axi4_stream_driver import AXI4StreamDriver
from utils.itch_decoder import encode_add_order, encode_system_event
from checkers.axi4_stream_checker import AXI4StreamChecker
from checkers.parser_checker import ParserChecker


async def reset_dut(dut):
    """Apply reset for 5 cycles."""
    dut.rst.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tlast.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def wait_for_fields_valid(dut, timeout=50):
    """Wait up to `timeout` cycles for fields_valid to assert."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.fields_valid.value == 1:
            return True
    return False


async def wait_for_msg_valid(dut, timeout=50):
    """Wait up to `timeout` cycles for msg_valid to assert."""
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.msg_valid.value == 1:
            return True
    return False


@cocotb.test()
async def test_single_add_order(dut):
    """Encode one Add Order, send via AXI4-Stream, verify extracted fields."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    # Start protocol checkers
    stream_chk = AXI4StreamChecker(dut)
    parser_chk = ParserChecker(dut)
    await stream_chk.start()
    await parser_chk.start()

    driver = AXI4StreamDriver(dut)

    # Known values
    expected_order_ref = 0x0000000012345678
    expected_side = 'B'
    expected_price = 150000  # $15.0000 (4 implied decimals)

    msg = encode_add_order(
        order_ref=expected_order_ref,
        side=expected_side,
        price=expected_price,
        stock="AAPL    ",
    )

    # Send message
    cocotb.start_soon(driver.send(msg))

    # Wait for fields_valid
    found = await wait_for_fields_valid(dut)
    assert found, "fields_valid never asserted"

    # Check extracted fields
    got_type = int(dut.message_type.value)
    got_ref = int(dut.order_ref.value)
    got_side = int(dut.side.value)
    got_price = int(dut.price.value)

    dut._log.info(f"message_type=0x{got_type:02x}, order_ref=0x{got_ref:016x}, "
                  f"side={got_side}, price={got_price}")

    assert got_type == 0x41, f"Expected message_type 0x41, got 0x{got_type:02x}"
    assert got_ref == expected_order_ref, \
        f"order_ref mismatch: got 0x{got_ref:016x}, expected 0x{expected_order_ref:016x}"
    assert got_side == 1, f"Expected side=1 (buy), got {got_side}"
    assert got_price == expected_price, \
        f"price mismatch: got {got_price}, expected {expected_price}"

    dut._log.info(stream_chk.report())
    dut._log.info(parser_chk.report())
    dut._log.info("PASS: single Add Order correctly parsed")


@cocotb.test()
async def test_multi_beat_message(dut):
    """Add Order spanning 5 AXI beats (38 bytes with length prefix)."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    stream_chk = AXI4StreamChecker(dut)
    parser_chk = ParserChecker(dut)
    await stream_chk.start()
    await parser_chk.start()

    driver = AXI4StreamDriver(dut)

    # Use distinctive values to catch byte-lane errors
    expected_order_ref = 0xDEADBEEFCAFEBABE
    expected_side = 'S'
    expected_price = 999999

    msg = encode_add_order(
        order_ref=expected_order_ref,
        side=expected_side,
        price=expected_price,
        stock="TSLA    ",
        shares=200,
    )

    # Verify message is multi-beat (38 bytes → 5 beats)
    assert len(msg) == 38, f"Expected 38-byte message, got {len(msg)}"

    cocotb.start_soon(driver.send(msg))
    found = await wait_for_fields_valid(dut)
    assert found, "fields_valid never asserted for multi-beat message"

    got_ref = int(dut.order_ref.value)
    got_side = int(dut.side.value)
    got_price = int(dut.price.value)

    assert got_ref == expected_order_ref, \
        f"order_ref mismatch: got 0x{got_ref:016x}, expected 0x{expected_order_ref:016x}"
    assert got_side == 0, f"Expected side=0 (sell), got {got_side}"
    assert got_price == expected_price, \
        f"price mismatch: got {got_price}, expected {expected_price}"

    dut._log.info(stream_chk.report())
    dut._log.info(parser_chk.report())
    dut._log.info("PASS: multi-beat Add Order correctly parsed")


@cocotb.test()
async def test_non_add_order_passthrough(dut):
    """Send a System Event ('S') message, verify parser discards it."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    stream_chk = AXI4StreamChecker(dut)
    parser_chk = ParserChecker(dut)
    await stream_chk.start()
    await parser_chk.start()

    driver = AXI4StreamDriver(dut)

    msg = encode_system_event(event_code='O')

    cocotb.start_soon(driver.send(msg))

    # msg_valid should fire (message was received) but fields_valid should NOT
    found_msg = await wait_for_msg_valid(dut)
    assert found_msg, "msg_valid never asserted for System Event"

    # fields_valid should be 0 in this same cycle (msg_valid is combinational from state)
    assert dut.fields_valid.value == 0, \
        "fields_valid should NOT assert for non-Add-Order message"

    dut._log.info(stream_chk.report())
    dut._log.info(parser_chk.report())
    dut._log.info("PASS: non-Add-Order message correctly discarded")


@cocotb.test()
async def test_back_to_back_messages(dut):
    """Two Add Orders in rapid succession, verify both parsed correctly."""
    clock = Clock(dut.clk, 10, unit='ns')
    cocotb.start_soon(clock.start())
    await reset_dut(dut)

    stream_chk = AXI4StreamChecker(dut)
    parser_chk = ParserChecker(dut)
    await stream_chk.start()
    await parser_chk.start()

    driver = AXI4StreamDriver(dut)

    messages = [
        {'order_ref': 0x1111111111111111, 'side': 'B', 'price': 100000},
        {'order_ref': 0x2222222222222222, 'side': 'S', 'price': 200000},
    ]

    for idx, m in enumerate(messages):
        msg = encode_add_order(
            order_ref=m['order_ref'],
            side=m['side'],
            price=m['price'],
        )

        cocotb.start_soon(driver.send(msg))
        found = await wait_for_fields_valid(dut)
        assert found, f"fields_valid never asserted for message {idx}"

        got_ref = int(dut.order_ref.value)
        got_side = int(dut.side.value)
        got_price = int(dut.price.value)

        expected_side_val = 1 if m['side'] == 'B' else 0

        assert got_ref == m['order_ref'], \
            f"Msg {idx}: order_ref mismatch: got 0x{got_ref:016x}"
        assert got_side == expected_side_val, \
            f"Msg {idx}: side mismatch: got {got_side}"
        assert got_price == m['price'], \
            f"Msg {idx}: price mismatch: got {got_price}"

        dut._log.info(f"Message {idx}: PASS")

    dut._log.info(stream_chk.report())
    dut._log.info(parser_chk.report())
    dut._log.info("PASS: back-to-back Add Orders correctly parsed")
