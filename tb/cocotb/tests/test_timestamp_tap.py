"""test_timestamp_tap.py — Block-level tests for timestamp_tap.sv.

DUT: timestamp_tap
Clock: 3.2 ns (312.5 MHz — matches §3.2 sys_clk)

Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.9, §5 Phase 1

timestamp_tap behaviour (from RTL):
  - local_sub_cnt increments every cycle; resets to 0 on ptp_sync_pulse.
  - On tap_event, captures {epoch_latch, local_sub_cnt} → timestamp_out,
    timestamp_valid pulses for 1 cycle.

The test drives ptp_sync_pulse and ptp_epoch directly from Python,
acting as a stub for ptp_core.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

async def reset_tap_dut(dut):
    """Reset helper for timestamp_tap DUT; also drives inputs to safe defaults."""
    cocotb.start_soon(Clock(dut.clk, 3.2, unit='ns').start())
    dut.rst.value            = 1
    dut.ptp_sync_pulse.value = 0
    dut.ptp_epoch.value      = 0
    dut.tap_event.value      = 0
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


# ---------------------------------------------------------------------------
# Tests — timestamp_tap
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_timestamp_tap_sub_counter_reset(dut):
    """Verifies:
      1. local_sub_cnt increments each cycle (inferred from timestamp captures).
      2. ptp_sync_pulse resets local_sub_cnt to 0 next cycle.
      3. tap_event captures {epoch_latch, local_sub_cnt} → timestamp_out;
         timestamp_valid pulses for exactly 1 cycle.
    """
    await reset_tap_dut(dut)

    # After one settling edge (inside reset_tap_dut) local_sub_cnt = 1.
    # Run 5 more cycles so local_sub_cnt = 6, then capture.
    for _ in range(5):
        await RisingEdge(dut.clk)
    expected_sub_cnt = 6  # 1 (settle) + 5 (loop)

    # Fire tap_event for one cycle.
    # In cocotb+Verilator NBA commits become readable at the NEXT edge, so
    # wait a second rising edge before sampling the outputs.
    dut.tap_event.value = 1
    await RisingEdge(dut.clk)  # edge N: NBA commits timestamp_out & timestamp_valid=1
    dut.tap_event.value = 0
    await RisingEdge(dut.clk)  # edge N+1: stable read point (post-NBA of edge N)

    ts_out   = int(dut.timestamp_out.value)
    ts_valid = int(dut.timestamp_valid.value)
    captured_sub   = ts_out & 0x3FF
    captured_epoch = (ts_out >> 10) & ((1 << 64) - 1)

    assert ts_valid == 1, \
        f"timestamp_valid must be 1 when tap_event fires, got {ts_valid}"
    assert captured_sub == expected_sub_cnt, \
        f"Captured sub-counter should be {expected_sub_cnt}, got {captured_sub}"
    assert captured_epoch == 0, \
        f"epoch_latch should be 0 (no sync yet), got {captured_epoch}"

    # timestamp_valid should deassert next cycle.
    # Edge N+1's NBA (tap_event=0): timestamp_valid <= 0; readable at edge N+2.
    await RisingEdge(dut.clk)  # edge N+2
    assert int(dut.timestamp_valid.value) == 0, \
        "timestamp_valid must deassert after 1 cycle"

    # -----------------------------------------------------------------------
    # Drive ptp_sync_pulse with a known epoch value.
    # local_sub_cnt should reset to 0 on the pulse edge, then increment.
    # -----------------------------------------------------------------------
    test_epoch = 0xDEADBEEF_CAFEBABE
    dut.ptp_epoch.value      = test_epoch
    dut.ptp_sync_pulse.value = 1
    await RisingEdge(dut.clk)
    dut.ptp_sync_pulse.value = 0
    # Edge S  : local_sub_cnt NBA = 0, epoch_latch NBA = test_epoch.
    # Edge S+1: local_sub_cnt NBA = 1 (starts incrementing from 0).
    # At edge S+1 the OLD value of local_sub_cnt seen by RTL is 0 (from edge S's NBA).

    await RisingEdge(dut.clk)  # edge S+1: local_sub_cnt OLD = 0 → NBA = 1
    expected_after_sync = 1    # value that will be captured at edge S+2

    # Capture via tap_event; read at edge S+3 (double-await).
    dut.tap_event.value = 1
    await RisingEdge(dut.clk)  # edge S+2: NBA: timestamp_out={epoch,1}, ts_valid=1
    dut.tap_event.value = 0
    await RisingEdge(dut.clk)  # edge S+3: stable read (post-NBA of edge S+2)

    ts_out   = int(dut.timestamp_out.value)
    ts_valid = int(dut.timestamp_valid.value)
    sub_after_sync   = ts_out & 0x3FF
    epoch_after_sync = (ts_out >> 10) & ((1 << 64) - 1)

    assert ts_valid == 1, \
        "timestamp_valid must be 1 after second tap_event"
    assert sub_after_sync == expected_after_sync, \
        (f"local_sub_cnt should be {expected_after_sync} one cycle after sync, "
         f"got {sub_after_sync}")
    assert epoch_after_sync == test_epoch, \
        (f"epoch_latch should be 0x{test_epoch:X} after sync pulse, "
         f"got 0x{epoch_after_sync:X}")
