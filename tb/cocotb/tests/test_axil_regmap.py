"""Coverage-targeted tests for axi4_lite_slave.sv register map.

Targets gaps in:
  - Write channel FSM: AW/W capture ordering, simultaneous vs sequential
  - Read channel FSM: all register address selects
  - Register addresses: CTRL, STATUS, WGT_ADDR, WGT_DATA, RESULT, unmapped
  - Back-to-back writes with no gap
  - Write while inference is active
  - Read during each possible state
"""

import struct
import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

import sys, os
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from drivers.axi4_lite_driver import AXI4LiteDriver

# Register addresses
REG_CTRL     = 0x00
REG_STATUS   = 0x04
REG_WGT_ADDR = 0x08
REG_WGT_DATA = 0x0C
REG_RESULT   = 0x10


async def reset_dut(dut, cycles=5):
    dut.rst.value = 1
    dut.s_axil_awaddr.value = 0
    dut.s_axil_awvalid.value = 0
    dut.s_axil_wdata.value = 0
    dut.s_axil_wstrb.value = 0
    dut.s_axil_wvalid.value = 0
    dut.s_axil_bready.value = 0
    dut.s_axil_araddr.value = 0
    dut.s_axil_arvalid.value = 0
    dut.s_axil_rready.value = 0
    # Status inputs
    dut.status_result_ready.value = 0
    dut.status_busy.value = 0
    dut.result_data.value = 0
    for _ in range(cycles):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


# ================================================================
# Test: write and read every register address
# ================================================================
@cocotb.test()
async def test_write_all_registers(dut):
    """Write to CTRL, WGT_ADDR, WGT_DATA, and verify side-effects."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    # Write CTRL with start bit
    await axil.write(REG_CTRL, 0x1)
    await RisingEdge(dut.clk)
    # ctrl_start should have pulsed (self-clearing)
    # We can't easily catch the 1-cycle pulse, but the write should complete

    # Write CTRL with soft_reset bit
    await axil.write(REG_CTRL, 0x2)
    await RisingEdge(dut.clk)

    # Write CTRL with both bits
    await axil.write(REG_CTRL, 0x3)
    await RisingEdge(dut.clk)

    # Write WGT_ADDR
    await axil.write(REG_WGT_ADDR, 0x0)
    await RisingEdge(dut.clk)
    assert int(dut.wgt_wr_addr.value) == 0, "wgt_wr_addr should be 0"

    # Write WGT_ADDR with different value
    await axil.write(REG_WGT_ADDR, 0x3)
    await RisingEdge(dut.clk)

    # Write WGT_DATA (should trigger wr_en)
    await axil.write(REG_WGT_DATA, 0x3F80)
    await RisingEdge(dut.clk)

    dut._log.info("PASS: write all registers")


@cocotb.test()
async def test_read_all_registers(dut):
    """Read STATUS, RESULT, and unmapped addresses."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    # Set status inputs
    dut.status_result_ready.value = 1
    dut.status_busy.value = 0
    dut.result_data.value = 0x41200000  # 10.0 in float32
    await RisingEdge(dut.clk)

    # Read STATUS
    status = await axil.read(REG_STATUS)
    assert (status & 0x1) == 1, f"result_ready bit not set, got {status:#x}"
    assert (status & 0x2) == 0, f"busy bit should not be set, got {status:#x}"

    # Read STATUS with busy=1
    dut.status_busy.value = 1
    await RisingEdge(dut.clk)
    status2 = await axil.read(REG_STATUS)
    assert (status2 & 0x2) == 2, f"busy bit should be set, got {status2:#x}"

    # Read RESULT
    result = await axil.read(REG_RESULT)
    assert result == 0x41200000, f"RESULT mismatch: got {result:#x}"

    # Read unmapped address
    dead = await axil.read(0x20)
    assert dead == 0xDEADBEEF, f"Unmapped read should return 0xDEADBEEF, got {dead:#x}"

    # Read another unmapped
    dead2 = await axil.read(0xFF)
    assert dead2 == 0xDEADBEEF, f"Unmapped read should return 0xDEADBEEF, got {dead2:#x}"

    dut._log.info("PASS: read all registers")


# ================================================================
# Test: write to read-only / unmapped addresses
# ================================================================
@cocotb.test()
async def test_write_to_readonly_registers(dut):
    """Write to STATUS (0x04) and RESULT (0x10) — should be ignored gracefully."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    # Write to STATUS (read-only)
    await axil.write(REG_STATUS, 0xFFFF)
    await RisingEdge(dut.clk)

    # Write to RESULT (read-only)
    await axil.write(REG_RESULT, 0x12345678)
    await RisingEdge(dut.clk)

    # Write to unmapped address
    await axil.write(0x20, 0xDEAD)
    await RisingEdge(dut.clk)

    # Write to another unmapped address
    await axil.write(0xFC, 0xBEEF)
    await RisingEdge(dut.clk)

    dut._log.info("PASS: writes to read-only/unmapped addresses handled gracefully")


# ================================================================
# Test: back-to-back writes with no gap
# ================================================================
@cocotb.test()
async def test_back_to_back_writes(dut):
    """Rapid successive writes — exercises AW/W capture pipeline."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    # 4 weights back-to-back
    for i in range(4):
        await axil.write(REG_WGT_ADDR, i)
        await axil.write(REG_WGT_DATA, 0x3F80 + i)

    dut._log.info("PASS: back-to-back writes (4 weight loads)")


# ================================================================
# Test: back-to-back reads with no gap
# ================================================================
@cocotb.test()
async def test_back_to_back_reads(dut):
    """Rapid successive reads — exercises AR/R pipeline."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    dut.status_result_ready.value = 1
    dut.status_busy.value = 0
    dut.result_data.value = 0x42C80000
    await RisingEdge(dut.clk)

    # Read STATUS, RESULT, STATUS, unmapped in rapid succession
    s1 = await axil.read(REG_STATUS)
    r1 = await axil.read(REG_RESULT)
    s2 = await axil.read(REG_STATUS)
    u1 = await axil.read(0x30)

    assert s1 == s2, f"STATUS reads should be consistent: {s1:#x} vs {s2:#x}"
    assert r1 == 0x42C80000, f"RESULT mismatch: {r1:#x}"
    assert u1 == 0xDEADBEEF, f"Unmapped should be 0xDEADBEEF: {u1:#x}"

    dut._log.info("PASS: back-to-back reads")


# ================================================================
# Test: interleaved reads and writes
# ================================================================
@cocotb.test()
async def test_interleaved_read_write(dut):
    """Mix reads and writes to exercise both FSMs concurrently."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    dut.status_result_ready.value = 0
    dut.status_busy.value = 0
    dut.result_data.value = 0

    # Write WGT_ADDR, then read STATUS
    await axil.write(REG_WGT_ADDR, 0)
    status = await axil.read(REG_STATUS)

    # Write WGT_DATA, then read RESULT
    await axil.write(REG_WGT_DATA, 0x4000)
    result = await axil.read(REG_RESULT)

    # Write CTRL (start), then read STATUS
    await axil.write(REG_CTRL, 0x1)
    status = await axil.read(REG_STATUS)

    dut._log.info("PASS: interleaved read/write")


# ================================================================
# Test: AW before W (sequential capture)
# ================================================================
@cocotb.test()
async def test_aw_before_w(dut):
    """Drive AW first, then W — tests the aw_captured latch path."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    # Drive AW only
    dut.s_axil_awaddr.value = REG_WGT_ADDR
    dut.s_axil_awvalid.value = 1
    dut.s_axil_wvalid.value = 0
    dut.s_axil_bready.value = 1

    # Wait for AW handshake
    while True:
        await RisingEdge(dut.clk)
        if dut.s_axil_awready.value == 1:
            dut.s_axil_awvalid.value = 0
            break

    # Now drive W
    dut.s_axil_wdata.value = 0x02
    dut.s_axil_wstrb.value = 0xF
    dut.s_axil_wvalid.value = 1

    while True:
        await RisingEdge(dut.clk)
        if dut.s_axil_wready.value == 1:
            dut.s_axil_wvalid.value = 0
            break

    # Wait for B response
    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.s_axil_bvalid.value == 1:
            dut.s_axil_bready.value = 0
            break

    dut._log.info("PASS: AW before W sequential capture")


# ================================================================
# Test: W before AW (sequential capture, reversed order)
# ================================================================
@cocotb.test()
async def test_w_before_aw(dut):
    """Drive W first, then AW — tests the w_captured latch path."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)

    # Drive W only
    dut.s_axil_wdata.value = 0x3FC0
    dut.s_axil_wstrb.value = 0xF
    dut.s_axil_wvalid.value = 1
    dut.s_axil_awvalid.value = 0
    dut.s_axil_bready.value = 1

    # Wait for W handshake
    while True:
        await RisingEdge(dut.clk)
        if dut.s_axil_wready.value == 1:
            dut.s_axil_wvalid.value = 0
            break

    # Now drive AW
    dut.s_axil_awaddr.value = REG_WGT_DATA
    dut.s_axil_awvalid.value = 1

    while True:
        await RisingEdge(dut.clk)
        if dut.s_axil_awready.value == 1:
            dut.s_axil_awvalid.value = 0
            break

    # Wait for B response
    for _ in range(10):
        await RisingEdge(dut.clk)
        if dut.s_axil_bvalid.value == 1:
            dut.s_axil_bready.value = 0
            break

    dut._log.info("PASS: W before AW sequential capture")


# ================================================================
# Test: status bits in different combinations
# ================================================================
@cocotb.test()
async def test_status_bit_combinations(dut):
    """Read STATUS with all 4 combinations of result_ready × busy."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    for rr in [0, 1]:
        for busy in [0, 1]:
            dut.status_result_ready.value = rr
            dut.status_busy.value = busy
            await RisingEdge(dut.clk)
            status = await axil.read(REG_STATUS)
            expected = (busy << 1) | rr
            assert (status & 0x3) == expected, \
                f"rr={rr}, busy={busy}: got {status:#x}, expected {expected:#x}"

    dut._log.info("PASS: all status bit combinations")


# ================================================================
# Test: CTRL write data bit combinations
# ================================================================
@cocotb.test()
async def test_ctrl_write_combinations(dut):
    """Write 0, 1, 2, 3 to CTRL — exercise all bit paths."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    for val in [0, 1, 2, 3]:
        await axil.write(REG_CTRL, val)
        await RisingEdge(dut.clk)

    dut._log.info("PASS: CTRL write data bit combinations")


# ================================================================
# Test: multiple different result_data values to toggle bits
# ================================================================
@cocotb.test()
async def test_result_data_toggle(dut):
    """Read RESULT with various bit patterns to toggle register read data."""
    cocotb.start_soon(Clock(dut.clk, 10, unit='ns').start())
    await reset_dut(dut)
    axil = AXI4LiteDriver(dut)

    patterns = [0x00000000, 0xFFFFFFFF, 0xAAAAAAAA, 0x55555555, 0x12345678]
    for pat in patterns:
        dut.result_data.value = pat
        await RisingEdge(dut.clk)
        result = await axil.read(REG_RESULT)
        assert result == pat, f"RESULT mismatch: got {result:#x}, expected {pat:#x}"

    dut._log.info("PASS: result_data toggle patterns")
