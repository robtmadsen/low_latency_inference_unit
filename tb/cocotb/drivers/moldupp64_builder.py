"""moldupp64_builder.py — Stimulus helper for moldupp64_strip testbench.

Builds MoldUDP64 datagrams and drives them as AXI4-Stream beats onto the DUT.

Byte order convention (matches moldupp64_strip.sv tdata_byte function):
  Byte N of the datagram → tdata[(N%8)*8 +: 8]
  → tdata = int.from_bytes(chunk_8_bytes, 'little')
  → byte 0 at tdata[7:0], byte 7 at tdata[63:56]

MoldUDP64 header layout (20 bytes):
  bytes  0– 9: Session (10 ASCII bytes)
  bytes 10–17: Sequence Number (big-endian uint64)
  bytes 18–19: Message Count (big-endian uint16)
  bytes 20+  : ITCH payload (msg_count × [2-byte msg_len + msg_bytes])
"""

from __future__ import annotations

from typing import List, Tuple

from cocotb.triggers import RisingEdge


# Default session name used unless caller overrides
DEFAULT_SESSION = b"TESTSESS  "   # exactly 10 bytes


def build_datagram(
    seq_num:   int,
    payload:   bytes,
    msg_count: int = 1,
    session:   bytes = DEFAULT_SESSION,
) -> bytes:
    """Return the raw MoldUDP64 datagram as a bytes object.

    Args:
        seq_num:   Sequence number for this datagram (MoldUDP64 starts at 1).
        payload:   Raw bytes to place after the 20-byte header.  The caller is
                   responsible for including MoldUDP64 message-length prefixes
                   if needed.  For moldupp64_strip tests the content is
                   arbitrary — only the header fields matter to the DUT.
        msg_count: Number of ITCH messages encoded in this datagram (used by
                   the DUT to advance expected_seq_num).
        session:   10-byte ASCII session identifier.
    """
    assert len(session) == 10, "session must be exactly 10 bytes"
    hdr = session + seq_num.to_bytes(8, "big") + msg_count.to_bytes(2, "big")
    return hdr + payload


def pack_beats(dgram: bytes) -> List[Tuple[int, int, int]]:
    """Slice a datagram into AXI4-Stream (tdata, tkeep, tlast) beat tuples.

    The packing uses little-endian byte order within each 64-bit word.
    tkeep[i] covers tdata[i*8+7 : i*8].  For full beats tkeep=0xFF;
    for the last partial beat tkeep = (1 << valid_bytes) - 1.
    """
    beats = []
    n = len(dgram)
    for i in range(0, n, 8):
        chunk = dgram[i : i + 8]
        valid = len(chunk)
        padded = chunk.ljust(8, b"\x00")
        tdata = int.from_bytes(padded, "little")
        tkeep = (1 << valid) - 1
        tlast = 1 if (i + 8 >= n) else 0
        beats.append((tdata, tkeep, tlast))
    return beats


def expected_output_beats(payload: bytes) -> List[Tuple[int, int, int]]:
    """Return the expected output beats for a given ITCH payload.

    The moldupp64_strip DUT strips the 20-byte header and passes through
    the remaining bytes unchanged (same byte-lane ordering).  This function
    produces the expected (tdata, tkeep, tlast) list for comparison.

    IMPORTANT: Only call with payload sizes where
        (20 + len(payload)) % 8  ∈  {1, 2, 3, 4}
    i.e., the last input beat ends in the *lower* 4 byte lanes (tkeep[7:4]==0).
    For payload multiples of 8 bytes this is always satisfied.
    See moldupp64_strip.sv S_PAYLOAD notes for details.
    """
    return pack_beats(payload)


async def send_datagram(dut, dgram: bytes, idle_cycles: int = 0):
    """Drive one MoldUDP64 datagram beat-by-beat onto the DUT.

    Drives:  s_tdata, s_tkeep, s_tvalid, s_tlast
    Reads:   s_tready (obeys backpressure)

    Call after reset and with m_tready already set by the test.

    Args:
        idle_cycles: Number of cycles to deassert s_tvalid between beats
                     (simulates inter-beat gaps / backpressure).
    """
    beats = pack_beats(dgram)
    for tdata, tkeep, tlast in beats:
        # Inter-beat gap
        if idle_cycles > 0:
            dut.s_tvalid.value = 0
            for _ in range(idle_cycles):
                await RisingEdge(dut.clk)

        dut.s_tdata.value  = tdata
        dut.s_tkeep.value  = tkeep
        dut.s_tvalid.value = 1
        dut.s_tlast.value  = tlast

        # Wait for handshake
        while True:
            await RisingEdge(dut.clk)
            if int(dut.s_tready.value) == 1:
                break

    dut.s_tvalid.value = 0
    dut.s_tlast.value  = 0


async def receive_stream(dut, timeout_cycles: int = 200) -> List[Tuple[int, int, int]]:
    """Collect (tdata, tkeep, tlast) beats from the DUT output.

    Drives m_tready=1 and collects until tlast or timeout.
    Returns an empty list if no data arrives within timeout_cycles.
    """
    beats = []
    dut.m_tready.value = 1
    for _ in range(timeout_cycles):
        await RisingEdge(dut.clk)
        if int(dut.m_tvalid.value) == 1:
            tdata = int(dut.m_tdata.value)
            tkeep = int(dut.m_tkeep.value)
            tlast = int(dut.m_tlast.value)
            beats.append((tdata, tkeep, tlast))
            if tlast:
                break
    return beats


def beats_to_bytes(beats: List[Tuple[int, int, int]]) -> bytes:
    """Reassemble beats into a flat byte string using tkeep to determine valid lanes."""
    result = bytearray()
    for tdata, tkeep, _tlast in beats:
        for lane in range(8):
            if tkeep & (1 << lane):
                result.append((tdata >> (lane * 8)) & 0xFF)
    return bytes(result)
