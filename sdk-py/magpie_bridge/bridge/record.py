# -*- coding: utf-8 -*-
#
#   Magpie Bridge
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

import socket as socket_module
import struct
import time
from typing import List, Optional

from .utils import SocketAddress, socket_identity_hash

#  wildcard marker [1, 2, 3] (clear / allow-all)
ALLOW_ALL_BIDS = (1, 2, 3)

#
#  record buffer layout (see design/220): 80-byte header + slot area.
#  All multi-byte fields are big-endian (network byte order).
#

HEADER_SIZE = 80
SLOT_SIZE = 8

OFF_SECRET = 0
OFF_BID = 32
OFF_HASH31 = 36
OFF_IP = 40
OFF_PORT = 56
OFF_OFFLINE = 59
OFF_LAST_TIME = 60
OFF_LAST_NOOP = 68
OFF_CNT = 78


def _ip_bytes(ip: str) -> bytes:
    """16-byte big-endian IP: IPv6 verbatim, IPv4 prefix-packed."""
    try:
        if ':' in ip:
            return socket_module.inet_pton(socket_module.AF_INET6, ip)
        packed = socket_module.inet_pton(socket_module.AF_INET, ip)
        return packed + b'\x00' * 12
    except (OSError, ValueError):
        # malformed address: zero-filled
        return b'\x00' * 16


class PermitView:
    """A temporary writable view over one permit slot (not pooled).

    The view holds the record buffer + slot offset; accept() toggles the
    valid bit (bit0 of the value word, big-endian) and writes it back.
    In wildcard state it is a read-only virtual permit (match always true).
    """

    __slots__ = ['__owner', '__bid', '__hash31', '__valid', '__virtual',
                 '__buffer', '__offset']

    def __init__(self, owner: 'Record', bid: int, hash31: int, valid: bool,
                 virtual: bool = False,
                 buffer: Optional[bytearray] = None, offset: int = -1):
        super().__init__()
        self.__owner = owner
        self.__bid = bid
        self.__hash31 = hash31
        self.__valid = valid
        self.__virtual = virtual
        self.__buffer = buffer
        self.__offset = offset

    @property
    def bid(self) -> int:
        """ The peer bid this permit entry points to. """
        return self.__bid

    @property
    def hash31(self) -> int:
        """ The peer's socket identity hash (31-bit). """
        return self.__hash31

    @property
    def valid(self) -> bool:
        """ Whether the permit is confirmed by both sides. """
        return self.__valid

    def match(self, record: 'Record') -> bool:
        """True if the record is one of the two parties of this permit."""
        if self.__virtual:
            return True
        return self.__owner.socket == record.socket or self.__hash31 == record.hash31

    def accept(self, record: 'Record') -> bool:
        """Cross-side confirmation: set the valid bit (slot write-back)."""
        if not self.match(record):
            return False
        if self.__virtual:
            # wildcard view: no slot to write, just report success
            return True
        self.__valid = True
        # value occupies buffer[offset+4 .. offset+7]; big-endian, bit0 of
        # the last byte toggled on (valid)
        if self.__buffer is not None and self.__offset >= 0:
            self.__buffer[self.__offset + 7] |= 1
        return True


class Record:
    """A bid record in the server allocation table.

    Record fields live in a single fixed-length byte buffer (80-byte header
    + slot area), see design/220: secret(32) @0, bid(4) @32, hash31(4) @36,
    ip(16) @40, port(2) @56, reserved @58, offline(1) @59,
    last_time(8 double) @60, last_noop_time(8 double) @68, reserved(2) @76,
    cnt(2) @78. Slots follow at 80+i*8: {bid(4), value(4 = hash31|valid)}.
    All multi-byte fields are big-endian. The socket object is the only
    persistent object reference (key() derives from it).
    """

    __slots__ = ['__socket', '__buffer', '__slot_capacity']

    def __init__(self, bid: int, socket: SocketAddress, secret: bytes,
                 max_entries: int = 256):
        super().__init__()
        if len(secret) != 32:
            raise ValueError('secret must be 32 bytes')
        self.__socket = socket
        self.__slot_capacity = int(max_entries)
        buf = bytearray(HEADER_SIZE + self.__slot_capacity * SLOT_SIZE)
        self.__buffer: bytearray = buf
        # secret
        buf[OFF_SECRET:OFF_SECRET + 32] = secret
        # bid (unsigned 32)
        buf[OFF_BID:OFF_BID + 4] = struct.pack('>I', int(bid))
        # hash31 (own socket identity hash)
        buf[OFF_HASH31:OFF_HASH31 + 4] = struct.pack('>I', socket_identity_hash(socket.key()))
        # ip (16 bytes)
        buf[OFF_IP:OFF_IP + 16] = _ip_bytes(socket.ip)
        # port
        buf[OFF_PORT:OFF_PORT + 2] = struct.pack('>H', int(socket.port))
        # offline = 0, cnt = 0
        buf[OFF_OFFLINE] = 0
        buf[OFF_CNT:OFF_CNT + 2] = struct.pack('>H', 0)
        # times (last_noop_time = 0.0: the NOOP immunity window counts as
        # elapsed until the client actually sends a NOOP)
        now = time.time()
        buf[OFF_LAST_TIME:OFF_LAST_TIME + 8] = struct.pack('>d', now)
        buf[OFF_LAST_NOOP:OFF_LAST_NOOP + 8] = struct.pack('>d', 0.0)

    #
    #   identity (immutable)
    #

    @property
    def socket(self) -> SocketAddress:
        return self.__socket

    @property
    def key(self) -> str:
        """Socket key string used as the allocation-table index."""
        return self.__socket.key()

    @property
    def bid(self) -> int:
        return struct.unpack('>I', bytes(self.__buffer[OFF_BID:OFF_BID + 4]))[0]

    @property
    def secret(self) -> bytes:
        return bytes(self.__buffer[OFF_SECRET:OFF_SECRET + 32])

    @property
    def hash31(self) -> int:
        return struct.unpack('>I', bytes(self.__buffer[OFF_HASH31:OFF_HASH31 + 4]))[0]

    #
    #   lifecycle
    #

    @property
    def offline(self) -> bool:
        return self.__buffer[OFF_OFFLINE] != 0

    def set_offline(self):
        self.__buffer[OFF_OFFLINE] = 1

    def clear_offline(self):
        self.__buffer[OFF_OFFLINE] = 0

    @property
    def last_time(self) -> float:
        return struct.unpack('>d',
                             bytes(self.__buffer[OFF_LAST_TIME:OFF_LAST_TIME + 8]))[0]

    def touch(self, now: float):
        self.__buffer[OFF_LAST_TIME:OFF_LAST_TIME + 8] = struct.pack('>d', now)

    @property
    def last_noop_time(self) -> float:
        return struct.unpack('>d',
                             bytes(self.__buffer[OFF_LAST_NOOP:OFF_LAST_NOOP + 8]))[0]

    def update_noop_time(self, now: float):
        self.__buffer[OFF_LAST_NOOP:OFF_LAST_NOOP + 8] = struct.pack('>d', now)

    #
    #   slot area helpers
    #

    def _get_cnt(self) -> int:
        return struct.unpack('>H', bytes(self.__buffer[OFF_CNT:OFF_CNT + 2]))[0]

    def _set_cnt(self, n: int):
        self.__buffer[OFF_CNT:OFF_CNT + 2] = struct.pack('>H', int(n))

    # noinspection PyMethodMayBeStatic
    def _slot_offset(self, i: int) -> int:
        return HEADER_SIZE + i * SLOT_SIZE

    def _slot_bid(self, i: int) -> int:
        off = self._slot_offset(i)
        return struct.unpack('>I', bytes(self.__buffer[off:off + 4]))[0]

    def _slot_value(self, i: int) -> int:
        off = self._slot_offset(i) + 4
        return struct.unpack('>I', bytes(self.__buffer[off:off + 4]))[0]

    def _write_slot(self, i: int, bid: int, value: int):
        off = self._slot_offset(i)
        self.__buffer[off:off + 4] = struct.pack('>I', int(bid))
        self.__buffer[off + 4:off + 8] = struct.pack('>I', int(value))

    @property
    def permit_count(self) -> int:
        return self._get_cnt()

    #
    #   allowlist interface (external code must use these wrappers)
    #

    def is_allow_all(self) -> bool:
        """True when cnt == 3 and slots 0/1/2 hold bids 1, 2, 3."""
        if self._get_cnt() != 3:
            return False
        return self._slot_bid(0) == 1 and self._slot_bid(1) == 2 \
            and self._slot_bid(2) == 3

    def _find_slot(self, bid: int) -> int:
        """Binary search: slot index, or -(insertion point)-1."""
        lo, hi = 0, self._get_cnt() - 1
        while lo <= hi:
            mid = (lo + hi) // 2
            mb = self._slot_bid(mid)
            if mb < bid:
                lo = mid + 1
            elif mb > bid:
                hi = mid - 1
            else:
                return mid
        return -(lo + 1)

    def search_permit(self, record: 'Record') -> Optional[PermitView]:
        """Find the permit for record.bid (valid + match checked by caller)."""
        if self.is_allow_all():
            return PermitView(self, record.bid, record.hash31, True,
                              virtual=True)
        idx = self._find_slot(record.bid)
        if idx < 0:
            return None
        off = self._slot_offset(idx)
        value = self._slot_value(idx)
        return PermitView(self, self._slot_bid(idx), value & 0xFFFFFFFE,
                          bool(value & 1), virtual=False,
                          buffer=self.__buffer, offset=off)

    def insert_permit(self, record: 'Record', view: PermitView) -> bool:
        """Insert a permit for record; False if the allowlist is full."""
        cnt = self._get_cnt()
        if cnt >= self.__slot_capacity:
            return False
        bid = record.bid
        if view.bid == bid:
            value = view.hash31 | (1 if view.valid else 0)
        else:
            # the other side already accepted (or wildcard init): valid=1
            value = record.hash31 | (1 if view.valid else 0)
        idx = self._find_slot(bid)
        if idx >= 0:
            # overwrite existing
            self._write_slot(idx, bid, value)
            return True
        at = -(idx + 1)
        # shift slots [at, cnt-1] right by one
        for i in range(cnt, at, -1):
            self._write_slot(i, self._slot_bid(i - 1), self._slot_value(i - 1))
        self._write_slot(at, bid, value)
        self._set_cnt(cnt + 1)
        return True

    def remove_permit(self, bid: int):
        """Remove the permit for bid (idempotent)."""
        idx = self._find_slot(bid)
        if idx < 0:
            return
        cnt = self._get_cnt()
        # shift slots [idx+1, cnt-1] left by one
        for i in range(idx, cnt - 1):
            self._write_slot(i, self._slot_bid(i + 1), self._slot_value(i + 1))
        self._set_cnt(cnt - 1)

    def clear_permits(self) -> List[int]:
        """Remove all permits; return the cleared bid list."""
        cnt = self._get_cnt()
        cleared = [self._slot_bid(i) for i in range(cnt)]
        self._set_cnt(0)
        return cleared

    def allow_all(self) -> List[int]:
        """Atomic: clear directional permits and install the wildcard slots.

        Returns the cleared directional bid list.
        """
        cleared = [bid for bid in self.clear_permits()
                   if bid not in ALLOW_ALL_BIDS]
        self._write_slot(0, 1, 0x00000001)
        self._write_slot(1, 2, 0x00000001)
        self._write_slot(2, 3, 0x00000001)
        self._set_cnt(3)
        return cleared

    def all_permit_bids(self) -> List[int]:
        """Peer bids referenced by the slots (purge reverse-cleanup)."""
        if self.is_allow_all():
            # wildcard slots (1, 2, 3) are not real peers
            return []
        cnt = self._get_cnt()
        return [self._slot_bid(i) for i in range(cnt)]

    def __repr__(self) -> str:
        return 'Record(bid=%d, cnt=%d, slots=%d)' % (self.bid, self._get_cnt(),
                                                     self.__slot_capacity)
