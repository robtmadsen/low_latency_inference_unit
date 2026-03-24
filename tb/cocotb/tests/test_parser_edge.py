"""Coverage-targeted edge-case tests for itch_parser.sv and itch_field_extract.sv.

Targets gaps in:
  - Message length boundary conditions (msg_len = 1..6, 7, 8, exactly 14, etc.)
  - Back-to-back messages with zero idle cycles
  - Non-Add-Order message types (should be parsed but not extract fields)
  - Truncated messages during ACCUMULATE (tlast early)
  - Short (single-beat) messages that fit in first beat
  - Large multi-beat messages
"""

import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from drivers.axi4_stream_driver import AXI4StreamDriver
from utils.itch_decoder import encode_add_order, encode_system_event, ADD_ORDER_LEN


async def reset_dut(dut):
    dut.rst.value = 1
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tdata.value = 0
    dut.s_axis_tlast.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def wait_for_msg_valid(dut, timeout=100):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.msg_valid.value == 1:
            return True
    return False


async def wait_for_fields_valid(dut, timeout=100):
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if dut.fields_valid.value == 1:
            return True
    return False


def make_short_message(body_len, msg_type=0x53):
    """Build a message with given body length (fits in first beat if <= 6)."""
    body = bytearray(body_len)
    body[0] = msg_type
    for i in range(1, body_len):
        body[i] = i & 0xFF
    return struct.pack('>H', body_len) + bytes(body)


def make_raw_message(body_len, msg_type=0x41):
    """Build a message with arbitrary body length and given type."""
    body = bytearray(body_len)
    body[0] = msg_type
    for i in range(1, body_len):
        body[i] = (i * 7) & 0xFF
    return struct.pack('>H', body_len) + bytes(body)


async def send_raw_beats(dut, data_bytes):
    """Send raw bytes as AXI4-Stream beats, 8 bytes per beat, big-endian."""
    padded = data_bytes + b'\x00' * ((8 - len(data_bytes) % 8) % 8)
    num_beats = len(padded) // 8
    for i in range(num_beats):
        beat = int.from_bytes(padded[i*8:(i+1)*8], byteorder='big')
        is_last = (i == num_beats - 1)
        dut.s_axis_tdata.value = beat
        dut.s_axis_tvalid.value = 1
        dut.s_axis_tlast.value = int(is_last)
        while True:
            await RisingEdge(dut.clk)
            if dut.s_axis_tready.value == 1:
                break
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0


# ================================================================
# Test: minimum-length message (body_len=1, fits in first beat)
# ================================================================
@cocotb.test()
async def test_min_length_message(dut):
    """Message with body_len=1 — should complete in S_IDLE→S_EMIT."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    msg = make_short_message(body_len=1, msg_type=0x53)
    cocotb.start_soon(send_raw_beats(dut, msg))

    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid never asserted for min-length message"
    assert dut.fields_valid.value == 0, "fields_valid should NOT assert for non-Add-Order"
    dut._log.info("PASS: min-length message (body_len=1)")


# ================================================================
# Test: body_len exactly 6 (boundary: fits entirely in first beat)
# ================================================================
@cocotb.test()
async def test_body_len_exactly_6(dut):
    """body_len=6 is the threshold for single-beat completion."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    msg = make_short_message(body_len=6)
    cocotb.start_soon(send_raw_beats(dut, msg))

    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid never asserted for body_len=6"
    dut._log.info("PASS: body_len=6 (single-beat boundary)")


# ================================================================
# Test: body_len=7 — requires exactly one more beat in ACCUMULATE
# ================================================================
@cocotb.test()
async def test_body_len_7(dut):
    """body_len=7 needs 1 extra beat after the first (6 bytes in first beat)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    msg = make_raw_message(body_len=7)
    cocotb.start_soon(send_raw_beats(dut, msg))

    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid never asserted for body_len=7"
    dut._log.info("PASS: body_len=7 (one extra beat)")


# ================================================================
# Test: body_len=8 — boundary: 6+8=14 >= 8, complete after one ACCUMULATE beat
# ================================================================
@cocotb.test()
async def test_body_len_8(dut):
    """body_len=8 completes after first beat in ACCUMULATE."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    msg = make_raw_message(body_len=8)
    cocotb.start_soon(send_raw_beats(dut, msg))

    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid never asserted for body_len=8"
    dut._log.info("PASS: body_len=8 (ACCUMULATE boundary)")


# ================================================================
# Test: body_len=14 — boundary: 6+8=14 exactly equals msg_len
# ================================================================
@cocotb.test()
async def test_body_len_14(dut):
    """body_len=14 exactly fills two beats (6 + 8 = 14)."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    msg = make_raw_message(body_len=14)
    cocotb.start_soon(send_raw_beats(dut, msg))

    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid never asserted for body_len=14"
    dut._log.info("PASS: body_len=14 (exact two-beat boundary)")


# ================================================================
# Test: truncated in IDLE (tlast with long declared length)
# ================================================================
@cocotb.test()
async def test_truncated_in_idle(dut):
    """Declare long message but only send one beat with tlast — should discard."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    # Declare body_len=36 but send single beat with tlast
    data = struct.pack('>H', 36) + bytes(6)  # length prefix + 6 bytes
    dut.s_axis_tdata.value = int.from_bytes(data, byteorder='big')
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tlast.value = 1
    await RisingEdge(dut.clk)
    while dut.s_axis_tready.value != 1:
        await RisingEdge(dut.clk)
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0

    # Should NOT emit — msg_valid should stay low
    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.msg_valid.value == 1:
            raise AssertionError("msg_valid asserted for truncated-in-IDLE message")

    # Now send a valid message to confirm parser recovered
    valid_msg = encode_add_order(order_ref=0xABCD, side='B', price=100)
    cocotb.start_soon(send_raw_beats(dut, valid_msg))
    found = await wait_for_fields_valid(dut)
    assert found, "Parser did not recover after truncated message"
    dut._log.info("PASS: truncated in IDLE, parser recovered")


# ================================================================
# Test: truncated in ACCUMULATE (tlast before message complete)
# ================================================================
@cocotb.test()
async def test_truncated_in_accumulate(dut):
    """Send two beats for a 36-byte message then tlast — should discard."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    # Build partial data: length prefix says 36, but we only send 2 beats (14 bytes)
    body = bytearray(14)
    body[0] = 0x41  # Add Order type
    data = struct.pack('>H', 36) + bytes(body)
    padded = data + b'\x00' * ((8 - len(data) % 8) % 8)

    # Send beat 1 (no tlast)
    beat1 = int.from_bytes(padded[0:8], byteorder='big')
    dut.s_axis_tdata.value = beat1
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tlast.value = 0
    while True:
        await RisingEdge(dut.clk)
        if dut.s_axis_tready.value == 1:
            break

    # Send beat 2 (with tlast — truncated!)
    beat2 = int.from_bytes(padded[8:16], byteorder='big')
    dut.s_axis_tdata.value = beat2
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tlast.value = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.s_axis_tready.value == 1:
            break

    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0

    # Should NOT produce fields_valid (message was truncated)
    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.fields_valid.value == 1:
            raise AssertionError("fields_valid asserted for truncated message")

    # Recovery: send a valid message
    valid_msg = encode_add_order(order_ref=0x1234, side='S', price=50000)
    cocotb.start_soon(send_raw_beats(dut, valid_msg))
    found = await wait_for_fields_valid(dut)
    assert found, "Parser did not recover after truncated ACCUMULATE"
    dut._log.info("PASS: truncated in ACCUMULATE, parser recovered")


# ================================================================
# Test: back-to-back messages with no idle cycles
# ================================================================
@cocotb.test()
async def test_back_to_back_no_idle(dut):
    """Send 5 Add Orders back-to-back, verify all parsed correctly."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    driver = AXI4StreamDriver(dut)
    prices = [10000, 20000, 30000, 40000, 50000]
    sides = ['B', 'S', 'B', 'S', 'B']

    for idx, (p, s) in enumerate(zip(prices, sides)):
        msg = encode_add_order(order_ref=idx + 1, side=s, price=p)
        cocotb.start_soon(driver.send(msg))
        found = await wait_for_fields_valid(dut)
        assert found, f"fields_valid not asserted for message {idx}"
        got_price = int(dut.price.value)
        got_side = int(dut.side.value)
        assert got_price == p, f"Msg {idx}: price {got_price} != {p}"
        expected_side = 1 if s == 'B' else 0
        assert got_side == expected_side, f"Msg {idx}: side {got_side} != {expected_side}"

    dut._log.info("PASS: 5 back-to-back messages, no idle")


# ================================================================
# Test: multiple non-Add-Order types (should parse but not extract)
# ================================================================
@cocotb.test()
async def test_multiple_non_add_order_types(dut):
    """Send System Event, then custom types — none should assert fields_valid."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    # System Event ('S'), body=12 bytes — multi-beat
    se_msg = encode_system_event(event_code='O')
    cocotb.start_soon(send_raw_beats(dut, se_msg))
    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid not asserted for System Event"
    assert dut.fields_valid.value == 0, "fields_valid should not assert for System Event"

    # Custom short message type 0x44 ('D' = Delete), body_len=5
    del_msg = make_short_message(body_len=5, msg_type=0x44)
    cocotb.start_soon(send_raw_beats(dut, del_msg))
    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid not asserted for Delete msg"
    assert dut.fields_valid.value == 0, "fields_valid should not assert for Delete"

    # Custom message type 0x55 ('U' = Replace), body_len=20
    rep_msg = make_raw_message(body_len=20, msg_type=0x55)
    cocotb.start_soon(send_raw_beats(dut, rep_msg))
    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid not asserted for Replace msg"
    assert dut.fields_valid.value == 0, "fields_valid should not assert for Replace"

    dut._log.info("PASS: multiple non-Add-Order message types discarded correctly")


# ================================================================
# Test: maximum-length message (fills buffer)
# ================================================================
@cocotb.test()
async def test_max_length_message(dut):
    """Send a 120-byte message (near buffer limit) — should complete."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    msg = make_raw_message(body_len=120, msg_type=0x53)
    cocotb.start_soon(send_raw_beats(dut, msg))

    found = await wait_for_msg_valid(dut)
    assert found, "msg_valid never asserted for max-length message"
    assert dut.fields_valid.value == 0, "Non-Add-Order should not set fields_valid"
    dut._log.info("PASS: max-length message (120 bytes)")


# ================================================================
# Test: interleaved valid and invalid messages
# ================================================================
@cocotb.test()
async def test_valid_invalid_interleave(dut):
    """Send: valid → truncated → valid → non-Add → valid. All valids must parse."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    driver = AXI4StreamDriver(dut)

    # 1. Valid Add Order
    msg1 = encode_add_order(order_ref=0x100, side='B', price=1000)
    cocotb.start_soon(driver.send(msg1))
    assert await wait_for_fields_valid(dut), "Msg 1 not parsed"
    assert int(dut.price.value) == 1000

    # 2. Truncated message (single beat with tlast, declares 36)
    data = struct.pack('>H', 36) + bytes(6)
    dut.s_axis_tdata.value = int.from_bytes(data, byteorder='big')
    dut.s_axis_tvalid.value = 1
    dut.s_axis_tlast.value = 1
    while True:
        await RisingEdge(dut.clk)
        if dut.s_axis_tready.value == 1:
            break
    dut.s_axis_tvalid.value = 0
    dut.s_axis_tlast.value = 0
    for _ in range(5):
        await RisingEdge(dut.clk)

    # 3. Valid Add Order (recovery check)
    msg3 = encode_add_order(order_ref=0x200, side='S', price=2000)
    cocotb.start_soon(driver.send(msg3))
    assert await wait_for_fields_valid(dut), "Msg 3 not parsed after truncation"
    assert int(dut.price.value) == 2000

    # 4. Non-Add-Order
    se_msg = encode_system_event(event_code='C')
    cocotb.start_soon(driver.send(se_msg))
    assert await wait_for_msg_valid(dut), "System Event not parsed"

    # 5. Valid Add Order
    msg5 = encode_add_order(order_ref=0x300, side='B', price=3000)
    cocotb.start_soon(driver.send(msg5))
    assert await wait_for_fields_valid(dut), "Msg 5 not parsed after non-Add-Order"
    assert int(dut.price.value) == 3000

    dut._log.info("PASS: interleaved valid/invalid message sequence")


# ================================================================
# Test: boundary prices (0 and max uint32)
# ================================================================
@cocotb.test()
async def test_boundary_prices(dut):
    """Exercise price=0 and price=0xFFFFFFFF to toggle all price bits."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    driver = AXI4StreamDriver(dut)

    for price in [0, 0xFFFFFFFF]:
        msg = encode_add_order(order_ref=0xAAAA, side='B', price=price)
        cocotb.start_soon(driver.send(msg))
        found = await wait_for_fields_valid(dut)
        assert found, f"fields_valid not asserted for price={price:#x}"
        got = int(dut.price.value)
        assert got == price, f"Price mismatch: got {got:#x}, expected {price:#x}"

    dut._log.info("PASS: boundary prices (0 and 0xFFFFFFFF)")


# ================================================================
# Test: boundary order_ref values
# ================================================================
@cocotb.test()
async def test_boundary_order_refs(dut):
    """Exercise order_ref=0, order_ref=max to toggle all ref bits."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    driver = AXI4StreamDriver(dut)

    for ref in [0, 0xFFFFFFFFFFFFFFFF]:
        msg = encode_add_order(order_ref=ref, side='S', price=5000)
        cocotb.start_soon(driver.send(msg))
        found = await wait_for_fields_valid(dut)
        assert found, f"fields_valid not asserted for ref={ref:#x}"
        got = int(dut.order_ref.value)
        assert got == ref, f"order_ref mismatch: got {got:#018x}, expected {ref:#018x}"

    dut._log.info("PASS: boundary order_ref values")
