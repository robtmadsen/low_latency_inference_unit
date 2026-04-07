"""order_book_model.py — Python reference model for order_book.sv.

Tracks the DUT's exact state-machine semantics, including:
  - CRC-17/CAN hash function (matches RTL crc17())
  - Phase-1 simplified BBO (best-price wins; reset to 0 on delete of BBO-price order)
  - Non-blocking assignment semantics for Replace (BBO add check uses pre-clear BBO values)
  - Collision detection for modify operations (delete/cancel/replace/execute)

Spec ref: .github/arch/kintex-7/2p0_kintex-7_MAS.md §4.3, §7
"""


def crc17(data: int) -> int:
    """CRC-17/CAN matching rtl/order_book.sv crc17() function.

    Processes bits MSB-first.  Polynomial 0x1002D.
    """
    crc = 0
    for i in range(63, -1, -1):
        bit = (data >> i) & 1
        msb = ((crc >> 16) ^ bit) & 1
        crc = (crc << 1) & 0x1FFFF
        if msb:
            crc ^= 0x1002D
    return crc


class OrderBookModel:
    """Python reference model for order_book.sv (Phase 1).

    Attributes
    ----------
    ref_table : dict
        Maps 17-bit CRC hash → entry dict with keys:
        order_ref, price, shares, side, sym_id
    bbo_bid_price : list[int]  length 500
    bbo_ask_price : list[int]  length 500
    bbo_bid_size  : list[int]  length 500
    bbo_ask_size  : list[int]  length 500
    collision_count : int
    """

    NUM_SYMBOLS = 500

    def __init__(self):
        self.ref_table = {}
        self.bbo_bid_price = [0] * self.NUM_SYMBOLS
        self.bbo_ask_price = [0] * self.NUM_SYMBOLS
        self.bbo_bid_size  = [0] * self.NUM_SYMBOLS
        self.bbo_ask_size  = [0] * self.NUM_SYMBOLS
        self.collision_count = 0

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def add(self, order_ref: int, price: int, shares: int, side: int, sym_id: int) -> dict:
        """Add a resting order.

        Collision policy: if the CRC-17 bucket already holds a *different*
        order_ref, this is a hash collision — increment counter and drop.
        (Same order_ref re-adds the entry, matching RTL overwrite semantics.)

        Returns dict with keys 'collision' (bool) and 'bbo_updated' (bool).
        """
        h = crc17(order_ref)
        if h in self.ref_table and self.ref_table[h]['order_ref'] != order_ref:
            self.collision_count += 1
            return {'collision': True, 'bbo_updated': False}

        self.ref_table[h] = {
            'order_ref': order_ref,
            'price':     price,
            'shares':    shares & 0xFFFFFF,   # 24-bit, matches RTL
            'side':      side,
            'sym_id':    sym_id,
        }

        # Phase-1 BBO: better price wins
        if side == 1:  # bid
            if price > self.bbo_bid_price[sym_id]:
                self.bbo_bid_price[sym_id] = price
                self.bbo_bid_size[sym_id]  = shares & 0xFFFFFF
        else:           # ask
            if self.bbo_ask_price[sym_id] == 0 or price < self.bbo_ask_price[sym_id]:
                self.bbo_ask_price[sym_id] = price
                self.bbo_ask_size[sym_id]  = shares & 0xFFFFFF

        return {'collision': False, 'bbo_updated': True}

    def cancel(self, order_ref: int, cancelled_shares: int) -> dict:
        """Partially or fully cancel a resting order (ITCH Cancel 'X').

        Reduces stored shares.  If shares reach 0, the entry is deleted and
        BBO is reset when the cancelled price matched the current BBO price.
        """
        h = crc17(order_ref)
        if h not in self.ref_table or self.ref_table[h]['order_ref'] != order_ref:
            return {'collision': False, 'bbo_updated': False}

        entry = self.ref_table[h]
        new_sh = max(0, entry['shares'] - (cancelled_shares & 0xFFFFFF))
        entry['shares'] = new_sh

        if new_sh == 0:
            del self.ref_table[h]
            self._bbo_clear_if_at_bbo(entry)

        return {'collision': False, 'bbo_updated': True}

    def delete(self, order_ref: int) -> dict:
        """Fully remove a resting order (ITCH Delete 'D').

        Resets BBO to 0 when the deleted price was the current BBO price.
        (Phase-1 simplified: no full rescan.)
        """
        h = crc17(order_ref)
        if h not in self.ref_table or self.ref_table[h]['order_ref'] != order_ref:
            return {'collision': False, 'bbo_updated': False}

        entry = self.ref_table.pop(h)
        self._bbo_clear_if_at_bbo(entry)
        return {'collision': False, 'bbo_updated': True}

    def replace(self, order_ref: int, new_order_ref: int,
                price: int, shares: int, side: int, sym_id: int) -> dict:
        """Atomic cancel + re-add (ITCH Replace 'U').

        Implements RTL non-blocking assignment semantics:
        - The BBO add check for the *new* order compares against the
          PRE-CLEAR BBO value (same as RTL reading bbo_bid/ask_price_r
          before any NBA takes effect).
        """
        h = crc17(order_ref)
        if h not in self.ref_table or self.ref_table[h]['order_ref'] != order_ref:
            return {'collision': False, 'bbo_updated': False}

        old_entry = self.ref_table.pop(h)
        old_side  = old_entry['side']
        old_price = old_entry['price']

        # Snapshot BBO before any changes (mirrors RTL pre-NBA read).
        pre_bid    = self.bbo_bid_price[sym_id]
        pre_bid_sz = self.bbo_bid_size[sym_id]
        pre_ask    = self.bbo_ask_price[sym_id]
        pre_ask_sz = self.bbo_ask_size[sym_id]

        # Delete logic: clear BBO if old order was at BBO price.
        new_bid    = 0            if (old_side == 1 and old_price == pre_bid)  else pre_bid
        new_bid_sz = 0            if (old_side == 1 and old_price == pre_bid)  else pre_bid_sz
        new_ask    = 0            if (old_side == 0 and old_price == pre_ask)  else pre_ask
        new_ask_sz = 0            if (old_side == 0 and old_price == pre_ask)  else pre_ask_sz

        # Add new ref entry. RTL writes new_order_ref unconditionally — no tag
        # check on the write path (collision detection is for *lookups* only,
        # per spec §4.3). Overwrite any occupying entry silently, exactly as
        # the DUT does with ref_mem[op_new_hash] <= {...}.
        nh = crc17(new_order_ref)
        self.ref_table[nh] = {
            'order_ref': new_order_ref,
            'price':     price,
            'shares':    shares & 0xFFFFFF,
            'side':      side,
            'sym_id':    sym_id,
        }

        # Add BBO logic: compare against PRE-CLEAR values (RTL NBA semantics).
        if side == 1:  # bid
            if price > pre_bid:
                new_bid    = price
                new_bid_sz = shares & 0xFFFFFF
        else:           # ask
            if pre_ask == 0 or price < pre_ask:
                new_ask    = price
                new_ask_sz = shares & 0xFFFFFF

        self.bbo_bid_price[sym_id] = new_bid
        self.bbo_bid_size[sym_id]  = new_bid_sz
        self.bbo_ask_price[sym_id] = new_ask
        self.bbo_ask_size[sym_id]  = new_ask_sz

        return {'collision': False, 'bbo_updated': True}

    def execute(self, order_ref: int, exec_shares: int) -> dict:
        """Reduce shares by executed amount (ITCH Execute 'E'/'C').

        Identical semantics to cancel: share reduction, BBO reset on full fill.
        """
        return self.cancel(order_ref, exec_shares)

    def get_bbo(self, sym_id: int):
        """Return (bid_price, ask_price, bid_size, ask_size) for sym_id."""
        return (
            self.bbo_bid_price[sym_id],
            self.bbo_ask_price[sym_id],
            self.bbo_bid_size[sym_id],
            self.bbo_ask_size[sym_id],
        )

    def find_collision_pair(self):
        """Find two 64-bit order_ref values that produce the same CRC-17.

        Iterates upward from 1 until a bucket collision is found.
        With 2^17 buckets, the birthday paradox guarantees a hit within ~450
        iterations on average.

        Returns
        -------
        tuple[int, int]
            (ref_a, ref_b) where crc17(ref_a) == crc17(ref_b).
        """
        seen = {}
        ref = 1
        while True:
            h = crc17(ref)
            if h in seen:
                return (seen[h], ref)
            seen[h] = ref
            ref += 1

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _bbo_clear_if_at_bbo(self, entry: dict) -> None:
        """Reset BBO to 0 when the deleted entry's price was the current BBO."""
        sym_id = entry['sym_id']
        if entry['side'] == 1:
            if entry['price'] == self.bbo_bid_price[sym_id]:
                self.bbo_bid_price[sym_id] = 0
                self.bbo_bid_size[sym_id]  = 0
        else:
            if entry['price'] == self.bbo_ask_price[sym_id]:
                self.bbo_ask_price[sym_id] = 0
                self.bbo_ask_size[sym_id]  = 0
