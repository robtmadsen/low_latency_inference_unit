"""Scoreboard — compares expected vs actual inference results."""


class Scoreboard:
    """Queue-based scoreboard for comparing golden model predictions with DUT output."""

    def __init__(self, tolerance=1e-3):
        self.expected = []
        self.actual = []
        self.results = []  # list of (expected, actual, match)
        self.tolerance = tolerance
        self.mismatches = 0
        self.total = 0

    def add_expected(self, value):
        self.expected.append(value)

    def add_actual(self, value):
        self.actual.append(value)

    def check(self):
        """Compare all queued expected/actual pairs."""
        while self.expected and self.actual:
            exp = self.expected.pop(0)
            act = self.actual.pop(0)
            self.total += 1

            if abs(exp) < 1e-10:
                match = abs(act) < self.tolerance
            else:
                match = abs(act - exp) / max(abs(exp), 1e-10) < self.tolerance

            self.results.append((exp, act, match))
            if not match:
                self.mismatches += 1

    def report(self) -> str:
        lines = [f"Scoreboard: {self.total} checked, {self.mismatches} mismatches"]
        for exp, act, match in self.results:
            status = "OK" if match else "MISMATCH"
            lines.append(f"  {status}: expected={exp:.6f}, actual={act:.6f}")
        return "\n".join(lines)

    @property
    def passed(self) -> bool:
        return self.mismatches == 0 and self.total > 0
