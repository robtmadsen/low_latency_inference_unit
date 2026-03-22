"""ITCH feeder — reads real ITCH binary data and drives via AXI4-Stream."""

import struct


class ITCHFeeder:
    """Parses an ITCH 5.0 binary file and feeds messages via AXI4-Stream driver.

    Message framing: 2-byte big-endian length prefix → N-byte body.
    """

    def __init__(self, axis_driver):
        self.axis = axis_driver

    def parse_file(self, path: str, msg_type_filter=None, max_messages=None):
        """Read ITCH binary file and return list of (length_prefix + body) messages.

        Args:
            path: Path to binary file
            msg_type_filter: If set, only return messages of this type byte (e.g. 0x41)
            max_messages: Maximum messages to return
        """
        messages = []
        with open(path, 'rb') as f:
            data = f.read()

        pos = 0
        while pos < len(data):
            if pos + 2 > len(data):
                break
            length = struct.unpack('>H', data[pos:pos+2])[0]
            if length == 0 or pos + 2 + length > len(data):
                break
            body = data[pos+2:pos+2+length]
            full_msg = data[pos:pos+2+length]  # length prefix + body
            pos += 2 + length

            if msg_type_filter is not None and body[0] != msg_type_filter:
                continue

            messages.append(full_msg)
            if max_messages and len(messages) >= max_messages:
                break

        return messages

    async def feed_messages(self, messages):
        """Send a list of raw ITCH messages via AXI4-Stream."""
        for msg in messages:
            await self.axis.send(msg)
