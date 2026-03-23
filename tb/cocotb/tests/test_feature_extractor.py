"""Tests for the feature_extractor module.

Verifies price delta, side encoding, order flow imbalance,
and normalized price features against golden model.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles
import struct


# ---- bfloat16 helpers (matching golden model) ----

def float_to_bfloat16(f: float) -> int:
    fp32_bits = struct.unpack('>I', struct.pack('>f', f))[0]
    return (fp32_bits >> 16) & 0xFFFF


def bfloat16_to_float(b: int) -> float:
    fp32_bits = (b & 0xFFFF) << 16
    return struct.unpack('>f', struct.pack('>I', fp32_bits))[0]


def int_to_bf16_ref(val: int) -> int:
    """Reference int-to-bfloat16 matching the RTL function."""
    if val == 0:
        return 0x0000
    sign = 1 if val < 0 else 0
    mag = abs(val)
    # Find position of leading 1
    bit_pos = mag.bit_length() - 1
    exp_val = 127 + bit_pos
    # Extract 7-bit mantissa (bits below leading 1)
    if bit_pos >= 7:
        man_val = (mag >> (bit_pos - 7)) & 0x7F
    else:
        man_val = (mag << (7 - bit_pos)) & 0x7F
    return (sign << 15) | (exp_val << 7) | man_val


async def reset_dut(dut, cycles=5):
    """Assert reset for N cycles."""
    dut.rst.value = 1
    dut.fields_valid.value = 0
    dut.price.value = 0
    dut.order_ref.value = 0
    dut.side.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def drive_fields(dut, price, side, order_ref=0):
    """Drive one set of parsed fields for one clock cycle."""
    dut.price.value = price
    dut.side.value = int(side)
    dut.order_ref.value = order_ref
    dut.fields_valid.value = 1
    await RisingEdge(dut.clk)
    dut.fields_valid.value = 0


async def read_features(dut):
    """Wait for features_valid and read the feature vector."""
    while True:
        await RisingEdge(dut.clk)
        if dut.features_valid.value == 1:
            feats = []
            for i in range(4):
                feats.append(int(dut.features[i].value))
            return feats


@cocotb.test()
async def test_price_delta(dut):
    """Verify price delta feature: second order should show delta from first."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    price1 = 10000
    price2 = 10500

    # First order: delta should be price1 - 0 = price1
    await drive_fields(dut, price1, side=1)
    feats1 = await read_features(dut)
    expected_delta1 = int_to_bf16_ref(price1)
    assert feats1[0] == expected_delta1, \
        f"Price delta mismatch: got 0x{feats1[0]:04x}, expected 0x{expected_delta1:04x}"

    # Second order: delta = price2 - price1 = 500
    await drive_fields(dut, price2, side=0)
    feats2 = await read_features(dut)
    expected_delta2 = int_to_bf16_ref(price2 - price1)
    assert feats2[0] == expected_delta2, \
        f"Price delta mismatch: got 0x{feats2[0]:04x}, expected 0x{expected_delta2:04x}"


@cocotb.test()
async def test_side_encoding(dut):
    """Verify buy → +1.0 bfloat16, sell → -1.0 bfloat16."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    bf16_plus1 = int_to_bf16_ref(1)   # +1.0 = 0x3F80
    bf16_minus1 = int_to_bf16_ref(-1)  # -1.0 = 0xBF80

    # Buy order
    await drive_fields(dut, 5000, side=1)
    feats = await read_features(dut)
    assert feats[1] == bf16_plus1, \
        f"Side buy: got 0x{feats[1]:04x}, expected 0x{bf16_plus1:04x}"

    # Sell order
    await drive_fields(dut, 5000, side=0)
    feats = await read_features(dut)
    assert feats[1] == bf16_minus1, \
        f"Side sell: got 0x{feats[1]:04x}, expected 0x{bf16_minus1:04x}"


@cocotb.test()
async def test_order_flow_imbalance(dut):
    """Verify running buy - sell imbalance counter."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    # Sequence: buy, buy, sell, buy → flow = +1, +2, +1, +2
    # Feature[2] shows the flow value AFTER this order's contribution
    expected_flows = [1, 2, 1, 2]
    sides = [1, 1, 0, 1]

    for i, (s, ef) in enumerate(zip(sides, expected_flows)):
        await drive_fields(dut, 5000, side=s)
        feats = await read_features(dut)
        expected_bf16 = int_to_bf16_ref(ef)
        assert feats[2] == expected_bf16, \
            f"Order {i}: flow got 0x{feats[2]:04x}, expected 0x{expected_bf16:04x} (flow={ef})"


@cocotb.test()
async def test_feature_vector_format(dut):
    """Verify full feature vector matches golden model reference."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    price = 25000
    side = 1  # buy

    await drive_fields(dut, price, side=side)
    feats = await read_features(dut)

    # Feature[0]: price_delta = 25000 - 0 = 25000
    assert feats[0] == int_to_bf16_ref(25000), f"feat[0] mismatch"
    # Feature[1]: side = +1
    assert feats[1] == int_to_bf16_ref(1), f"feat[1] mismatch"
    # Feature[2]: order_flow = 0 + 1 = 1
    assert feats[2] == int_to_bf16_ref(1), f"feat[2] mismatch"
    # Feature[3]: normalized price = 25000
    assert feats[3] == int_to_bf16_ref(25000), f"feat[3] mismatch"
