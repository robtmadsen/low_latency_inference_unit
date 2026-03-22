"""Weight loader — writes bfloat16 weights to weight_mem via AXI4-Lite."""

import struct


def float_to_bfloat16(f: float) -> int:
    """Convert float to bfloat16 bit pattern (truncation, no rounding)."""
    fp32_bits = struct.unpack('>I', struct.pack('>f', f))[0]
    return (fp32_bits >> 16) & 0xFFFF


async def load_weights(axil_driver, weights: list):
    """Load a list of float weights into weight_mem via AXI4-Lite.

    Register map:
      0x08 = WGT_ADDR
      0x0C = WGT_DATA (triggers wr_en on write)
    """
    REG_WGT_ADDR = 0x08
    REG_WGT_DATA = 0x0C

    for i, w in enumerate(weights):
        bf16 = float_to_bfloat16(float(w))
        await axil_driver.write(REG_WGT_ADDR, i)
        await axil_driver.write(REG_WGT_DATA, bf16)
