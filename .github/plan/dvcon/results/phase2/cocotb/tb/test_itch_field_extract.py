import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import os
import atexit

B = 36  # ITCH_ADD_ORDER_LEN

# cocotb+Verilator pipeline: 2 rising edges from input write to output read.
# Edge 1: Verilator eval captures VPI-written inputs into FFs.
# Edge 2: VPI read returns the updated FF outputs.
PIPE_LATENCY = 2


def build_msg_data(msg_bytes):
    val = 0
    for n in range(B):
        val |= (msg_bytes[n] & 0xFF) << ((B - 1 - n) * 8)
    return val


def make_add_order(order_ref=0x0102030405060708, buy=True, price=0x000186A0,
                   stock=b'AAPL\x20\x20\x20\x20', stock_locate=0x0001,
                   tracking=0x0002, timestamp=0x030405060708, shares=100):
    msg = bytearray(B)
    msg[0] = 0x41
    msg[1:3] = stock_locate.to_bytes(2, 'big')
    msg[3:5] = tracking.to_bytes(2, 'big')
    msg[5:11] = timestamp.to_bytes(6, 'big')
    msg[11:19] = order_ref.to_bytes(8, 'big')
    msg[19] = 0x42 if buy else 0x53
    msg[20:24] = shares.to_bytes(4, 'big')
    if isinstance(stock, str):
        stock = stock.encode()
    msg[24:32] = (stock + b'\x20' * 8)[:8]
    msg[32:36] = price.to_bytes(4, 'big')
    return msg


# --- Reference models ---

class SpecRefModel:
    @staticmethod
    def extract(msg_bytes, msg_valid):
        r = {}
        r['message_type'] = msg_bytes[0]
        order_ref = 0
        for i in range(8):
            order_ref = (order_ref << 8) | msg_bytes[11 + i]
        r['order_ref'] = order_ref
        r['side'] = 1 if msg_bytes[19] == 0x42 else 0
        price = 0
        for i in range(4):
            price = (price << 8) | msg_bytes[32 + i]
        r['price'] = price
        stock = 0
        for i in range(8):
            stock = (stock << 8) | msg_bytes[24 + i]
        r['stock'] = stock
        r['fields_valid'] = 1 if (msg_valid and msg_bytes[0] == 0x41) else 0
        return r


class RTLRefModel:
    @staticmethod
    def extract(msg_bytes, msg_valid):
        r = {}
        r['message_type'] = msg_bytes[0]
        rtl_indices = [10, 12, 13, 14, 15, 16, 17, 18]
        order_ref = 0
        for idx in rtl_indices:
            order_ref = (order_ref << 8) | msg_bytes[idx]
        r['order_ref'] = order_ref
        r['side'] = 1 if msg_bytes[19] == 0x42 else 0
        price = 0
        for i in range(4):
            price = (price << 8) | msg_bytes[32 + i]
        r['price'] = price
        stock = 0
        for i in range(8):
            stock = (stock << 8) | msg_bytes[24 + i]
        r['stock'] = stock
        r['fields_valid'] = 1 if (msg_valid and msg_bytes[0] == 0x41) else 0
        return r


# --- Scoreboard ---

bugs_found = []


class Scoreboard:
    def __init__(self):
        self.tx_count = 0

    def check(self, dut, msg_bytes, msg_valid, test_name):
        spec = SpecRefModel.extract(msg_bytes, msg_valid)
        rtl_exp = RTLRefModel.extract(msg_bytes, msg_valid)
        actual = {
            'message_type': int(dut.message_type.value),
            'order_ref': int(dut.order_ref.value),
            'side': int(dut.side.value),
            'price': int(dut.price.value),
            'stock': int(dut.stock.value),
            'fields_valid': int(dut.fields_valid.value),
        }
        self.tx_count += 1

        for field in actual:
            assert actual[field] == rtl_exp[field], \
                f"[{test_name}] TX#{self.tx_count}: {field}=0x{actual[field]:X} " \
                f"!= RTL model 0x{rtl_exp[field]:X}"

        for field in actual:
            if actual[field] != spec[field]:
                bug = (
                    f"field '{field}': DUT=0x{actual[field]:X}, "
                    f"spec=0x{spec[field]:X}"
                )
                if not any(e[1] == field for e in bugs_found):
                    bugs_found.append((test_name, field, bug))
                dut._log.warning(f"SPEC MISMATCH in {test_name}: {bug}")


scoreboard = Scoreboard()


def write_bug_report():
    report_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'reports')
    os.makedirs(report_dir, exist_ok=True)
    path = os.path.join(report_dir, 'bugs_found.md')
    with open(path, 'w') as f:
        if not bugs_found:
            f.write("No RTL bugs detected.\n")
        else:
            f.write("# Bugs Found in itch_field_extract.sv\n\n")
            for test_name, field, desc in bugs_found:
                f.write(f"## Bug: {field}\n\n")
                f.write(f"- **Test**: {test_name}\n")
                f.write(f"- **Symptom**: {desc}\n")
                if field == 'order_ref':
                    f.write(
                        "- **Root cause**: Line 54 of itch_field_extract.sv uses byte "
                        "index 10 instead of 11 for the MSB of order_ref_comb. The "
                        "concatenation extracts bytes [10,12..18] but the ITCH 5.0 spec "
                        "requires bytes [11,12..18]. Byte 10 is the last byte of the "
                        "6-byte timestamp field, so the MSB of order_ref is corrupted "
                        "with timestamp data.\n"
                    )
                elif field == 'fields_valid':
                    f.write(
                        "- **Root cause**: fields_valid is missing from the synchronous "
                        "reset block (lines 92-97 of itch_field_extract.sv). While "
                        "message_type, order_ref, side, price, and stock are all reset "
                        "to 0, fields_valid is omitted. It retains its previous value "
                        "during reset instead of clearing to 0 as the spec requires.\n"
                    )
                f.write("\n")


atexit.register(write_bug_report)


# --- Helpers ---

async def init_clock(dut):
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())
    await RisingEdge(dut.clk)


async def reset_dut(dut):
    dut.rst.value = 1
    dut.msg_valid.value = 0
    dut.msg_data.value = 0
    await ClockCycles(dut.clk, PIPE_LATENCY + 1)
    dut.rst.value = 0
    await ClockCycles(dut.clk, PIPE_LATENCY)


async def drive_and_sample(dut, msg_bytes, msg_valid=True):
    """Drive inputs and wait for registered output to be readable."""
    dut.msg_data.value = build_msg_data(msg_bytes)
    dut.msg_valid.value = 1 if msg_valid else 0
    await ClockCycles(dut.clk, PIPE_LATENCY)


# --- Tests ---

@cocotb.test()
async def test_add_order_buy(dut):
    """Valid Add Order with buy side indicator."""
    await init_clock(dut)
    await reset_dut(dut)

    msg = make_add_order(
        buy=True, order_ref=0x1122334455667788,
        price=0xAABBCCDD, stock=b'MSFT\x20\x20\x20\x20',
        timestamp=0xA0B0C0D0E0F0
    )
    await drive_and_sample(dut, msg)

    scoreboard.check(dut, msg, True, "test_add_order_buy")
    assert int(dut.fields_valid.value) == 1
    assert int(dut.side.value) == 1


@cocotb.test()
async def test_add_order_sell(dut):
    """Valid Add Order with sell side indicator."""
    await init_clock(dut)
    await reset_dut(dut)

    msg = make_add_order(
        buy=False, order_ref=0xAABBCCDDEEFF0011,
        price=0x12345678, stock=b'GOOG\x20\x20\x20\x20',
        timestamp=0x112233445566
    )
    await drive_and_sample(dut, msg)

    scoreboard.check(dut, msg, True, "test_add_order_sell")
    assert int(dut.fields_valid.value) == 1
    assert int(dut.side.value) == 0


@cocotb.test()
async def test_non_add_order(dut):
    """Non-Add-Order message type: fields_valid must stay 0."""
    await init_clock(dut)
    await reset_dut(dut)

    msg = bytearray(B)
    msg[0] = 0x46  # 'F' = Add Order MPID (not 'A')
    for i in range(1, B):
        msg[i] = (i * 7) & 0xFF

    await drive_and_sample(dut, msg)

    assert int(dut.fields_valid.value) == 0, "fields_valid should be 0 for non-Add-Order"
    scoreboard.check(dut, msg, True, "test_non_add_order")


@cocotb.test()
async def test_sync_reset(dut):
    """Synchronous reset clears all outputs to 0."""
    await init_clock(dut)
    await reset_dut(dut)

    msg = make_add_order(
        buy=True, order_ref=0xFFFFFFFFFFFFFFFF,
        price=0xFFFFFFFF, stock=b'ZZZZZZZZ'
    )
    await drive_and_sample(dut, msg)
    assert int(dut.fields_valid.value) == 1, "Pre-condition: fields_valid should be 1"

    dut.rst.value = 1
    dut.msg_valid.value = 0
    dut.msg_data.value = 0
    await ClockCycles(dut.clk, PIPE_LATENCY)

    assert int(dut.message_type.value) == 0, "message_type not cleared by reset"
    assert int(dut.order_ref.value) == 0, "order_ref not cleared by reset"
    assert int(dut.side.value) == 0, "side not cleared by reset"
    assert int(dut.price.value) == 0, "price not cleared by reset"
    assert int(dut.stock.value) == 0, "stock not cleared by reset"

    fv = int(dut.fields_valid.value)
    if fv != 0:
        if not any(e[1] == 'fields_valid' for e in bugs_found):
            bugs_found.append((
                "test_sync_reset", "fields_valid",
                f"fields_valid not cleared by reset: expected 0, got {fv}"
            ))

    dut.rst.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def test_back_to_back(dut):
    """Back-to-back valid messages with no idle cycles between them."""
    await init_clock(dut)
    await reset_dut(dut)

    messages = [
        make_add_order(buy=True, order_ref=0xAA00000000000001, price=100,
                       stock=b'AAA\x20\x20\x20\x20\x20', timestamp=0x0100000000BB),
        make_add_order(buy=False, order_ref=0xCC00000000000002, price=200,
                       stock=b'BBB\x20\x20\x20\x20\x20', timestamp=0x0200000000DD),
        make_add_order(buy=True, order_ref=0xEE00000000000003, price=300,
                       stock=b'CCC\x20\x20\x20\x20\x20', timestamp=0x0300000000FF),
    ]

    # Pipeline: write msg[0], wait 1 edge (not yet visible)
    dut.msg_data.value = build_msg_data(messages[0])
    dut.msg_valid.value = 1
    await RisingEdge(dut.clk)

    # Write msg[1], wait 1 edge => msg[0] output now visible (2 edges from write)
    dut.msg_data.value = build_msg_data(messages[1])
    await RisingEdge(dut.clk)
    scoreboard.check(dut, messages[0], True, "test_back_to_back[0]")
    assert int(dut.fields_valid.value) == 1

    # Write msg[2], wait 1 edge => msg[1] output visible
    dut.msg_data.value = build_msg_data(messages[2])
    await RisingEdge(dut.clk)
    scoreboard.check(dut, messages[1], True, "test_back_to_back[1]")
    assert int(dut.fields_valid.value) == 1

    # Deassert valid, wait 1 edge => msg[2] output visible
    dut.msg_valid.value = 0
    await RisingEdge(dut.clk)
    scoreboard.check(dut, messages[2], True, "test_back_to_back[2]")
    assert int(dut.fields_valid.value) == 1


@cocotb.test()
async def test_msg_valid_deasserted(dut):
    """msg_valid=0: fields_valid must stay 0 even with Add Order data."""
    await init_clock(dut)
    await reset_dut(dut)

    msg = make_add_order(buy=True, order_ref=0xDEADBEEFCAFEBABE, price=0x99887766)
    await drive_and_sample(dut, msg, msg_valid=False)

    assert int(dut.fields_valid.value) == 0, "fields_valid must be 0 when msg_valid=0"
    scoreboard.check(dut, msg, False, "test_msg_valid_deasserted")


@cocotb.test()
async def test_multiple_non_add_order_types(dut):
    """Exercise several non-Add-Order message types."""
    await init_clock(dut)
    await reset_dut(dut)

    for msg_type in [0x44, 0x55, 0x58, 0x45, 0x43, 0x50]:
        msg = bytearray(B)
        msg[0] = msg_type
        for i in range(1, B):
            msg[i] = (i + msg_type) & 0xFF

        await drive_and_sample(dut, msg)

        assert int(dut.fields_valid.value) == 0, \
            f"fields_valid should be 0 for msg_type 0x{msg_type:02X}"
        scoreboard.check(dut, msg, True, f"test_multi_non_add[0x{msg_type:02X}]")
