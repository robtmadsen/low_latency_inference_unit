"""eth_frame_builder.py — Build complete Ethernet/IP/UDP/MoldUDP64 frames.

Used by kc705 system-level tests that drive ``mac_rx_*`` on ``kc705_top``
(or ``eth_axis_rx_wrap`` Ethernet-level tests).

Frame layout per MAS §6.3:
    [Ethernet 14 B][IPv4 20 B][UDP 8 B][MoldUDP64 20 B][ITCH messages ...]

Ethernet header:
  - Dst MAC : 01:00:5e:36:0c:00  (multicast for 233.54.12.0, per RFC 1112)
  - Src MAC : 02:00:00:00:00:01
  - EtherType: 0x0800

IPv4 header (no options, 20 bytes):
  - Src IP  : 10.0.0.1
  - Dst IP  : 233.54.12.0
  - Proto   : 0x11 (UDP)
  - Checksum: computed correctly (ip_complete_64 verifies it)

UDP header:
  - Dst  port: 26477
  - Checksum : 0x0000

AXI4-Stream beat packing (matches moldupp64_builder.py convention):
  Byte N of frame → tdata[(N%8)*8 +: 8]  i.e. little-endian within each word.
"""

import struct
from cocotb.triggers import RisingEdge


# ---------------------------------------------------------------------------
# Default addressing constants (MAS §6.3)
# ---------------------------------------------------------------------------

ETH_DST_MAC  : bytes = bytes([0x01, 0x00, 0x5E, 0x36, 0x0C, 0x00])
ETH_SRC_MAC  : bytes = bytes([0x02, 0x00, 0x00, 0x00, 0x00, 0x01])
ETH_TYPE_IPV4: int   = 0x0800

IPV4_SRC     : bytes = bytes([10, 0, 0, 1])        # 10.0.0.1
IPV4_DST     : bytes = bytes([233, 54, 12, 0])     # 233.54.12.0
IPV4_TTL     : int   = 64
IPV4_PROTO   : int   = 0x11                        # UDP

UDP_SRC_PORT : int   = 1024
UDP_DST_PORT : int   = 26477

DEFAULT_SESSION: bytes = b"TESTSESS  "             # 10 bytes


# ---------------------------------------------------------------------------
# IPv4 checksum
# ---------------------------------------------------------------------------

def compute_ipv4_checksum(header: bytes) -> int:
    """RFC 791 one's-complement checksum over a 20-byte IPv4 header.

    The checksum field in the header must be zeroed before calling this.
    """
    assert len(header) == 20
    total = 0
    for i in range(0, 20, 2):
        word = (header[i] << 8) | header[i + 1]
        total += word
    # Fold carry bits back in
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return ~total & 0xFFFF


# ---------------------------------------------------------------------------
# Header builders
# ---------------------------------------------------------------------------

def build_eth_header(
    dst_mac: bytes = ETH_DST_MAC,
    src_mac: bytes = ETH_SRC_MAC,
    eth_type: int  = ETH_TYPE_IPV4,
) -> bytes:
    """Return the 14-byte Ethernet II header."""
    return dst_mac[:6] + src_mac[:6] + struct.pack(">H", eth_type)


def build_ipv4_header(
    payload_len: int,
    src_ip: bytes = IPV4_SRC,
    dst_ip: bytes = IPV4_DST,
    protocol: int = IPV4_PROTO,
    ident: int    = 0,
) -> bytes:
    """Return a 20-byte IPv4 header with a correct one's-complement checksum.

    ``payload_len`` is the number of bytes that follow the IP header
    (i.e. UDP header + UDP payload).
    """
    total_length = 20 + payload_len
    # Pack header with checksum = 0 first
    hdr = struct.pack(
        ">BBHHHBBH4s4s",
        0x45,           # Version + IHL
        0x00,           # DSCP / ECN
        total_length,   # Total length
        ident,          # Identification
        0x4000,         # Flags (DF) + Fragment Offset = 0
        IPV4_TTL,       # TTL
        protocol,       # Protocol
        0x0000,         # Checksum (zeroed for computation)
        src_ip[:4],
        dst_ip[:4],
    )
    checksum = compute_ipv4_checksum(hdr)
    # Re-pack with correct checksum at offset 10
    hdr = hdr[:10] + struct.pack(">H", checksum) + hdr[12:]
    return hdr


def build_udp_header(
    udp_payload_len: int,
    src_port: int = UDP_SRC_PORT,
    dst_port: int = UDP_DST_PORT,
) -> bytes:
    """Return an 8-byte UDP header with checksum=0.

    ``udp_payload_len`` is the number of bytes of UDP payload (after this header).
    """
    udp_length = 8 + udp_payload_len
    return struct.pack(">HHHH", src_port, dst_port, udp_length, 0x0000)


def build_moldupp64_payload(
    seq_num: int,
    msg_count: int,
    messages: list[bytes],
    session: bytes = DEFAULT_SESSION,
) -> bytes:
    """Return the 20-byte MoldUDP64 header followed by length-prefixed ITCH messages.

    Each message in ``messages`` is prefixed with a 2-byte big-endian length.
    ``msg_count`` must equal ``len(messages)`` or be set explicitly for gap tests.
    """
    assert len(session) == 10
    header = session + seq_num.to_bytes(8, "big") + msg_count.to_bytes(2, "big")
    body = b""
    for msg in messages:
        body += len(msg).to_bytes(2, "big") + msg
    return header + body


# ---------------------------------------------------------------------------
# Top-level frame assembly
# ---------------------------------------------------------------------------

def build_kc705_frame(
    messages:   list[bytes],
    seq_num:    int,
    msg_count:  int | None = None,
    session:    bytes      = DEFAULT_SESSION,
    dst_mac:    bytes      = ETH_DST_MAC,
    src_mac:    bytes      = ETH_SRC_MAC,
    src_ip:     bytes      = IPV4_SRC,
    dst_ip:     bytes      = IPV4_DST,
    src_port:   int        = UDP_SRC_PORT,
    dst_port:   int        = UDP_DST_PORT,
) -> bytes:
    """Assemble a fully-encapsulated Eth/IPv4/UDP/MoldUDP64 frame.

    This is the primary entry-point for kc705 system tests.

    Args:
        messages:  List of raw ITCH message bodies (no length prefix — this
                   function adds them).
        seq_num:   MoldUDP64 sequence number for this datagram.
        msg_count: Overrides the message count in the MoldUDP64 header.
                   Defaults to ``len(messages)`` for normal tests; pass a
                   different value to exercise gap / drop coverage.
        session:   10-byte MoldUDP64 session identifier.

    Returns:
        Byte string ready to be driven beat-by-beat onto ``mac_rx_*``.
    """
    if msg_count is None:
        msg_count = len(messages)

    moldudp64 = build_moldupp64_payload(seq_num, msg_count, messages, session)
    udp_hdr   = build_udp_header(len(moldudp64), src_port, dst_port)
    ipv4_hdr  = build_ipv4_header(len(udp_hdr) + len(moldudp64), src_ip, dst_ip)
    eth_hdr   = build_eth_header(dst_mac, src_mac)

    return eth_hdr + ipv4_hdr + udp_hdr + moldudp64


# ---------------------------------------------------------------------------
# AXI4-Stream beat helpers
# ---------------------------------------------------------------------------

def frame_to_beats(frame: bytes) -> list[tuple[int, int, int]]:
    """Slice ``frame`` into (tdata, tkeep, tlast) AXI4-Stream tuples.

    Packing convention (little-endian within each 64-bit word):
        byte N → tdata[(N%8)*8 +: 8]
    Full beats have tkeep=0xFF; the final partial beat has
    tkeep = (1 << valid_bytes) - 1.
    """
    beats = []
    n = len(frame)
    for i in range(0, n, 8):
        chunk = frame[i : i + 8]
        valid = len(chunk)
        padded = chunk.ljust(8, b"\x00")
        tdata = int.from_bytes(padded, "little")
        tkeep = (1 << valid) - 1
        tlast = 1 if (i + 8 >= n) else 0
        beats.append((tdata, tkeep, tlast))
    return beats


async def send_mac_frame(
    dut,
    frame: bytes,
    clk_sig,
    *,
    tready_timeout: int = 500,
) -> None:
    """Drive ``frame`` byte-for-byte onto ``dut.mac_rx_*`` one beat per handshake.

    Waits for ``mac_rx_tready`` before asserting the next beat.
    Deasserts ``mac_rx_tvalid`` after the last beat (``tlast=1``) is consumed.

    Args:
        dut:             cocotb DUT handle (must have mac_rx_tdata/tkeep/tvalid/tlast).
        frame:           Raw bytes to transmit.
        clk_sig:         Clock signal to trigger on.
        tready_timeout:  Cycles before an assertion error for backpressure stall.
    """
    beats = frame_to_beats(frame)
    for tdata, tkeep, tlast in beats:
        dut.mac_rx_tdata.value  = tdata
        dut.mac_rx_tkeep.value  = tkeep
        dut.mac_rx_tvalid.value = 1
        dut.mac_rx_tlast.value  = tlast
        # Wait until DUT accepts the beat
        for _ in range(tready_timeout):
            await RisingEdge(clk_sig)
            if int(dut.mac_rx_tready.value) == 1:
                break
        else:
            raise AssertionError(
                f"mac_rx_tready never asserted within {tready_timeout} cycles"
            )
    # Deassert after last beat consumed
    dut.mac_rx_tvalid.value = 0
    dut.mac_rx_tlast.value  = 0


async def collect_mac_output(
    dut,
    clk_sig,
    *,
    timeout: int = 200,
) -> list[tuple[int, int, int]]:
    """Collect (tdata, tkeep, tlast) beats from ``dut.fifo_rd_*`` output.

    Drives ``fifo_rd_tready`` high and collects all beats up to and including
    the beat with ``tlast=1``.  Returns an empty list if no output appears
    within ``timeout`` cycles.
    """
    beats = []
    for _ in range(timeout):
        await RisingEdge(clk_sig)
        if int(dut.fifo_rd_tvalid.value) == 1:
            tdata = int(dut.fifo_rd_tdata.value)
            tkeep = int(dut.fifo_rd_tkeep.value)
            tlast = int(dut.fifo_rd_tlast.value)
            beats.append((tdata, tkeep, tlast))
            if tlast:
                break
    return beats
