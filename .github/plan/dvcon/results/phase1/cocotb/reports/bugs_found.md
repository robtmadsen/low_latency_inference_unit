No RTL bugs detected.

All scoreboard checks across every cocotb test passed (TESTS=9 PASS=9 FAIL=0).
The DUT's registered outputs match the independent Python reference model on
every transaction for:
  - Add Order (0x41) messages, both buy ('B'=0x42) and sell ('S'=0x53) sides
  - Add Order with non-'B' / non-'S' bytes in byte 19 (side correctly = 0)
  - Non-Add-Order message types ('B', 'C', 'D', 'E', 'F', 'P', 'U', 'X', 0x00, 0xFF)
  - msg_valid=0 with arbitrary msg_data (fields_valid stays 0)
  - Synchronous active-high reset (all outputs return to 0)
  - Reset asserted while a valid message is on the bus (reset wins)
  - Back-to-back valid messages (32 consecutive cycles, no idle)
  - Random mixed traffic (80 cycles of mixed types and idle)

The RTL behavior matches the spec verbatim, including:
  - 1-cycle pipeline latency from msg_valid → fields_valid
  - fields_valid = msg_valid && (message_type == 0x41)
  - Big-endian decoding of order_ref (bytes 11-18), price (bytes 32-35)
  - Stock symbol byte slice (bytes 24-31)
