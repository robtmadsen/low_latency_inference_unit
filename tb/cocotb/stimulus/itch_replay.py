"""ITCH replay stimulus utilities."""


async def replay_itch_file(feeder, path, max_messages=None, msg_type_filter=None):
    """Top-level replay coroutine: parse file and feed via AXI4-Stream.

    Returns the list of messages that were sent.
    """
    messages = feeder.parse_file(
        path,
        msg_type_filter=msg_type_filter,
        max_messages=max_messages
    )
    await feeder.feed_messages(messages)
    return messages
