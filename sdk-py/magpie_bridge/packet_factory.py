# -*- coding: utf-8 -*-
#
#   Magpie Bridge Messaging Protocol
#
#                               Written in 2026 by Moky <albert.moky@gmail.com>
#
# ==============================================================================
# MIT License
#
# Copyright (c) 2026 Albert Moky
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ==============================================================================

from typing import Optional

from .protocol import Packet
from .protocol import MAGIC_CODE, MIN_HEADER_LENGTH, MSS
from .protocol import ATTACHMENT_LENGTH
from .protocol import calc_header_length

from .packet import MessagePacket


class MessagePacketFactory:
    """ Validate a raw datagram and decode its header fields.

        Shared by BridgePacketFactory and DirectPacketFactory: performs the
        magic-code check, E-width range, header-length formula and per-field
        bounds. Returns None on any violation. The caller then applies the
        B-bit filter and the tail (attachment) rule.
    """

    def parse(self, data: bytes) -> Optional[Packet]:
        """ Validate a raw datagram and decode its header fields.

            Shared by BridgePacketFactory and DirectPacketFactory: performs
            the magic-code check, E-width range, header-length formula and
            per-field bounds. Returns None on any violation. The caller then
            applies the B-bit filter and the tail (attachment) rule.

            Args:
                data: raw UDP datagram to parse.

            Returns:
                A validated MessagePacket, or None if the datagram is invalid.
        """
        buffer_length = len(data)
        if buffer_length < MIN_HEADER_LENGTH:
            # UDP datagram must hold at least the fixed 8-byte prefix.
            return None
        elif buffer_length > MSS:
            # MSS hard cap: header + payload (+ attachment) <= 1232.
            return None

        # 1. Magic code.
        if data[0:4] != MAGIC_CODE:
            return None

        # 2. Type byte.
        type_byte = data[4]
        h_len = data[5]
        p_len = (data[6] << 8) | data[7]   # 2 bytes, big-endian

        # flags
        ack = (type_byte >> 7) & 0x01
        bid = (type_byte >> 6) & 0x01
        cmd = (type_byte >> 5) & 0x01
        dsn = (type_byte >> 4) & 0x01
        ext = type_byte & 0x07

        # E must be 0..4 (5/6/7 are invalid); E>0 requires D=1.
        if ext > 4:
            return None
        elif ext > 0 and dsn == 0:
            return None

        # Header length must match the formula.
        if h_len != calc_header_length(bid=bid, cmd=cmd, dsn=dsn, ext=ext):
            return None

        # tail < 0: the datagram cannot even hold the declared header + payload.
        # Check before reading the variable-length fields below, otherwise a
        # truncated packet with a long declared header throws instead of
        # being silently dropped (300:195-201).
        size = h_len + p_len
        tail = buffer_length - size
        if tail == ATTACHMENT_LENGTH:
            # cut the tail here
            data = data[:size]
        elif tail != 0:
            # tail is neither 0 nor 32: bad packet.
            return None

        # 3. Read header fields and validate them.
        target = 0
        source = 0
        sn = 0
        index = 0
        count = 1
        command = 0

        offset = MIN_HEADER_LENGTH
        if bid != 0:
            target = _read_uint32(data=data, offset=offset)
            offset += 4
            source = _read_uint32(data=data, offset=offset)
            offset += 4
        if dsn != 0:
            sn = _read_uint32(data=data, offset=offset)
            offset += 4
            if sn == 0:
                # D=1 implies sn != 0.
                return None
        if ext > 0:
            index = _read_ext(data=data, offset=offset, width=ext)
            offset += ext
            count = _read_ext(data=data, offset=offset, width=ext)
            offset += ext
            if index >= count or count < 2:
                # 0 <= index < count; count must be > 1 when E>0.
                return None
        if cmd != 0:
            command = _read_uint32(data=data, offset=offset)
            offset += 4
            if command == 0:
                # C=1 implies command != 0.
                return None

        # Tail: attachment decision.
        payload = data[h_len:size]

        return MessagePacket(
            data,
            ack=ack,
            bid=bid,
            cmd=cmd,
            dsn=dsn,
            ext=ext,
            header_length=h_len,
            payload_length=p_len,
            target=target,
            source=source,
            sn=sn,
            index=index,
            count=count,
            command=command,
            payload=payload,
        )


#
#   byte helpers
#

def _read_uint32(data: bytes, offset: int) -> int:
    """ Read a big-endian unsigned 32-bit integer. """
    value = data[offset:offset + 4]
    return int.from_bytes(value, 'big')


def _read_ext(data: bytes, offset: int, width: int) -> int:
    """ Read a big-endian unsigned integer of width bytes (1, 2, 3 or 4). """
    value = data[offset:offset + width]
    return int.from_bytes(value, 'big')
