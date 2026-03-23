"""AXI4-Lite protocol compliance checker — concurrent cocotb coroutine.

Monitors AXI4-Lite signals and asserts protocol rules:
  1. AWVALID must not deassert without AWREADY handshake
  2. WVALID must not deassert without WREADY handshake
  3. ARVALID must not deassert without ARREADY handshake
  4. BRESP must be OKAY (0) on valid write response
  5. RRESP must be OKAY (0) on valid read response
"""

import cocotb
from cocotb.triggers import RisingEdge


class AXI4LiteChecker:
    """Runs as a concurrent coroutine checking AXI4-Lite protocol rules."""

    def __init__(self, dut, prefix="s_axil", log_name=None):
        self.clk = dut.clk
        # Write address channel
        self.awvalid = getattr(dut, f"{prefix}_awvalid")
        self.awready = getattr(dut, f"{prefix}_awready")
        # Write data channel
        self.wvalid = getattr(dut, f"{prefix}_wvalid")
        self.wready = getattr(dut, f"{prefix}_wready")
        # Write response
        self.bvalid = getattr(dut, f"{prefix}_bvalid")
        self.bresp = getattr(dut, f"{prefix}_bresp")
        # Read address channel
        self.arvalid = getattr(dut, f"{prefix}_arvalid")
        self.arready = getattr(dut, f"{prefix}_arready")
        # Read response
        self.rvalid = getattr(dut, f"{prefix}_rvalid")
        self.rresp = getattr(dut, f"{prefix}_rresp")

        self.log = dut._log
        self.violations = []
        self._name = log_name or f"{prefix}_checker"

    async def start(self):
        """Launch the checker coroutine."""
        cocotb.start_soon(self._run())

    async def _run(self):
        prev_awvalid = 0
        prev_awready = 0
        prev_wvalid = 0
        prev_wready = 0
        prev_arvalid = 0
        prev_arready = 0

        while True:
            await RisingEdge(self.clk)
            cur_awvalid = int(self.awvalid.value)
            cur_awready = int(self.awready.value)
            cur_wvalid = int(self.wvalid.value)
            cur_wready = int(self.wready.value)
            cur_arvalid = int(self.arvalid.value)
            cur_arready = int(self.arready.value)
            cur_bvalid = int(self.bvalid.value)
            cur_bresp = int(self.bresp.value)
            cur_rvalid = int(self.rvalid.value)
            cur_rresp = int(self.rresp.value)

            # Rule 1: AWVALID must not drop without handshake
            if prev_awvalid == 1 and prev_awready == 0 and cur_awvalid == 0:
                msg = f"[{self._name}] VIOLATION: AWVALID deasserted without AWREADY"
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            # Rule 2: WVALID must not drop without handshake
            if prev_wvalid == 1 and prev_wready == 0 and cur_wvalid == 0:
                msg = f"[{self._name}] VIOLATION: WVALID deasserted without WREADY"
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            # Rule 3: ARVALID must not drop without handshake
            if prev_arvalid == 1 and prev_arready == 0 and cur_arvalid == 0:
                msg = f"[{self._name}] VIOLATION: ARVALID deasserted without ARREADY"
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            # Rule 4: BRESP == OKAY on valid write response
            if cur_bvalid == 1 and cur_bresp != 0:
                msg = f"[{self._name}] VIOLATION: BRESP != OKAY ({cur_bresp}) on write response"
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            # Rule 5: RRESP == OKAY on valid read response
            if cur_rvalid == 1 and cur_rresp != 0:
                msg = f"[{self._name}] VIOLATION: RRESP != OKAY ({cur_rresp}) on read response"
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            prev_awvalid = cur_awvalid
            prev_awready = cur_awready
            prev_wvalid = cur_wvalid
            prev_wready = cur_wready
            prev_arvalid = cur_arvalid
            prev_arready = cur_arready

    def report(self):
        if not self.violations:
            return f"[{self._name}] PASS — no protocol violations"
        return f"[{self._name}] FAIL — {len(self.violations)} violation(s)"
