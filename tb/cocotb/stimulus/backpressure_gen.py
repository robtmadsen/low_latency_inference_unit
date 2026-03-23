"""Backpressure generation — controls message send pacing for pipeline stress.

The DUT (lliu_top) drives s_axis_tready as the AXI4-Stream slave. This module
controls the *send rate* from the test side: how quickly messages are injected,
exercising the pipeline's natural backpressure behavior when tready deasserts.
"""

import random

import cocotb
from cocotb.triggers import RisingEdge, ClockCycles


class BackpressureGenerator:
    """Configurable inter-message pacing for pipeline stress testing.

    Patterns:
        'none':     No delay between messages (maximum throughput).
        'periodic': N cycles ready, then M cycles stall between sends.
        'random':   Random delay (0 to max_delay cycles) between sends.
    """

    def __init__(self, dut, pattern='none', ready_cycles=4, stall_cycles=2,
                 max_delay=10, seed=42):
        self.dut = dut
        self.pattern = pattern
        self.ready_cycles = ready_cycles
        self.stall_cycles = stall_cycles
        self.max_delay = max_delay
        self.rng = random.Random(seed)
        self._send_count = 0

    async def inter_message_delay(self):
        """Wait between messages according to the configured pattern."""
        self._send_count += 1

        if self.pattern == 'none':
            return

        elif self.pattern == 'periodic':
            if self._send_count % self.ready_cycles == 0:
                await ClockCycles(self.dut.clk, self.stall_cycles)

        elif self.pattern == 'random':
            delay = self.rng.randint(0, self.max_delay)
            if delay > 0:
                await ClockCycles(self.dut.clk, delay)
