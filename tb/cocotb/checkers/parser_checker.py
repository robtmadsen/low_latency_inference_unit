"""ITCH parser compliance checker — concurrent cocotb coroutine.

Monitors the parser and checks:
  1. Latency from tvalid handshake to fields_valid must be bounded
  2. FSM state must be valid (0, 1, or 2) — detects stuck/corrupt state
  3. Parser must not stay in non-IDLE state indefinitely (liveness check)
"""

import cocotb
from cocotb.triggers import RisingEdge


# Parser FSM states (from itch_parser.sv)
S_IDLE = 0
S_ACCUMULATE = 1
S_EMIT = 2
VALID_STATES = {S_IDLE, S_ACCUMULATE, S_EMIT}

# Maximum cycles parser can stay in ACCUMULATE before it's considered stuck
MAX_ACCUMULATE_CYCLES = 64


class ParserChecker:
    """Runs as a concurrent coroutine checking parser protocol and liveness."""

    def __init__(self, dut, parser_path=None, log_name=None):
        """
        Args:
            dut: Top-level DUT handle.
            parser_path: Hierarchy path to parser instance (e.g. dut.u_parser).
                         If None, assumes dut IS the parser.
        """
        self.clk = dut.clk
        parser = parser_path if parser_path is not None else dut
        self.tvalid = parser.s_axis_tvalid
        self.tready = parser.s_axis_tready
        self.fields_valid = parser.fields_valid
        self.state = parser.state
        self.log = dut._log
        self.violations = []
        self._name = log_name or "parser_checker"
        self.latencies = []

    async def start(self):
        """Launch the checker coroutine."""
        cocotb.start_soon(self._run())

    async def _run(self):
        accumulate_count = 0
        ingress_cycle = None
        cycle = 0

        while True:
            await RisingEdge(self.clk)
            cycle += 1

            cur_state = int(self.state.value)
            cur_tvalid = int(self.tvalid.value)
            cur_tready = int(self.tready.value)
            cur_fields_valid = int(self.fields_valid.value)

            # Rule 1: FSM state must be valid
            if cur_state not in VALID_STATES:
                msg = f"[{self._name}] VIOLATION: invalid FSM state {cur_state}"
                self.violations.append(msg)
                self.log.error(msg)
                assert False, msg

            # Track handshake → fields_valid latency
            if cur_tvalid == 1 and cur_tready == 1 and cur_state == S_IDLE:
                ingress_cycle = cycle

            if cur_fields_valid == 1 and ingress_cycle is not None:
                latency = cycle - ingress_cycle
                self.latencies.append(latency)
                ingress_cycle = None

            # Rule 2: Liveness — parser must not stay in ACCUMULATE too long
            if cur_state == S_ACCUMULATE:
                accumulate_count += 1
                if accumulate_count > MAX_ACCUMULATE_CYCLES:
                    msg = (f"[{self._name}] VIOLATION: parser stuck in ACCUMULATE "
                           f"for {accumulate_count} cycles")
                    self.violations.append(msg)
                    self.log.error(msg)
                    assert False, msg
            else:
                accumulate_count = 0

    def report(self):
        parts = []
        if not self.violations:
            parts.append(f"[{self._name}] PASS — no protocol violations")
        else:
            parts.append(f"[{self._name}] FAIL — {len(self.violations)} violation(s)")
        if self.latencies:
            parts.append(
                f"  Parser latencies: min={min(self.latencies)}, "
                f"max={max(self.latencies)}, avg={sum(self.latencies)/len(self.latencies):.1f}"
            )
        return "\n".join(parts)
