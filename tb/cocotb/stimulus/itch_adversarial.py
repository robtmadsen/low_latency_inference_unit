"""Adversarial ITCH message generators for error injection testing.

Produces intentionally malformed messages to verify parser recovery:
  - Truncated messages (shorter than declared length)
  - Invalid message type codes
  - Oversized messages (exceed max ITCH length)
  - Garbage bytes (no valid framing)
"""

import random
import struct

from utils.itch_decoder import encode_add_order, ADD_ORDER_LEN


def generate_truncated_message(seed=1) -> bytes:
    """Message body shorter than the 2-byte length prefix declares.

    Declares ADD_ORDER_LEN (36) but only includes 10 bytes of body.
    """
    rng = random.Random(seed)
    length_prefix = struct.pack('>H', ADD_ORDER_LEN)
    partial_body = bytes(rng.randint(0, 255) for _ in range(10))
    return length_prefix + partial_body


def generate_malformed_type(seed=2) -> bytes:
    """Full-length message with an invalid message type code (not 'A').

    Uses type code 0xFF which is not a valid ITCH message type.
    """
    rng = random.Random(seed)
    length_prefix = struct.pack('>H', ADD_ORDER_LEN)
    body = bytearray(ADD_ORDER_LEN)
    body[0] = 0xFF  # Invalid type
    for i in range(1, ADD_ORDER_LEN):
        body[i] = rng.randint(0, 255)
    return length_prefix + bytes(body)


def generate_oversized_message(size=200, seed=3) -> bytes:
    """Message declaring a length much larger than any valid ITCH message."""
    rng = random.Random(seed)
    length_prefix = struct.pack('>H', size)
    body = bytes(rng.randint(0, 255) for _ in range(size))
    return length_prefix + body


def generate_garbage(length=16, seed=4) -> bytes:
    """Random bytes with no valid ITCH framing."""
    rng = random.Random(seed)
    return bytes(rng.randint(0, 255) for _ in range(length))
