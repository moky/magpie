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

""" Protocol layer: wire-format constants, header calculations and the
    Magpie / Packet interfaces.

    Import this module when you only need the wire format primitives
    (constants, calculators, command values, interfaces), without the
    concrete packet classes. See docs/protocol.md for the wire format.
"""

from .magpie import Magpie, Packet
from .command import Command

from .protocol import MAGIC_CODE
from .protocol import MIN_HEADER_LENGTH, MAX_HEADER_LENGTH, MAX_PAYLOAD_LENGTH
from .protocol import ATTACHMENT_LENGTH
from .protocol import MSS
from .protocol import calc_type, calc_header_length, calc_cmd, calc_dsn, calc_ext


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

]
