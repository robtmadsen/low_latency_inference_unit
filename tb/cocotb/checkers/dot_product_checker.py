"""Dot-product engine compliance checker — concurrent cocotb coroutine.

Monitors the dot-product engine and checks:
  1. result_valid must assert within (VEC_LEN + pipeline_depth) cycles of start
  2. No result_valid without a preceding start
  3. FSM state must be valid (0, 1, or 2)
"""

import cocotb
from cocotb.triggers import RisingEdge


# Dot-product FSM states (from dot_product_engine.sv)
S_IDLE = 0
S_COMPUTE = 1
S_DONE = 2
VALID_STATES = {S_IDLE, S_COMPUTE, S_DONE}

# VEC_LEN + pipeline overhead — generous bound
MAX_COMPUTE_CYCLES = 32


class DotProductChecker:
    """Runs as a concurrent coroutine checking dot-product engine protocol."""

    def __init__(self, dut, dp_path=None, log_name=None):
        """
        Args:
            dut: Top-level DUT handle.
            dp_path: Hierarchy path to dot_product_engine instance
                     (e.g. dut.u_dot_product). If None, assumes dut IS the engine.
        """
        self.clk = dut.clk
        engine = dp_path if dp_path is not None else dut
        self.start_sig = engine.start
        self.result_valid = engine.result_valid
        self.state = engine.state
        self.log = dut._log
        self.violations = []
        self._name = log_name or "dot_product_checker"
        self.compute_latencies = []

    async def start(self):
        """Launch the checker coroutine."""
        cocotb.start_soon(self._run())

    async def _run(self):
        started = False
        cycles_since_start = 0

        while True:
            await RisingEdge(self.clk)

            cur_state = int(self.state.value)
            cur_start = int(self.start_sig.value)
            cur_result_valid = int(self.result_valid.value)

            # Rule 1: FSM state must be valid
            if cur_state not in VALID_STATES:
                msg = f"[{self._name}] VIOLATION: invalid FSM state {cur_state}"
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            # Track start → result_valid
            if cur_start == 1 and not started:
                started = True
                cycles_since_start = 0

            if started:
                cycles_since_start += 1

            # Rule 2: result_valid must come within bounded cycles of start
            if started and cycles_since_start > MAX_COMPUTE_CYCLES:
                msg = (f"[{self._name}] VIOLATION: result_valid not asserted within "
                       f"{MAX_COMPUTE_CYCLES} cycles of start")
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            if cur_result_valid == 1:
                if started:
                    self.compute_latencies.append(cycles_since_start)
                    started = False
                else:
                    # Rule 3: No result_valid without preceding start
                    msg = f"[{self._name}] VIOLATION: result_valid without preceding start"
                    self.violations.append(msg)
                    self.log.error(msg)
                    assert False, msg

    def report(self):
        parts = []
        if not self.violations:
            parts.append(f"[{self._name}] PASS — no protocol violations")
        else:
            parts.append(f"[{self._name}] FAIL — {len(self.violations)} violation(s)")
        if self.compute_latencies:
            parts.append(
                f"  Compute latencies: min={min(self.compute_latencies)}, "
                f"max={max(self.compute_latencies)}, "
                f"avg={sum(self.compute_latencies)/len(self.compute_latencies):.1f}"
            )
        return "\n".join(parts)
