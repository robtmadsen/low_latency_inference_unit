"""test_moldupp64_strip.py — Block-level tests for moldupp64_strip.

DUT: moldupp64_strip
Clock: 6 ns (≈167 MHz; representative of the 156.25 MHz clk_156 domain)
Spec ref: .github/arch/kintex-7/Kintex-7_MAS.md §2.3

MoldUDP64 header: 20 bytes
  bytes  0–9:  session (10 ASCII bytes)
  bytes 10–17: sequence number (big-endian uint64)
  bytes 18–19: message count (big-endian uint16)
  bytes 20+:   ITCH payload

The DUT strips the header and passes through payload bytes unchanged.
Initial expected_seq_num after reset = 1 (per RTL).

Byte ordering: byte N of datagram → dut.s_tdata[(N%8)*8 +: 8] low bit
  → pack beat as int.from_bytes(chunk, 'little')

IMPORTANT payload size constraint: only use payload sizes where
  (20 + len(payload)) % 8  ∈  {1, 2, 3, 4}
i.e. the last input beat occupies ≤ 4 byte lanes (tkeep[7:4]==0).
For payload multiples of 8 bytes this is always satisfied.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from drivers.moldupp64_builder import (
    build_datagram,
    send_datagram,
    receive_stream,
    beats_to_bytes,
    expected_output_beats,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _reset(dut):
    """6 ns clock, 5-cycle reset."""
    cocotb.start_soon(Clock(dut.clk, 6, unit="ns").start())
    dut.rst.value      = 1
    dut.s_tdata.value  = 0
    dut.s_tkeep.value  = 0
    dut.s_tvalid.value = 0
    dut.s_tlast.value  = 0
    dut.m_tready.value = 1
    for _ in range(5):
        await RisingEdge(dut.clk)
    dut.rst.value = 0
    await RisingEdge(dut.clk)


async def _send_and_receive(dut, dgram: bytes, timeout: int = 100):
    """Send one datagram and collect all output beats concurrently."""
    import cocotb
    beats = []
    done  = cocotb.start_soon(_collect(dut, beats, timeout=timeout))
    await send_datagram(dut, dgram)
    # Give the DUT a few extra cycles to flush the final output beat
    for _ in range(8):
        await RisingEdge(dut.clk)
    done.cancel()
    return beats


async def _collect(dut, beats: list, timeout: int):
    """Background coroutine: collect (tdata, tkeep, tlast) beats until tlast."""
    dut.m_tready.value = 1
    for _ in range(timeout):
        await RisingEdge(dut.clk)
        if int(dut.m_tvalid.value) == 1 and int(dut.m_tready.value) == 1:
            beats.append((
                int(dut.m_tdata.value),
                int(dut.m_tkeep.value),
                int(dut.m_tlast.value),
            ))
            if int(dut.m_tlast.value):
                break


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@cocotb.test()
async def test_single_datagram(dut):
    """One well-formed datagram; verify stripped payload bytes are bit-accurate.

    seq_num=1 (accepted because initial expected_seq_num=1), msg_count=1,
    payload = 8 bytes.  Expected output: 1 beat with the 8 payload bytes.
    """
    await _reset(dut)

    payload = bytes(range(8))       # 0x00 0x01 … 0x07 — easy to inspect
    dgram   = build_datagram(seq_num=1, payload=payload, msg_count=1)
    # Sanity: total = 28 bytes → last beat has 4 bytes → tkeep[7:4]=0 ✓

    beats = await _send_and_receive(dut, dgram)

    assert len(beats) >= 1, "Expected at least 1 output beat, got 0"
    assert beats[-1][2] == 1, "Last beat must have tlast=1"

    received = beats_to_bytes(beats)
    assert received == payload, \
        f"Payload mismatch:\n  expected: {payload.hex()}\n  got:      {received.hex()}"

    # seq_valid should have pulsed — verify expected_seq_num advanced
    # expected_seq_num after reset = 1; after accepting 1 msg = 1 + 1 = 2
    assert int(dut.expected_seq_num.value) == 2, \
        f"expected_seq_num should be 2, got {int(dut.expected_seq_num.value)}"

    # No dropped datagrams
    assert int(dut.dropped_datagrams.value) == 0, \
        f"dropped_datagrams should be 0, got {int(dut.dropped_datagrams.value)}"

    dut._log.info(f"PASS: received {len(beats)} beat(s), payload matched")


@cocotb.test()
async def test_seq_advance(dut):
    """Two back-to-back datagrams; expected_seq_num advances by msg_count each time."""
    await _reset(dut)

    payload = b"\xAA" * 8

    # Datagram 1: seq_num=1, msg_count=2
    dgram1 = build_datagram(seq_num=1, payload=payload, msg_count=2)
    beats1 = await _send_and_receive(dut, dgram1)
    assert int(dut.expected_seq_num.value) == 3, \
        f"After datagram 1 (msg_count=2): expected 3, got {int(dut.expected_seq_num.value)}"

    # Datagram 2: seq_num=3, msg_count=1
    dgram2 = build_datagram(seq_num=3, payload=payload, msg_count=1)
    beats2 = await _send_and_receive(dut, dgram2)
    assert int(dut.expected_seq_num.value) == 4, \
        f"After datagram 2 (msg_count=1): expected 4, got {int(dut.expected_seq_num.value)}"

    assert int(dut.dropped_datagrams.value) == 0
    dut._log.info("PASS: expected_seq_num advances correctly")


@cocotb.test()
async def test_gap_seq_drop(dut):
    """Datagram with wrong seq_num is dropped; counter increments, seq_num unchanged."""
    await _reset(dut)

    payload = b"\xBB" * 8

    # Send a valid datagram first to reach expected_seq_num = 2
    dgram_ok = build_datagram(seq_num=1, payload=payload, msg_count=1)
    await _send_and_receive(dut, dgram_ok)
    assert int(dut.expected_seq_num.value) == 2

    # Send an out-of-order datagram (seq_num=5, not 2)
    dgram_bad = build_datagram(seq_num=5, payload=payload, msg_count=1)
    beats_bad = await _send_and_receive(dut, dgram_bad)

    # No payload output for dropped datagram
    assert len(beats_bad) == 0, \
        f"Expected 0 output beats for dropped datagram, got {len(beats_bad)}"

    assert int(dut.dropped_datagrams.value) == 1, \
        f"dropped_datagrams should be 1, got {int(dut.dropped_datagrams.value)}"

    # expected_seq_num unchanged after drop
    assert int(dut.expected_seq_num.value) == 2, \
        f"expected_seq_num should still be 2 after drop, got {int(dut.expected_seq_num.value)}"

    # A valid datagram at seq_num=2 should still be accepted
    dgram_recover = build_datagram(seq_num=2, payload=payload, msg_count=1)
    beats_recover = await _send_and_receive(dut, dgram_recover)
    assert len(beats_recover) >= 1, "Recovery datagram should produce output"
    assert beats_to_bytes(beats_recover) == payload

    dut._log.info("PASS: gap datagram dropped, counter incremented, recovery succeeds")


@cocotb.test()
async def test_multi_beat_payload(dut):
    """Datagram with 16-byte payload → 2 output beats."""
    await _reset(dut)

    payload = bytes(range(16))      # 0x00–0x0F
    dgram   = build_datagram(seq_num=1, payload=payload, msg_count=1)
    # total = 36 bytes → last beat has 4 valid bytes → tkeep[7:4]=0 ✓

    beats = await _send_and_receive(dut, dgram, timeout=200)

    assert len(beats) == 2, f"Expected 2 output beats for 16-byte payload, got {len(beats)}"
    assert beats[0][2] == 0, "First beat must not have tlast"
    assert beats[1][2] == 1, "Second beat must have tlast"

    received = beats_to_bytes(beats)
    assert received == payload, \
        f"Payload mismatch:\n  expected: {payload.hex()}\n  got:      {received.hex()}"
    dut._log.info("PASS: 16-byte payload, 2 beats, bit-accurate")


@cocotb.test()
async def test_interleaved_good_bad(dut):
    """Alternating good and bad datagrams; verify counts."""
    await _reset(dut)

    payload = b"\xCC" * 8
    dropped = 0
    seq = 1

    for i in range(6):
        if i % 2 == 0:
            dgram = build_datagram(seq_num=seq, payload=payload, msg_count=1)
            beats = await _send_and_receive(dut, dgram)
            assert len(beats) >= 1, f"Good datagram {i} produced no output"
            seq += 1
        else:
            # Send datagram with wrong seq_num (far future)
            dgram = build_datagram(seq_num=seq + 100, payload=payload, msg_count=1)
            beats = await _send_and_receive(dut, dgram)
            assert len(beats) == 0, f"Bad datagram {i} should produce no output"
            dropped += 1

    assert int(dut.dropped_datagrams.value) == dropped, \
        f"Expected dropped_datagrams={dropped}, got {int(dut.dropped_datagrams.value)}"
    dut._log.info(f"PASS: interleaved test, {dropped} drops correctly counted")
