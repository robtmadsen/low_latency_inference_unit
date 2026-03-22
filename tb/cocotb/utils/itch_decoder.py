"""ITCH 5.0 message encoding/decoding utilities for verification.

Implements Add Order ('A') message construction and parsing with
2-byte big-endian length prefix as used by ITCH/MoldUDP64 framing.
"""

import struct

# ITCH 5.0 message type codes
MSG_TYPE_ADD_ORDER = 0x41        # 'A'
MSG_TYPE_SYSTEM_EVENT = 0x53     # 'S'

# Add Order message body length (excluding length prefix)
ADD_ORDER_LEN = 36


def encode_add_order(order_ref: int, side: str, price: int,
                     stock: str = "AAPL    ",
                     shares: int = 100,
                     stock_locate: int = 1,
                     tracking_number: int = 0,
                     timestamp: int = 0) -> bytes:
    """Build a complete ITCH Add Order message with 2-byte length prefix.

    Returns bytes ready to send over AXI4-Stream (length prefix + 36-byte body).

    Args:
        order_ref: 64-bit order reference number
        side: 'B' for buy, 'S' for sell
        price: 32-bit price (4 decimal places implied)
        stock: 8-character stock symbol (right-padded with spaces)
        shares: 32-bit share count
        stock_locate: 16-bit stock locate
        tracking_number: 16-bit tracking number
        timestamp: 48-bit timestamp
    """
    body = bytearray(ADD_ORDER_LEN)

    # Byte 0: message type
    body[0] = MSG_TYPE_ADD_ORDER

    # Bytes 1-2: stock locate (big-endian)
    struct.pack_into('>H', body, 1, stock_locate)

    # Bytes 3-4: tracking number (big-endian)
    struct.pack_into('>H', body, 3, tracking_number)

    # Bytes 5-10: timestamp (6 bytes, big-endian)
    ts_bytes = timestamp.to_bytes(6, byteorder='big')
    body[5:11] = ts_bytes

    # Bytes 11-18: order reference number (8 bytes, big-endian)
    struct.pack_into('>Q', body, 11, order_ref)

    # Byte 19: buy/sell indicator
    body[19] = ord(side)

    # Bytes 20-23: shares (big-endian)
    struct.pack_into('>I', body, 20, shares)

    # Bytes 24-31: stock (8 bytes, ASCII, right-padded)
    stock_padded = stock.ljust(8)[:8]
    body[24:32] = stock_padded.encode('ascii')

    # Bytes 32-35: price (big-endian)
    struct.pack_into('>I', body, 32, price)

    # Prepend 2-byte big-endian length prefix
    length_prefix = struct.pack('>H', ADD_ORDER_LEN)
    return bytes(length_prefix + body)


def decode_add_order(raw: bytes) -> dict:
    """Parse an Add Order message from raw bytes (with or without length prefix).

    If the first two bytes form a valid length prefix (== 36), they are stripped.
    Returns dict with extracted fields, or None if not an Add Order.
    """
    # Strip length prefix if present
    if len(raw) >= 38 and struct.unpack('>H', raw[:2])[0] == ADD_ORDER_LEN:
        body = raw[2:]
    else:
        body = raw

    if len(body) < ADD_ORDER_LEN:
        return None
    if body[0] != MSG_TYPE_ADD_ORDER:
        return None

    return {
        'message_type': body[0],
        'stock_locate': struct.unpack('>H', body[1:3])[0],
        'tracking_number': struct.unpack('>H', body[3:5])[0],
        'timestamp': int.from_bytes(body[5:11], 'big'),
        'order_ref': struct.unpack('>Q', body[11:19])[0],
        'side': chr(body[19]),
        'shares': struct.unpack('>I', body[20:24])[0],
        'stock': body[24:32].decode('ascii').rstrip(),
        'price': struct.unpack('>I', body[32:36])[0],
    }


def encode_system_event(event_code: str = 'O',
                        stock_locate: int = 0,
                        tracking_number: int = 0,
                        timestamp: int = 0) -> bytes:
    """Build an ITCH System Event ('S') message with length prefix.

    System Event is 12 bytes:
      [0]    message_type = 'S' (0x53)
      [1:2]  stock_locate
      [3:4]  tracking_number
      [5:10] timestamp
      [11]   event_code
    """
    body_len = 12
    body = bytearray(body_len)
    body[0] = MSG_TYPE_SYSTEM_EVENT
    struct.pack_into('>H', body, 1, stock_locate)
    struct.pack_into('>H', body, 3, tracking_number)
    body[5:11] = timestamp.to_bytes(6, byteorder='big')
    body[11] = ord(event_code)

    length_prefix = struct.pack('>H', body_len)
    return bytes(length_prefix + body)
