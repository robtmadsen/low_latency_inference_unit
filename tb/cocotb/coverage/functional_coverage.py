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

        self._total_sampled = 0

    def sample(self, msg_type=0x41, price=0, side='B'):
        """Sample a transaction into all coverpoints."""
        self.cp_msg_type.sample(msg_type)
        self.cp_price_range.sample(price)
        self.cp_side.sample(side)
        self.cross_price_side.sample(price, side)
        self._total_sampled += 1

    def is_covered(self, target_pct=100.0):
        """Check if all coverpoints and crosses meet target percentage."""
        return (self.cp_price_range.coverage_pct >= target_pct and
                self.cp_side.coverage_pct >= target_pct and
                self.cross_price_side.coverage_pct >= target_pct)

    def overall_pct(self):
        """Weighted average across all coverpoints and crosses."""
        items = [self.cp_msg_type, self.cp_price_range, self.cp_side,
                 self.cross_price_side]
        total_bins = sum(i.total_bins for i in items)
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
            ],
            'crosses': [
                self.cross_price_side.report(),
            ],
        }
