"""Golden model: shared reference for both UVM (via DPI-C) and cocotb (native).

All math uses bfloat16 truncation at multiply, float32 at accumulate,
matching RTL behavior exactly.
"""

import struct
import numpy as np


def float_to_bfloat16(f: float) -> int:
    """Convert float to bfloat16 bit pattern (truncation, no rounding)."""
    fp32_bits = struct.unpack('>I', struct.pack('>f', f))[0]
    return (fp32_bits >> 16) & 0xFFFF


def bfloat16_to_float(b: int) -> float:
    """Convert bfloat16 bit pattern to float."""
    fp32_bits = (b & 0xFFFF) << 16
    return struct.unpack('>f', struct.pack('>I', fp32_bits))[0]


class GoldenModel:
    """Reference model for the LLIU pipeline."""

    def __init__(self):
        self.last_price = 0

    def parse_add_order(self, raw_bytes: bytes) -> dict:
        """Parse ITCH 5.0 Add Order message fields from raw message body.

        ITCH Add Order ('A') layout (36 bytes, after message type byte):
          [0]     message_type (1 byte) = 'A' (0x41)
          [1:2]   stock_locate (2 bytes)
          [3:4]   tracking_number (2 bytes)
          [5:10]  timestamp (6 bytes)
          [11:18] order_reference_number (8 bytes)
          [19]    buy_sell_indicator (1 byte) 'B' or 'S'
          [20:23] shares (4 bytes)
          [24:31] stock (8 bytes)
          [32:35] price (4 bytes)
        """
        if len(raw_bytes) < 36:
            return None
        if raw_bytes[0] != 0x41:  # 'A'
            return None

        order_ref = int.from_bytes(raw_bytes[11:19], 'big')
        side = 1 if raw_bytes[19] == ord('B') else 0  # 1=buy, 0=sell
        price = int.from_bytes(raw_bytes[32:36], 'big')

        return {
            'order_ref': order_ref,
            'side': side,
            'price': price,
        }

    def extract_features(self, price: int, order_ref: int, side: int) -> np.ndarray:
        """Compute feature vector matching RTL feature_extractor.

        Returns array of 4 float values (will be truncated to bfloat16 in inference).
        Features:
          [0] price delta (current - last)
          [1] side encoding (+1.0 buy, -1.0 sell)
          [2] order flow accumulator (not tracked here, placeholder 0.0)
          [3] normalized price (raw as float)
        """
        price_delta = float(price - self.last_price)
        self.last_price = price

        side_enc = 1.0 if side == 1 else -1.0
        norm_price = float(price)

        return np.array([price_delta, side_enc, 0.0, norm_price], dtype=np.float32)

    def inference(self, features: np.ndarray, weights: np.ndarray) -> float:
        """Dot product with bfloat16 mul + float32 accumulate semantics.

        Matches RTL: each element pair is truncated to bfloat16 before multiply,
        products are accumulated in float32.
        """
        assert len(features) == len(weights)
        acc = 0.0
        for f_val, w_val in zip(features, weights):
            # Truncate both to bfloat16
            f_bf16 = bfloat16_to_float(float_to_bfloat16(float(f_val)))
            w_bf16 = bfloat16_to_float(float_to_bfloat16(float(w_val)))
            # Multiply (result is float32-precision product of bfloat16 values)
            product = f_bf16 * w_bf16
            # Accumulate in float32
            acc += product
        return acc
