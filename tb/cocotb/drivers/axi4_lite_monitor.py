"""AXI4-Lite passive monitor — captures write/read transactions for scoreboard."""

import cocotb
from cocotb.triggers import RisingEdge


class AXI4LiteMonitor:
    """Passively samples AXI4-Lite transactions.

    Records completed write and read transactions for later verification.
    """

    def __init__(self, dut, prefix="s_axil"):
        self.clk = dut.clk
        self.awaddr = getattr(dut, f"{prefix}_awaddr")
        self.awvalid = getattr(dut, f"{prefix}_awvalid")
        self.awready = getattr(dut, f"{prefix}_awready")
        self.wdata = getattr(dut, f"{prefix}_wdata")
        self.wvalid = getattr(dut, f"{prefix}_wvalid")
        self.wready = getattr(dut, f"{prefix}_wready")
        self.bvalid = getattr(dut, f"{prefix}_bvalid")
        self.bready = getattr(dut, f"{prefix}_bready")
        self.araddr = getattr(dut, f"{prefix}_araddr")
        self.arvalid = getattr(dut, f"{prefix}_arvalid")
        self.arready = getattr(dut, f"{prefix}_arready")
        self.rdata = getattr(dut, f"{prefix}_rdata")
        self.rvalid = getattr(dut, f"{prefix}_rvalid")
        self.rready = getattr(dut, f"{prefix}_rready")

        self.writes = []  # list of (addr, data)
        self.reads = []   # list of (addr, data)
        self._write_cb = None
        self._read_cb = None

    def set_write_callback(self, cb):
        self._write_cb = cb

    def set_read_callback(self, cb):
        self._read_cb = cb

    async def monitor(self):
        """Run forever, sampling transactions on clock edges."""
        pending_wr_addr = None
        pending_wr_data = None
        pending_rd_addr = None

        while True:
            await RisingEdge(self.clk)

            # Capture write address
            if int(self.awvalid.value) and int(self.awready.value):
                pending_wr_addr = int(self.awaddr.value)

            # Capture write data
            if int(self.wvalid.value) and int(self.wready.value):
                pending_wr_data = int(self.wdata.value)

            # Write complete on B handshake
            if int(self.bvalid.value) and int(self.bready.value):
                if pending_wr_addr is not None and pending_wr_data is not None:
                    txn = (pending_wr_addr, pending_wr_data)
                    self.writes.append(txn)
                    if self._write_cb:
                        self._write_cb(txn)
                    pending_wr_addr = None
                    pending_wr_data = None

            # Capture read address
            if int(self.arvalid.value) and int(self.arready.value):
                pending_rd_addr = int(self.araddr.value)

            # Read complete on R handshake
            if int(self.rvalid.value) and int(self.rready.value):
                if pending_rd_addr is not None:
                    txn = (pending_rd_addr, int(self.rdata.value))
                    self.reads.append(txn)
                    if self._read_cb:
                        self._read_cb(txn)
                    pending_rd_addr = None
