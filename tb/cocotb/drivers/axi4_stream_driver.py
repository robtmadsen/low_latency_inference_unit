"""AXI4-Stream driver for cocotb — sends byte payloads as 64-bit beats."""

import cocotb
from cocotb.triggers import RisingEdge


class AXI4StreamDriver:
    """Drives AXI4-Stream master signals (tdata, tvalid, tlast).

    Byte order: big-endian (first byte at tdata[63:56]).
    Respects tready backpressure.
    """

    def __init__(self, dut, prefix="s_axis"):
        self.clk = dut.clk
        self.tdata = getattr(dut, f"{prefix}_tdata")
        self.tvalid = getattr(dut, f"{prefix}_tvalid")
        self.tready = getattr(dut, f"{prefix}_tready")
        self.tlast = getattr(dut, f"{prefix}_tlast")

    async def reset(self):
        """Deassert all drive signals."""
        self.tdata.value = 0
        self.tvalid.value = 0
        self.tlast.value = 0

    async def send(self, data: bytes):
        """Send a byte payload as 8-byte AXI4-Stream beats.

        Pads the last beat with zeros if not 8-byte aligned.
        Asserts tlast on the final beat.
        """
        # Pad to multiple of 8 bytes
        padded = data + b'\x00' * ((8 - len(data) % 8) % 8)
        num_beats = len(padded) // 8

        for i in range(num_beats):
            beat_bytes = padded[i*8 : (i+1)*8]
            beat_val = int.from_bytes(beat_bytes, byteorder='big')
            is_last = (i == num_beats - 1)

            self.tdata.value = beat_val
            self.tvalid.value = 1
            self.tlast.value = int(is_last)

            while True:
                await RisingEdge(self.clk)
                if self.tready.value == 1:
                    break

        # Deassert after transaction
        self.tvalid.value = 0
        self.tlast.value = 0
