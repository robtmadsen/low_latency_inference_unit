"""AXI4-Lite master driver for cocotb — performs read/write transactions."""

from cocotb.triggers import RisingEdge


class AXI4LiteDriver:
    """Drives AXI4-Lite master signals for write and read transactions.

    Handles AW+W→B (write) and AR→R (read) handshakes.
    """

    def __init__(self, dut, prefix="s_axil"):
        self.clk = dut.clk
        # Write address channel
        self.awaddr = getattr(dut, f"{prefix}_awaddr")
        self.awvalid = getattr(dut, f"{prefix}_awvalid")
        self.awready = getattr(dut, f"{prefix}_awready")
        # Write data channel
        self.wdata = getattr(dut, f"{prefix}_wdata")
        self.wstrb = getattr(dut, f"{prefix}_wstrb")
        self.wvalid = getattr(dut, f"{prefix}_wvalid")
        self.wready = getattr(dut, f"{prefix}_wready")
        # Write response channel
        self.bresp = getattr(dut, f"{prefix}_bresp")
        self.bvalid = getattr(dut, f"{prefix}_bvalid")
        self.bready = getattr(dut, f"{prefix}_bready")
        # Read address channel
        self.araddr = getattr(dut, f"{prefix}_araddr")
        self.arvalid = getattr(dut, f"{prefix}_arvalid")
        self.arready = getattr(dut, f"{prefix}_arready")
        # Read data channel
        self.rdata = getattr(dut, f"{prefix}_rdata")
        self.rresp = getattr(dut, f"{prefix}_rresp")
        self.rvalid = getattr(dut, f"{prefix}_rvalid")
        self.rready = getattr(dut, f"{prefix}_rready")

    async def reset(self):
        """Deassert all master-driven signals."""
        self.awaddr.value = 0
        self.awvalid.value = 0
        self.wdata.value = 0
        self.wstrb.value = 0
        self.wvalid.value = 0
        self.bready.value = 0
        self.araddr.value = 0
        self.arvalid.value = 0
        self.rready.value = 0

    async def write(self, addr: int, data: int):
        """Perform an AXI4-Lite write (AW + W → B)."""
        # Drive AW and W simultaneously
        self.awaddr.value = addr
        self.awvalid.value = 1
        self.wdata.value = data
        self.wstrb.value = 0xF  # All byte lanes
        self.wvalid.value = 1
        self.bready.value = 1

        # Wait for both AW and W handshakes
        aw_done = False
        w_done = False
        while not (aw_done and w_done):
            await RisingEdge(self.clk)
            if self.awready.value == 1 and self.awvalid.value == 1:
                aw_done = True
                self.awvalid.value = 0
            if self.wready.value == 1 and self.wvalid.value == 1:
                w_done = True
                self.wvalid.value = 0

        # Wait for B response
        while True:
            await RisingEdge(self.clk)
            if self.bvalid.value == 1:
                self.bready.value = 0
                break

    async def read(self, addr: int) -> int:
        """Perform an AXI4-Lite read (AR → R). Returns read data."""
        self.araddr.value = addr
        self.arvalid.value = 1
        self.rready.value = 1

        # Wait for AR handshake
        while True:
            await RisingEdge(self.clk)
            if self.arready.value == 1:
                self.arvalid.value = 0
                break

        # Wait for R response
        while True:
            await RisingEdge(self.clk)
            if self.rvalid.value == 1:
                result = int(self.rdata.value)
                self.rready.value = 0
                return result
