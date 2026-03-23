"""Latency profiler — measures cycle-accurate pipeline latency and jitter.

Records ingress (AXI4-Stream handshake) and egress (result valid) timestamps,
then computes min/max/mean/median/p99/stddev statistics.
"""

import math
import statistics


class LatencyProfiler:
    """Cycle-accurate latency measurement between ingress and egress events.

    Usage:
        profiler = LatencyProfiler()
        profiler.record_ingress(msg_id, cycle)
        ...
        profiler.record_egress(msg_id, cycle)
        stats = profiler.report()
    """

    def __init__(self):
        self._ingress = {}   # msg_id → cycle
        self._latencies = [] # completed latency measurements
        self._dropped = 0    # egress without matching ingress

    def record_ingress(self, msg_id, cycle: int):
        """Record the cycle when a message enters the pipeline."""
        self._ingress[msg_id] = cycle

    def record_egress(self, msg_id, cycle: int):
        """Record the cycle when a message's result is ready."""
        if msg_id in self._ingress:
            latency = cycle - self._ingress.pop(msg_id)
            self._latencies.append(latency)
        else:
            self._dropped += 1

    @property
    def latencies(self):
        return list(self._latencies)

    @property
    def count(self):
        return len(self._latencies)

    def report(self) -> dict:
        """Compute latency statistics. Returns dict with min/max/mean/median/p99/stddev."""
        if not self._latencies:
            return {"count": 0}

        sorted_lat = sorted(self._latencies)
        n = len(sorted_lat)

        result = {
            "count":  n,
            "min":    sorted_lat[0],
            "max":    sorted_lat[-1],
            "mean":   statistics.mean(sorted_lat),
            "median": statistics.median(sorted_lat),
            "p50":    sorted_lat[n // 2],
            "p99":    sorted_lat[min(int(n * 0.99), n - 1)],
            "stddev": statistics.stdev(sorted_lat) if n > 1 else 0.0,
            "dropped": self._dropped,
        }
        return result

    def histogram(self, bins=10) -> str:
        """Return a text histogram of latency distribution."""
        if not self._latencies:
            return "No latency data"

        lo = min(self._latencies)
        hi = max(self._latencies)

        if lo == hi:
            return f"All {len(self._latencies)} samples = {lo} cycles"

        bin_width = max(1, (hi - lo + bins) // bins)
        counts = [0] * bins
        for lat in self._latencies:
            idx = min((lat - lo) // bin_width, bins - 1)
            counts[int(idx)] += 1

        lines = []
        max_count = max(counts) if counts else 1
        for i, c in enumerate(counts):
            lo_edge = lo + i * bin_width
            hi_edge = lo_edge + bin_width - 1
            bar = "#" * max(1, int(40 * c / max_count)) if c > 0 else ""
            lines.append(f"  [{lo_edge:5d}-{hi_edge:5d}] {c:4d} {bar}")
        return "\n".join(lines)

    def format_report(self) -> str:
        """Human-readable summary string."""
        stats = self.report()
        if stats["count"] == 0:
            return "LatencyProfiler: no data"

        return (
            f"LatencyProfiler: {stats['count']} samples\n"
            f"  min={stats['min']} max={stats['max']} "
            f"mean={stats['mean']:.1f} median={stats['median']:.1f}\n"
            f"  p50={stats['p50']} p99={stats['p99']} "
            f"stddev={stats['stddev']:.2f}"
        )
