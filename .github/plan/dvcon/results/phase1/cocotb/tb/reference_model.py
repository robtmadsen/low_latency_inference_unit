"""Independent reference model for itch_field_extract.

Computes expected output fields given a 36-byte ITCH Add Order message
and the msg_valid input. Implementation reads the spec, not the RTL.
"""

ITCH_LEN = 36
ITCH_MSG_ADD_ORDER = 0x41  # 'A'
SIDE_BUY_BYTE = 0x42       # 'B'


def pack_msg(msg_bytes):
    """Pack 36 bytes into the 288-bit msg_data word.

    Spec: byte N occupies msg_data[(35-N)*8 +: 8].
    Equivalently, byte 0 is the most-significant byte of msg_data.
    """
    if len(msg_bytes) != ITCH_LEN:
        raise ValueError(f"msg must be {ITCH_LEN} bytes, got {len(msg_bytes)}")
    val = 0
    for i, b in enumerate(msg_bytes):
        val |= (b & 0xFF) << ((ITCH_LEN - 1 - i) * 8)
    return val


def reference(msg_bytes, msg_valid):
    """Return expected registered outputs one cycle after the given inputs.

    Returns a dict with: message_type, order_ref, side, price, stock,
    fields_valid. Fields other than fields_valid reflect the message bytes
    regardless of msg_valid (they are don't-care when fields_valid=0, but
    the RTL still drives them from the combinational decode).
    """
    if len(msg_bytes) != ITCH_LEN:
        raise ValueError(f"msg must be {ITCH_LEN} bytes, got {len(msg_bytes)}")

    message_type = msg_bytes[0]
    order_ref = int.from_bytes(bytes(msg_bytes[11:19]), "big")
    side = 1 if msg_bytes[19] == SIDE_BUY_BYTE else 0
    price = int.from_bytes(bytes(msg_bytes[32:36]), "big")
    stock = int.from_bytes(bytes(msg_bytes[24:32]), "big")
    fields_valid = 1 if (msg_valid and message_type == ITCH_MSG_ADD_ORDER) else 0

    return {
        "message_type": message_type,
        "order_ref": order_ref,
        "side": side,
        "price": price,
        "stock": stock,
        "fields_valid": fields_valid,
    }


def reset_outputs():
    """Expected output state when synchronous reset is sampled high."""
    return {
        "message_type": 0,
        "order_ref": 0,
        "side": 0,
        "price": 0,
        "stock": 0,
        "fields_valid": 0,
    }


def make_add_order(
    order_ref=0,
    side_byte=SIDE_BUY_BYTE,
    shares=0,
    stock=b"AAPL    ",
    price=0,
    stock_locate=0,
    tracking_number=0,
    timestamp=0,
):
    """Build a well-formed Add Order (0x41) message body."""
    if len(stock) != 8:
        raise ValueError("stock must be exactly 8 bytes")
    body = bytearray(ITCH_LEN)
    body[0] = ITCH_MSG_ADD_ORDER
    body[1:3] = stock_locate.to_bytes(2, "big")
    body[3:5] = tracking_number.to_bytes(2, "big")
    body[5:11] = timestamp.to_bytes(6, "big")
    body[11:19] = order_ref.to_bytes(8, "big")
    body[19] = side_byte & 0xFF
    body[20:24] = shares.to_bytes(4, "big")
    body[24:32] = stock
    body[32:36] = price.to_bytes(4, "big")
    return bytes(body)


def make_other(msg_type_byte, payload_seed=0):
    """Build a non-Add-Order message body filled with deterministic bytes."""
    body = bytearray(ITCH_LEN)
    body[0] = msg_type_byte & 0xFF
    for i in range(1, ITCH_LEN):
        body[i] = (payload_seed + i * 7) & 0xFF
    return bytes(body)
