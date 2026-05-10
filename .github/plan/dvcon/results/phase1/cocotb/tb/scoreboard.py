"""Scoreboard for itch_field_extract.

Receives expected-output dicts via .expect(...) (one per active clock
edge) and compares them against the registered DUT outputs sampled
exactly one cycle later. Records every checked transaction and raises
on the first mismatch.
"""

from cocotb.triggers import RisingEdge, ReadOnly


FIELDS = ("message_type", "order_ref", "side", "price", "stock", "fields_valid")


class Scoreboard:
    def __init__(self, dut, log=None):
        self.dut = dut
        self.log = log or dut._log
        self.checked = 0
        self.errors = []
        self._pending = []  # FIFO of expected dicts, one per clock edge

    def expect(self, expected):
        """Queue the expected DUT outputs visible at the next rising edge."""
        self._pending.append(dict(expected))

    def _read_outputs(self):
        return {
            "message_type": int(self.dut.message_type.value),
            "order_ref": int(self.dut.order_ref.value),
            "side": int(self.dut.side.value),
            "price": int(self.dut.price.value),
            "stock": int(self.dut.stock.value),
            "fields_valid": int(self.dut.fields_valid.value),
        }

    def _compare(self, expected, actual, cycle):
        for f in FIELDS:
            if expected[f] != actual[f]:
                msg = (
                    f"cycle {cycle}: field {f} mismatch — "
                    f"expected 0x{expected[f]:x}, got 0x{actual[f]:x} "
                    f"(full expected={expected}, full actual={actual})"
                )
                self.errors.append(msg)
                raise AssertionError(msg)

    async def run(self):
        """Sample outputs every rising edge and compare against the queue."""
        cycle = 0
        while True:
            await RisingEdge(self.dut.clk)
            await ReadOnly()
            if self._pending:
                expected = self._pending.pop(0)
                actual = self._read_outputs()
                self._compare(expected, actual, cycle)
                self.checked += 1
            cycle += 1

    def summary(self):
        return f"Scoreboard: {self.checked} transactions checked, {len(self.errors)} errors"
