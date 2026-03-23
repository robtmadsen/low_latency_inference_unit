"""AXI4-Stream protocol compliance checker — concurrent cocotb coroutine.

Monitors AXI4-Stream signals and asserts protocol rules equivalent to SVA:
  1. tvalid must not deassert without a handshake (tvalid && !tready |=> tvalid)
  2. tdata must be stable while tvalid is high and tready is low
  3. tlast must be stable while tvalid is high and tready is low
"""

import cocotb
from cocotb.triggers import RisingEdge


class AXI4StreamChecker:
    """Runs as a concurrent coroutine checking AXI4-Stream protocol rules."""

    def __init__(self, dut, prefix="s_axis", log_name=None):
        self.clk = dut.clk
        self.tdata = getattr(dut, f"{prefix}_tdata")
        self.tvalid = getattr(dut, f"{prefix}_tvalid")
        self.tready = getattr(dut, f"{prefix}_tready")
        self.tlast = getattr(dut, f"{prefix}_tlast")
        self.log = dut._log
        self.violations = []
        self._name = log_name or f"{prefix}_checker"

    async def start(self):
        """Launch the checker coroutine."""
        cocotb.start_soon(self._run())

    async def _run(self):
        prev_tvalid = 0
        prev_tdata = 0
        prev_tlast = 0
        prev_tready = 0

        while True:
            await RisingEdge(self.clk)
            cur_tvalid = int(self.tvalid.value)
            cur_tdata = int(self.tdata.value)
            cur_tlast = int(self.tlast.value)
            cur_tready = int(self.tready.value)

            # Rule 1: tvalid must not drop without handshake
            # If tvalid was high and tready was low last cycle, tvalid must still be high
            if prev_tvalid == 1 and prev_tready == 0 and cur_tvalid == 0:
                msg = f"[{self._name}] VIOLATION: tvalid deasserted without handshake"
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            # Rule 2: tdata must be stable while tvalid && !tready
            if prev_tvalid == 1 and prev_tready == 0 and cur_tvalid == 1:
                if cur_tdata != prev_tdata:
                    msg = (f"[{self._name}] VIOLATION: tdata changed while waiting "
                           f"for tready (0x{prev_tdata:016x} → 0x{cur_tdata:016x})")
                    self.violations.append(msg)
                    self.log.error(msg)
                    assert False, msg

            # Rule 3: tlast must be stable while tvalid && !tready
            if prev_tvalid == 1 and prev_tready == 0 and cur_tvalid == 1:
                if cur_tlast != prev_tlast:
                    msg = f"[{self._name}] VIOLATION: tlast changed while waiting for tready"
                    self.violations.append(msg)
                    self.log.error(msg)
                    assert False, msg

            prev_tvalid = cur_tvalid
            prev_tdata = cur_tdata
            prev_tlast = cur_tlast
            prev_tready = cur_tready

    def report(self):
        if not self.violations:
            return f"[{self._name}] PASS — no protocol violations"
        return f"[{self._name}] FAIL — {len(self.violations)} violation(s)"
