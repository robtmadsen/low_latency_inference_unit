"""Coverage-targeted edge tests for feature_extractor.sv.

Targets gaps in int_to_bf16 function: zero, negative, max-magnitude, power-of-2,
small magnitude, negative order flow, oscillating buy/sell.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


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


async def fe_reset(dut, cycles=5):
    dut.rst.value = 1
    dut.fields_valid.value = 0
    dut.price.value = 0
    dut.order_ref.value = 0
    dut.side.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def fe_drive(dut, price, side, order_ref=0):
    dut.price.value = price
    dut.side.value = int(side)
    dut.order_ref.value = order_ref
    dut.fields_valid.value = 1
    await RisingEdge(dut.clk)
    dut.fields_valid.value = 0


async def fe_read_features(dut):
    while True:
        await RisingEdge(dut.clk)
        if dut.features_valid.value == 1:
            return [int(dut.features[i].value) for i in range(4)]


@cocotb.test()
async def test_zero_price_input(dut):
    """Price=0 exercises the zero path in int_to_bf16.

    Sends a non-zero price first, then a zero price to force a combinational
    re-evaluation with the input transitioning to zero.
    """
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await fe_reset(dut)
    # First send non-zero price so inputs are non-zero
    await fe_drive(dut, price=1000, side=1)
    await fe_read_features(dut)
    # Then send same price=1000 → price_delta = 0 → int_to_bf16(0)
    await fe_drive(dut, price=1000, side=1)
    feats = await fe_read_features(dut)
    assert feats[0] == 0x0000, f"price_delta should be 0, got 0x{feats[0]:04x}"
    # Now send price=0 → price_norm = 0 → int_to_bf16(0) for price
    await fe_drive(dut, price=0, side=1)
    feats2 = await fe_read_features(dut)
    assert feats2[3] == 0x0000, f"norm_price should be 0, got 0x{feats2[3]:04x}"
    dut._log.info("PASS: zero price input")


@cocotb.test()
async def test_max_price_input(dut):
    """Maximum 32-bit price to exercise high-magnitude int_to_bf16 path."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await fe_reset(dut)
    max_price = 0x7FFFFFFF
    await fe_drive(dut, price=max_price, side=0)
    feats = await fe_read_features(dut)
    expected_bf16 = int_to_bf16_ref(max_price)
    assert feats[3] == expected_bf16, \
        f"norm_price: got 0x{feats[3]:04x}, expected 0x{expected_bf16:04x}"
    dut._log.info("PASS: max price input")


@cocotb.test()
async def test_negative_price_delta(dut):
    """Price decrease produces negative int_to_bf16 result."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await fe_reset(dut)
    await fe_drive(dut, price=50000, side=1)
    await fe_read_features(dut)
    await fe_drive(dut, price=10000, side=1)
    feats = await fe_read_features(dut)
    expected = int_to_bf16_ref(10000 - 50000)
    assert feats[0] == expected, f"got 0x{feats[0]:04x}, expected 0x{expected:04x}"
    assert (feats[0] >> 15) == 1, "Negative delta should have sign bit set"
    dut._log.info("PASS: negative price delta")


@cocotb.test()
async def test_negative_order_flow(dut):
    """Multiple sells to drive order_flow negative."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await fe_reset(dut)
    for i in range(5):
        await fe_drive(dut, price=5000, side=0)
        feats = await fe_read_features(dut)
        expected_flow = -(i + 1)
        expected_bf16 = int_to_bf16_ref(expected_flow)
        assert feats[2] == expected_bf16, \
            f"Order {i}: got 0x{feats[2]:04x}, expected 0x{expected_bf16:04x}"
    dut._log.info("PASS: negative order flow")


@cocotb.test()
async def test_order_flow_oscillation(dut):
    """Buy-sell-buy-sell oscillation to toggle sign of order_flow."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await fe_reset(dut)
    sides = [1, 0, 1, 0, 1]
    expected_flows = [1, 0, 1, 0, 1]
    for i, (s, ef) in enumerate(zip(sides, expected_flows)):
        await fe_drive(dut, price=5000, side=s)
        feats = await fe_read_features(dut)
        expected_bf16 = int_to_bf16_ref(ef)
        assert feats[2] == expected_bf16, \
            f"Order {i}: got 0x{feats[2]:04x}, expected 0x{expected_bf16:04x}"
    dut._log.info("PASS: order flow oscillation")


@cocotb.test()
async def test_small_magnitude_values(dut):
    """Small prices (1-7) exercise low-magnitude int_to_bf16 paths."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await fe_reset(dut)
    for price in [1, 2, 3, 4, 5, 6, 7]:
        await fe_drive(dut, price=price, side=1)
        feats = await fe_read_features(dut)
        expected_bf16 = int_to_bf16_ref(price)
        assert feats[3] == expected_bf16, \
            f"Price {price}: got 0x{feats[3]:04x}, expected 0x{expected_bf16:04x}"
    dut._log.info("PASS: small magnitude values")


@cocotb.test()
async def test_power_of_two_prices(dut):
    """Powers of 2 exercise each bit position in int_to_bf16."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await fe_reset(dut)
    for shift in range(1, 31):
        price = 1 << shift
        await fe_drive(dut, price=price, side=1)
        feats = await fe_read_features(dut)
        expected_bf16 = int_to_bf16_ref(price)
        assert feats[3] == expected_bf16, \
            f"Price 2^{shift}: got 0x{feats[3]:04x}, expected 0x{expected_bf16:04x}"
    dut._log.info("PASS: power-of-two prices")


@cocotb.test()
async def test_large_price_delta_sweep(dut):
    """Large price swings to exercise wide delta range."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await fe_reset(dut)
    prices = [0, 1, 1000, 100000, 0x3FFFFFFF, 1]
    for price in prices:
        await fe_drive(dut, price=price, side=1)
        await fe_read_features(dut)
    dut._log.info("PASS: large price delta sweep")
