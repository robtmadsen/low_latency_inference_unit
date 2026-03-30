"""Functional coverage — coverpoints and cross-coverage bins in Python.

Coverpoints: message_type, price_range, side
Cross-coverage: price_range x side
"""

import json


class Coverpoint:
    """A single coverpoint with named bins."""

    def __init__(self, name, bins):
        """
        Args:
            name: Coverpoint name (e.g. 'price_range').
            bins: dict mapping bin_name → predicate(value) -> bool,
                  or dict mapping bin_name → (lo, hi) tuple for range bins.
        """
        self.name = name
        self._bins = {}
        self._counts = {}
        for bin_name, spec in bins.items():
            if isinstance(spec, tuple) and len(spec) == 2:
                lo, hi = spec
                self._bins[bin_name] = lambda v, lo=lo, hi=hi: lo <= v <= hi
            elif callable(spec):
                self._bins[bin_name] = spec
            else:
                self._bins[bin_name] = lambda v, s=spec: v == s
            self._counts[bin_name] = 0

    def sample(self, value):
        """Increment counts for all bins matching value."""
        for bin_name, pred in self._bins.items():
            if pred(value):
                self._counts[bin_name] += 1

    @property
    def total_bins(self):
        return len(self._bins)

    @property
    def covered_bins(self):
        return sum(1 for c in self._counts.values() if c > 0)

    @property
    def coverage_pct(self):
        if self.total_bins == 0:
            return 100.0
        return 100.0 * self.covered_bins / self.total_bins

    def report(self):
        return {
            'name': self.name,
            'total_bins': self.total_bins,
            'covered_bins': self.covered_bins,
            'coverage_pct': self.coverage_pct,
            'bins': {k: v for k, v in self._counts.items()},
        }


class CrossCoverage:
    """Cross-coverage between two coverpoints — tracks (bin_a, bin_b) pairs."""

    def __init__(self, name, cp_a, cp_b):
        self.name = name
        self.cp_a = cp_a
        self.cp_b = cp_b
        self._counts = {}
        for a_name in cp_a._bins:
            for b_name in cp_b._bins:
                self._counts[(a_name, b_name)] = 0

    def sample(self, val_a, val_b):
        for a_name, a_pred in self.cp_a._bins.items():
            if a_pred(val_a):
                for b_name, b_pred in self.cp_b._bins.items():
                    if b_pred(val_b):
                        self._counts[(a_name, b_name)] += 1

    @property
    def total_bins(self):
        return len(self._counts)

    @property
    def covered_bins(self):
        return sum(1 for c in self._counts.values() if c > 0)

    @property
    def coverage_pct(self):
        if self.total_bins == 0:
            return 100.0
        return 100.0 * self.covered_bins / self.total_bins

    def report(self):
        return {
            'name': self.name,
            'total_bins': self.total_bins,
            'covered_bins': self.covered_bins,
            'coverage_pct': self.coverage_pct,
            'bins': {f"{a}×{b}": v for (a, b), v in self._counts.items()},
        }


class FunctionalCoverage:
    """Top-level coverage collector for the LLIU pipeline.

    Coverpoints:
        - message_type: add_order (always 'A' for now)
        - price_range: penny (1-99), dollar (100-9999), large (10000+)
        - side: buy, sell

    MoldUDP64 CoverGroup (new — kc705 integration):
        - seq_state: accepted, dropped_gap, dropped_dup
        - msg_count: single (1), burst (2-15), max_burst (16+)
        Cross: seq_state × msg_count

    SymbolFilter CoverGroup (new — kc705 integration):
        - cam_result: hit, miss
        - cam_index: lo (0-15), mid (16-47), hi (48-63)
        - back_to_back: isolated, consecutive

    EthAxisRxWrap CoverGroup (new — kc705 integration):
        - drop_event: no_drop, dropped
        - dropped_frames: zero (0), low (1-9), high (10+)

    Cross-coverage:
        - price_range × side
    """

    def __init__(self):
        self.cp_msg_type = Coverpoint('message_type', {
            'add_order': 0x41,
        })

        self.cp_price_range = Coverpoint('price_range', {
            'penny':  (1, 99),
            'dollar': (100, 9999),
            'large':  (10000, 500000),
        })

        self.cp_side = Coverpoint('side', {
            'buy':  lambda v: v == 'B' or v == 1,
            'sell': lambda v: v == 'S' or v == 0,
        })

        self.cross_price_side = CrossCoverage(
            'price_range×side', self.cp_price_range, self.cp_side)

        # ── MoldUDP64 CoverGroup ──────────────────────────────────────────
        self.cp_seq_state = Coverpoint('seq_state', {
            'accepted':     lambda v: v == 'accepted',
            'dropped_gap':  lambda v: v == 'dropped_gap',
            'dropped_dup':  lambda v: v == 'dropped_dup',
        })

        self.cp_msg_count = Coverpoint('msg_count', {
            'single':    (1,  1),
            'burst':     (2,  15),
            'max_burst': (16, 65535),
        })

        self.cross_seq_msg = CrossCoverage(
            'seq_state×msg_count', self.cp_seq_state, self.cp_msg_count)

        # ── SymbolFilter CoverGroup ───────────────────────────────────────
        self.cp_cam_result = Coverpoint('cam_result', {
            'hit':  lambda v: v is True  or v == 1,
            'miss': lambda v: v is False or v == 0,
        })

        self.cp_cam_index = Coverpoint('cam_index', {
            'lo':  (0,  15),
            'mid': (16, 47),
            'hi':  (48, 63),
        })

        self.cp_back_to_back = Coverpoint('back_to_back', {
            'isolated':   lambda v: v is False or v == 0,
            'consecutive': lambda v: v is True  or v == 1,
        })

        # ── EthAxisRxWrap CoverGroup ──────────────────────────────────────
        self.cp_drop_event = Coverpoint('drop_event', {
            'no_drop': lambda v: v is False or v == 0,
            'dropped': lambda v: v is True  or v == 1,
        })

        self.cp_dropped_frames = Coverpoint('dropped_frames', {
            'zero': (0, 0),
            'low':  (1, 9),
            'high': (10, 0x7FFFFFFF),
        })

        self._total_sampled = 0

    # ── Sampling methods ──────────────────────────────────────────────────

    def sample(self, msg_type=0x41, price=0, side='B'):
        """Sample a core transaction into price/side coverpoints."""
        self.cp_msg_type.sample(msg_type)
        self.cp_price_range.sample(price)
        self.cp_side.sample(side)
        self.cross_price_side.sample(price, side)
        self._total_sampled += 1

    def sample_moldupp64(self, seq_state: str, msg_count: int):
        """Sample a MoldUDP64 datagram event.

        Args:
            seq_state: 'accepted', 'dropped_gap', or 'dropped_dup'
            msg_count: number of ITCH messages in this datagram (1-65535)
        """
        self.cp_seq_state.sample(seq_state)
        self.cp_msg_count.sample(msg_count)
        self.cross_seq_msg.sample(seq_state, msg_count)

    def sample_symbol_filter(self, hit: bool, cam_index: int, back_to_back: bool):
        """Sample a symbol-filter lookup result.

        Args:
            hit:          True if the symbol matched a CAM entry
            cam_index:    Index of the matched entry (0-63); any value if miss
            back_to_back: True if this lookup immediately followed another valid_stock
        """
        self.cp_cam_result.sample(hit)
        self.cp_cam_index.sample(cam_index)
        self.cp_back_to_back.sample(back_to_back)

    def sample_eth_drop(self, dropped: bool, total_dropped_frames: int):
        """Sample an Ethernet frame-drop event from eth_axis_rx_wrap.

        Args:
            dropped:              True if a frame was dropped this cycle
            total_dropped_frames: current value of dropped_frames counter
        """
        self.cp_drop_event.sample(dropped)
        self.cp_dropped_frames.sample(total_dropped_frames)

    # ── Aggregation ───────────────────────────────────────────────────────

    def is_covered(self, target_pct=100.0):
        """Check if all coverpoints and crosses meet target percentage."""
        return (self.cp_price_range.coverage_pct >= target_pct and
                self.cp_side.coverage_pct >= target_pct and
                self.cross_price_side.coverage_pct >= target_pct and
                self.cp_seq_state.coverage_pct >= target_pct and
                self.cp_msg_count.coverage_pct >= target_pct and
                self.cross_seq_msg.coverage_pct >= target_pct and
                self.cp_cam_result.coverage_pct >= target_pct and
                self.cp_cam_index.coverage_pct >= target_pct and
                self.cp_drop_event.coverage_pct >= target_pct)

    def overall_pct(self):
        """Weighted average across all coverpoints and crosses."""
        items = [
            self.cp_msg_type, self.cp_price_range, self.cp_side,
            self.cross_price_side,
            self.cp_seq_state, self.cp_msg_count, self.cross_seq_msg,
            self.cp_cam_result, self.cp_cam_index, self.cp_back_to_back,
            self.cp_drop_event, self.cp_dropped_frames,
        ]
        total_bins   = sum(i.total_bins   for i in items)
        covered_bins = sum(i.covered_bins for i in items)
        if total_bins == 0:
            return 100.0
        return 100.0 * covered_bins / total_bins

    def report(self):
        return {
            'total_sampled': self._total_sampled,
            'overall_coverage_pct': self.overall_pct(),
            'coverpoints': [
                self.cp_msg_type.report(),
                self.cp_price_range.report(),
                self.cp_side.report(),
                # MoldUDP64
                self.cp_seq_state.report(),
                self.cp_msg_count.report(),
                # SymbolFilter
                self.cp_cam_result.report(),
                self.cp_cam_index.report(),
                self.cp_back_to_back.report(),
                # EthAxisRxWrap
                self.cp_drop_event.report(),
                self.cp_dropped_frames.report(),
            ],
            'crosses': [
                self.cross_price_side.report(),
                self.cross_seq_msg.report(),
            ],
        }
