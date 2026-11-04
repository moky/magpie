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

""" Magpie Bridge (MP) — UDP relay messaging protocol SDK for Python.

    Re-exports here:

    * `protocol` subpackage — wire-format constants, header calculations,
      the Magpie / Packet interfaces and the reserved Command values;
    * packet classes — MessagePacket, BasePacket, ReliablePacket,
      DirectPacket, BridgePacket, plus the pluggable MacGenerator /
      HmacSha256 utilities;
    * factories — MessagePacketFactory (shared datagram validation) and
      the per-kind instruction factories (BridgePacketFactory,
      DirectPacketFactory).

    See docs/protocol.md for the wire format.
"""

from .protocol import *

from .packet import MessagePacket
from .reliable import BasePacket, ReliablePacket
from .direct_packet import DirectPacket
from .bridge_packet import BridgePacket

from .packet_factory import MessagePacketFactory
from .direct_factory import DirectPacketFactory
from .bridge_factory import BridgePacketFactory

from .x import MacGenerator, HmacSha256


__all__ = [

    'Magpie', 'Packet',

    'Command',

    'MAGIC_CODE',
    'MIN_HEADER_LENGTH', 'MAX_HEADER_LENGTH', 'MAX_PAYLOAD_LENGTH',
    'ATTACHMENT_LENGTH',
    'MSS',

    'calc_type',
    'calc_header_length',
    'calc_cmd',
    'calc_dsn',
    'calc_ext',

    #
    #   Magpie Packet
    #

    'MessagePacket',
    'BasePacket', 'ReliablePacket',
    'DirectPacket',
    'BridgePacket',

    'MacGenerator', 'HmacSha256',

    'MessagePacketFactory',
    'DirectPacketFactory',
    'BridgePacketFactory',

]
