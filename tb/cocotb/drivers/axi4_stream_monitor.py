"""AXI4-Stream monitor for cocotb — passively captures transactions."""

import cocotb
from cocotb.triggers import RisingEdge


class AXI4StreamMonitor:
    """Passively monitors AXI4-Stream: samples tdata when tvalid & tready.

    Accumulates beats into complete transactions (terminated by tlast).
    Calls registered callbacks with the complete transaction bytes.
    """

    def __init__(self, dut, prefix="s_axis"):
        self.clk = dut.clk
        self.tdata = getattr(dut, f"{prefix}_tdata")
        self.tvalid = getattr(dut, f"{prefix}_tvalid")
        self.tready = getattr(dut, f"{prefix}_tready")
        self.tlast = getattr(dut, f"{prefix}_tlast")
        self._callbacks = []
        self.transactions = []

    def add_callback(self, fn):
        """Register a callback called with (bytes) for each complete transaction."""
        self._callbacks.append(fn)

    async def monitor(self):
        """Run the monitor forever — call as cocotb.start_soon(mon.monitor())."""
        buf = bytearray()
        while True:
            await RisingEdge(self.clk)
            if self.tvalid.value == 1 and self.tready.value == 1:
                beat_val = self.tdata.value.integer
                buf.extend(beat_val.to_bytes(8, byteorder='big'))
                if self.tlast.value == 1:
                    txn = bytes(buf)
                    self.transactions.append(txn)
                    for cb in self._callbacks:
                        cb(txn)
                    buf = bytearray()
