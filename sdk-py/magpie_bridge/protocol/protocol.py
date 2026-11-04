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

""" Magpie Bridge protocol constants and header calculations.

    See docs/protocol.md for the wire format.
"""


#  Magic Code: 'M' 'P' '\0' '\1'  (Messaging Protocol v1)
MAGIC_CODE = b'MP\x00\x01'

#
#   Size limits
#

MIN_HEADER_LENGTH = 8      # Fixed header size: magic(4) + type(1) + headerLen(1) + payloadLen(2)
MAX_HEADER_LENGTH = 32     # Maximum header size (all optional fields present, E=4)
MAX_PAYLOAD_LENGTH = 1024  # Suggested payload cap on the sender side (bytes).
ATTACHMENT_LENGTH = 32     # Attachment length: HMAC-SHA256, 32 bytes.

# Max datagram size (IPv6 minimum MTU 1280 - 40 ipv6 header - 8 udp header)
MSS = 1232                 # MSS hard cap: header + payload (+ attachment) <= 1232.


#
#   Calculations
#

def calc_type(*, ack: int, bid: int, cmd: int, dsn: int, ext: int) -> int:
    """ Compose the type byte: A(7) B(6) C(5) D(4) E(low 3 bits). """
    return ((ack & 1) << 7) | ((bid & 1) << 6) | ((cmd & 1) << 5) \
        | ((dsn & 1) << 4) | (ext & 0x07)


def calc_header_length(*, bid: int, cmd: int, dsn: int, ext: int) -> int:
    """ Header length: N = 8 + 8*B + 4*D + 2*E + 4*C. """
    return MIN_HEADER_LENGTH + 8 * (bid & 1) + 4 * (dsn & 1) + 2 * ext + 4 * (cmd & 1)


def calc_cmd(*, command: int) -> int:
    """ C flag: command == 0 => C=0 (plain DATA). """
    return 0 if command == 0 else 1


def calc_dsn(*, sn: int) -> int:
    """ D flag: sn == 0 => D=0 (system command). """
    return 0 if sn == 0 else 1


def calc_ext(*, count: int) -> int:
    """ E width: count >= 65536 => 4; count >= 2 => 2; else 0. """
    if count >= 65536:
        return 4
    if count >= 2:
        return 2
    assert count == 1, 'packet count error: %d' % count
    return 0
