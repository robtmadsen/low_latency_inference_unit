"""symbol_filter_checker.py — concurrent protocol checker for symbol_filter.

Monitors stock_valid / watchlist_hit timing:
  - When stock_valid is asserted, records the stock value and expected hit
    based on a Python-side CAM model.
  - On the NEXT rising edge asserts that watchlist_hit == expected.
  - Flags any watchlist_hit pulse when no preceding stock_valid (false trigger).
"""

import cocotb
from cocotb.triggers import RisingEdge


class SymbolFilterChecker:
    """Checker for symbol_filter block.

    Usage:
        checker = SymbolFilterChecker(dut)
        checker.add_cam_entry(0, b"AAPL    ", enabled=True)
        await checker.start()
        # ... drive DUT...
        checker.stop()
        checker.assert_no_errors()
    """

    def __init__(self, dut):
        self.dut = dut
        self.errors = []
        self._cam = {}   # index → (key_int, enabled)
        self._task = None

    # ------------------------------------------------------------------
    # CAM model — kept in sync with write transactions the test performs
    # ------------------------------------------------------------------

    def add_cam_entry(self, index: int, key: bytes, enabled: bool = True):
        """Register a CAM entry write so the checker knows the expected state."""
        assert len(key) == 8, "stock key must be exactly 8 bytes"
        self._cam[index] = (int.from_bytes(key, 'big'), enabled)

    def invalidate_cam_entry(self, index: int):
        self._cam[index] = (self._cam.get(index, (0, False))[0], False)

    def expected_hit(self, stock_int: int) -> bool:
        """Return True if stock_int matches any active CAM entry."""
        for _idx, (key, en) in self._cam.items():
            if en and key == stock_int:
                return True
        return False

    # ------------------------------------------------------------------
    # Concurrent monitoring coroutine
    # ------------------------------------------------------------------

    async def _monitor(self):
        dut = self.dut
        prev_stock_valid = False
        prev_stock_int = 0
        prev_expected_hit = False

        while True:
            await RisingEdge(dut.clk)

            cur_hit = int(dut.watchlist_hit.value) == 1

            # Check that watchlist_hit matches expectation from previous cycle
            if prev_stock_valid:
                if cur_hit != prev_expected_hit:
                    msg = (
                        f"watchlist_hit mismatch: stock=0x{prev_stock_int:016x} "
                        f"expected={prev_expected_hit} got={cur_hit}"
                    )
                    self.errors.append(msg)
                    dut._log.error(f"[SymbolFilterChecker] {msg}")
            elif cur_hit:
                # watchlist_hit asserted without a preceding stock_valid
                msg = f"watchlist_hit=1 with no preceding stock_valid (false trigger)"
                self.errors.append(msg)
                dut._log.error(f"[SymbolFilterChecker] {msg}")

            # Sample current cycle for next iteration
            prev_stock_valid = int(dut.stock_valid.value) == 1
            if prev_stock_valid:
                prev_stock_int = int(dut.stock.value)
                prev_expected_hit = self.expected_hit(prev_stock_int)
            else:
                prev_stock_int = 0
                prev_expected_hit = False

    async def start(self):
        self._task = cocotb.start_soon(self._monitor())

    def stop(self):
        if self._task is not None:
            self._task.kill()
            self._task = None

    def assert_no_errors(self):
        assert not self.errors, \
            f"SymbolFilterChecker found {len(self.errors)} error(s):\n" + \
            "\n".join(self.errors)
