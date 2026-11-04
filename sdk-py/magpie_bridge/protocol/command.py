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

from enum import IntEnum


"""
    System command constants for Magpie Bridge.
    
    Each command is the ASCII bytes of its readable name packed big-endian
    (network byte order) into a 32-bit unsigned integer, e.g. "SYN?" = 0x53594E3F.
    Value 0 is reserved for the empty command (C=0, plain DATA).
"""


class Command(IntEnum):
    """ Reserved system command values (32-bit unsigned, big-endian strings). """

    # Handshake
    SYN = 0x53594E3F       # "SYN?"  first handshake request
    SYN_ACK = 0x53594E21   # "SYN!"  second handshake response
    ACK = 0x41434B21       # "ACK!"  third handshake confirm

    # Result
    FAIL = 0x4641494C      # "FAIL"
    DONE = 0x444F4E45      # "DONE"

    # Permit
    ACPT = 0x41435054      # "ACPT"   accept (add permit)
    DENY = 0x44454E59      # "DENY"   deny (remove permit)

    # Heartbeat
    PING = 0x50494E47      # "PING"
    PONG = 0x504F4E47      # "PONG"

    # Shutdown
    FIN = 0x46494E3F       # "FIN?"  first wave request
    FIN_ACK = 0x46494E21   # "FIN!"  second wave response

    NOOP = 0x4E4F4F50      # "NOOP"

    # Data
    DATA = 0x44415441      # "DATA"
    COPY = 0x434F5059      # "COPY"   data acknowledgement

    EMPTY = 0              # empty command: C=0, same meaning as "DATA"
