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

import random
import threading
from typing import Dict, List, Optional

from .utils import ServerConfig
from .utils import SocketAddress
from .record import Record


class BidManager:
    """Bid allocation and the record index (docs/server.md 5).

    Owns the bid -> record and socket-key -> record tables, together with
    the lock that guards them.  The manager thread allocates, binds and
    removes records; the forwarder threads only look records up.
    """

    def __init__(self, config: ServerConfig):
        """Initialize the bid tables and the allocation policy.

        Args:
            config: server configuration (max_records, bid retries).
        """
        self.__config = config
        self.__by_bid: Dict[int, Record] = {}
        self.__by_key: Dict[str, Record] = {}
        self.__lock = threading.Lock()
        self.__last_purge = 0.0

    def record_by_bid(self, bid: int) -> Optional[Record]:
        """Look up a record by its bid.

        Args:
            bid: the bridge id.

        Returns:
            the record, or None when unknown.
        """
        return self.__by_bid.get(bid)

    def record_by_key(self, key: str) -> Optional[Record]:
        """Look up a record by its socket key.

        Args:
            key: the socket identity string.

        Returns:
            the record, or None when unknown.
        """
        return self.__by_key.get(key)

    def is_full(self) -> bool:
        """Whether the bid table has reached max_records."""
        return len(self.__by_bid) >= self.__config.max_records

    def add(self, bid: int, address: SocketAddress, secret: bytes, now: float) -> Optional[Record]:
        """Bind a new record after checking both indexes for conflicts.

        The capacity and both index tables are checked in one critical
        section; the record is created only when the bid and socket key
        are both free.

        Args:
            bid: the bridge id.
            address: the client socket address.
            secret: the message key.
            now: current epoch seconds.

        Returns:
            the bound record, or None when full or already taken.
        """
        with self.__lock:
            # final capacity check: the reserved loopback range (bid <= 65535,
            # internal port bids) is exempt; reserved/random bids are bounded.
            if len(self.__by_bid) >= self.__config.max_records and bid > 65535:
                return None
            if bid in self.__by_bid:
                return None
            key = address.key()
            if key in self.__by_key:
                return None
            record = Record(bid, address, secret,
                            self.__config.allowlist_max_entries)
            record.touch(now)
            self.__by_bid[bid] = record
            self.__by_key[key] = record
        return record

    def allocate(self, address: SocketAddress, source: int) -> Optional[int]:
        """Allocate a bid for a new client (loopback/reserved/random).

        Args:
            address: the source socket address.
            source: the requested bid (0 = server-assigned).

        Returns:
            the allocated bid, or None on conflict or failure.
        """
        # loopback + source=0: port as bid
        if address.is_loopback() and source == 0:
            bid = address.port
            if bid in self.__by_bid:
                return None
            return bid
        if source != 0:
            # reserved
            if source <= 65535:
                return None
            if source in self.__by_bid:
                return None
            return source
        # random in 0x00010000 .. 0x7FFFFFFF
        for _ in range(self.__config.bid_allocation_retries):
            bid = random.randint(0x00010000, 0x7FFFFFFF)
            if bid not in self.__by_bid:
                return bid
        return None

    def remove(self, record: Record):
        """Remove a record and reverse-clean its permit references.

        Args:
            record: the record to remove.
        """
        with self.__lock:
            # reverse-clean permits: for every peer bid referenced by this
            # record's slots, remove this record's entry from that peer's slots
            for peer_bid in record.all_permit_bids():
                peer = self.__by_bid.get(peer_bid)
                if peer is not None:
                    peer.remove_permit(record.bid)
            self.__by_bid.pop(record.bid, None)
            self.__by_key.pop(record.key, None)

    def _expired_records(self, now: float, expires: float) -> List[Record]:
        """Collect records idle longer than the recycle timeout.

        Args:
            now: current epoch seconds.
            expires: the recycle timeout in seconds.

        Returns:
            the expired records.
        """
        with self.__lock:
            return [r for r in self.__by_bid.values()
                    if now - r.last_time > expires]

    def purge(self, now: float):
        """Recycle expired records until the table is under 80% of max_records.

        Args:
            now: current epoch seconds.
        """
        if now - self.__last_purge < self.__config.record_recycle_interval:
            return
        else:
            self.__last_purge = now
        # remove expired records
        expires = self.__config.record_expires
        min_expires = self.__config.record_active_timeout
        max_count = self.__config.max_records * 0.8
        # the manager thread is the only writer: the count only shrinks
        # while purging, so read it once and decrement per removal
        count = len(self.__by_bid)
        while True:
            records = self._expired_records(now, expires)
            for r in records:
                self.remove(r)
                count -= 1
            if count < max_count:
                return
            if expires <= min_expires:
                # still over the limit after shrinking the recycle timeout
                # down to the floor: high load, give up this round
                return
            expires = max(expires / 2.0, min_expires)
