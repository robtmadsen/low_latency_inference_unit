"""Constrained-random ITCH Add Order generator for coverage-driven testing."""

import random
import struct

from utils.itch_decoder import encode_add_order


class ConstrainedRandomITCH:
    """Generates random valid ITCH Add Order messages with configurable constraints.

    Constraints:
        price_range: 'penny' (1-99), 'dollar' (100-9999), 'large' (10000+), or None (any)
        side_bias: probability of buy (0.0-1.0), default 0.5
        stock_pool: list of stock symbols to choose from
    """

    PRICE_RANGES = {
        'penny':  (1, 99),
        'dollar': (100, 9999),
        'large':  (10000, 500000),
    }

    DEFAULT_STOCKS = ["AAPL    ", "MSFT    ", "GOOG    ", "TSLA    ",
                      "AMZN    ", "NVDA    ", "META    ", "NFLX    "]

    def __init__(self, seed=42):
        self.rng = random.Random(seed)
        self._order_ref_counter = 1

    def generate_add_order(self, price_range=None, side_bias=0.5,
                           stock_pool=None) -> bytes:
        """Generate a single random valid Add Order message.

        Args:
            price_range: One of 'penny', 'dollar', 'large', or None for uniform across all.
            side_bias: Probability of generating a buy order (1.0=all buys, 0.0=all sells).
            stock_pool: List of 8-char stock symbols. Defaults to DEFAULT_STOCKS.

        Returns:
            Encoded ITCH Add Order bytes with length prefix.
        """
        if price_range is not None:
            lo, hi = self.PRICE_RANGES[price_range]
        else:
            lo, hi = 1, 500000
        price = self.rng.randint(lo, hi)

        side = 'B' if self.rng.random() < side_bias else 'S'
        shares = self.rng.choice([1, 10, 50, 100, 200, 500, 1000, 5000])
        stocks = stock_pool or self.DEFAULT_STOCKS
        stock = self.rng.choice(stocks)

        order_ref = self._order_ref_counter
        self._order_ref_counter += 1

        timestamp = self.rng.randint(0, 2**47)

        return encode_add_order(
            order_ref=order_ref,
            side=side,
            price=price,
            stock=stock,
            shares=shares,
            timestamp=timestamp,
        )

    def generate_stream(self, count, price_range=None, side_bias=0.5,
                        stock_pool=None) -> list:
        """Generate a batch of random Add Order messages.

        Returns:
            List of encoded ITCH Add Order byte strings.
        """
        return [
            self.generate_add_order(price_range=price_range,
                                    side_bias=side_bias,
                                    stock_pool=stock_pool)
            for _ in range(count)
        ]
