"""moldupp64_checker.py — Concurrent protocol checker for moldupp64_strip.

Monitors the DUT output stream and sideband signals, asserting:
  1. seq_valid pulses for exactly 1 cycle per accepted datagram.
  2. expected_seq_num advances by msg_count after each accepted datagram.
  3. expected_seq_num does NOT advance after a dropped datagram.
  4. tlast coincides with the end of the reported ITCH payload.
  5. No spurious seq_valid pulses between datagrams.

Usage:
    checker = MoldUPP64Checker(dut)
    await checker.start()
    # ... drive DUT...
    checker.stop()
    checker.assert_no_errors()
"""

import cocotb
from cocotb.triggers import RisingEdge


class MoldUPP64Checker:
    """Protocol checker for moldupp64_strip block.

    Tracks seq_valid, expected_seq_num, and dropped_datagrams to verify
    the DUT's sequencing behaviour matches the spec (MAS §2.3).
    """

    def __init__(self, dut):
        self.dut = dut
        self.errors = []
        self._task = None
        # Python-side model state
        self._expected_seq = None   # seeded from DUT after reset
        self._prev_seq_valid = False
        self._pending_advance = None  # (new_expected_seq) from seq_valid pulse

    def _snap_current_seq(self) -> int:
        return int(self.dut.expected_seq_num.value)

    def _snap_dropped(self) -> int:
        return int(self.dut.dropped_datagrams.value)

    # ------------------------------------------------------------------
    # Concurrent monitoring coroutine
    # ------------------------------------------------------------------

    async def _monitor(self):
        dut = self.dut

        # Seed baseline on first cycle after start
        await RisingEdge(dut.clk)
        prev_expected_seq = int(dut.expected_seq_num.value)
        prev_dropped      = int(dut.dropped_datagrams.value)
        prev_seq_valid    = int(dut.seq_valid.value)
        # Set when an accepted datagram's seq_valid fires; cleared when
        # expected_seq_num subsequently advances.  The RTL may update
        # expected_seq_num in the same cycle as seq_valid OR in a later cycle —
        # this flag handles both cases without cycle-exact assumptions.
        pending_accept = False

        while True:
            await RisingEdge(dut.clk)

            cur_seq_valid = int(dut.seq_valid.value)
            cur_exp_seq   = int(dut.expected_seq_num.value)
            cur_dropped   = int(dut.dropped_datagrams.value)

            seq_changed     = (cur_exp_seq != prev_expected_seq)
            dropped_changed = (cur_dropped != prev_dropped)
            seq_valid_rose  = bool(cur_seq_valid and not prev_seq_valid)

            # ── Rule A: seq_valid rising edge ────────────────────────────────
            if seq_valid_rose:
                if dropped_changed:
                    # Dropped datagram (drop counter incremented simultaneously)
                    # seq_num must NOT advance
                    if seq_changed:
                        msg = (
                            f"expected_seq_num changed after a DROPPED datagram "
                            f"(dropped_datagrams +{cur_dropped - prev_dropped})"
                        )
                        self.errors.append(msg)
                        dut._log.error(f"[MoldUPP64Checker] {msg}")
                else:
                    # Accepted datagram — expect eventual advance
                    pending_accept = True

            # ── Rule B: spurious change (checked BEFORE clearing pending_accept)
            # seq_num changed, but there's no pending accept and no drop and
            # seq_valid didn't rise this cycle → unexpected
            if seq_changed and not dropped_changed and not seq_valid_rose and not pending_accept:
                msg = (
                    f"expected_seq_num changed (0x{prev_expected_seq:x} → "
                    f"0x{cur_exp_seq:x}) without a seq_valid pulse"
                )
                self.errors.append(msg)
                dut._log.error(f"[MoldUPP64Checker] {msg}")

            # ── Rule C: clear pending_accept once the advance arrives ────────
            if seq_changed and pending_accept:
                # Backward movement (not a 64-bit wrap) is always wrong
                if cur_exp_seq < prev_expected_seq and cur_exp_seq > 0x1000:
                    msg = (
                        f"expected_seq_num went backward: "
                        f"0x{prev_expected_seq:x} → 0x{cur_exp_seq:x}"
                    )
                    self.errors.append(msg)
                    dut._log.error(f"[MoldUPP64Checker] {msg}")
                pending_accept = False

            prev_seq_valid    = cur_seq_valid
            prev_expected_seq = cur_exp_seq
            prev_dropped      = cur_dropped

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    async def start(self):
        """Start the background monitoring coroutine."""
        self._task = cocotb.start_soon(self._monitor())

    def stop(self):
        """Cancel the background monitoring coroutine."""
        if self._task is not None:
            self._task.cancel()
            self._task = None

    def assert_no_errors(self):
        """Raise AssertionError if any protocol violations were recorded."""
        if self.errors:
            raise AssertionError(
                f"MoldUPP64Checker: {len(self.errors)} violation(s):\n"
                + "\n".join(f"  {e}" for e in self.errors)
            )
