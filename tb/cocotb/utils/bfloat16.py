"""bfloat16 ↔ float32 conversion utilities for verification."""

import struct


def float_to_bfloat16(f: float) -> int:
    """Convert a Python float to a bfloat16 integer representation.

    Truncates the lower 16 bits of the float32 mantissa (no rounding).
    """
    fp32_bits = struct.unpack('>I', struct.pack('>f', f))[0]
    # bfloat16 is the upper 16 bits of float32
    return (fp32_bits >> 16) & 0xFFFF


def bfloat16_to_float(b: int) -> float:
    """Convert a bfloat16 integer representation back to a Python float."""
    # Pad lower 16 bits with zeros to make float32
    fp32_bits = (b & 0xFFFF) << 16
    return struct.unpack('>f', struct.pack('>I', fp32_bits))[0]


def bfloat16_mul_ref(a_float: float, b_float: float) -> float:
    """Reference bfloat16 multiply: truncate both inputs to bfloat16, multiply,
    return the float32 result (matching RTL bfloat16_mul behavior)."""
    a_bf16 = float_to_bfloat16(a_float)
    b_bf16 = float_to_bfloat16(b_float)
    # Convert back to float for the actual multiply (emulating hardware)
    a_trunc = bfloat16_to_float(a_bf16)
    b_trunc = bfloat16_to_float(b_bf16)
    return a_trunc * b_trunc


def fp32_to_bits(f: float) -> int:
    """Convert Python float to uint32 bit pattern."""
    return struct.unpack('>I', struct.pack('>f', f))[0]


def bits_to_fp32(b: int) -> float:
    """Convert uint32 bit pattern to Python float."""
    return struct.unpack('>f', struct.pack('>I', b & 0xFFFFFFFF))[0]
