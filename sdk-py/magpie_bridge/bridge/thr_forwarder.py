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

import queue
import socket
import time
from collections import deque
from typing import Dict

from ..protocol import Magpie
from ..reliable import ReliablePacket

from .utils import log, utf8_encode, json_encode
from .utils import SocketAddress, SharedCounters
from .config import ServerConfig
from .bid_manager import BidManager

from .thr_worker import Worker


class Forwarder(Worker):
    """Forwarder thread: rate-limited relay of data packets (docs/server.md 3).

    Owns an input queue and one waiting deque per source bid; runs a
    breadth-first drain with a sliding-window rate limit.
    """

    def __init__(self, index: int, forward_queue: queue.Queue,
                 config: ServerConfig, bids: BidManager,
                 sock: socket.socket, counters: SharedCounters):
        """Initialize the forwarder thread with its dependencies.

        Args:
            index: worker index (0-based).
            forward_queue: the queue fed by the preprocessor.
            config: server configuration (rate limit, active timeout).
            bids: the shared bid/record index for target lookup.
            sock: the UDP socket used for replies.
            counters: the shared rate limiter for unconfirmed FAIL replies.
        """
        super().__init__(sock=sock, counters=counters)
        self.__index = index
        self.__forward_queue = forward_queue
        self.__config = config
        self.__bids = bids
        self.__bid_deques: Dict[int, deque] = {}
        self.__window_start = 0.0
        self.__window_count = 0

    @property
    def forward_queue(self) -> queue.Queue:
        """ The input queue (preprocessor handoff point). """
        return self.__forward_queue

    # Override
    def process(self):
        """Consume one input task and drain the per-source deques."""
        try:
            item = self.__forward_queue.get(timeout=0.05)
        except queue.Empty:
            self._drain()
            return
        address, packet = item
        self._enqueue(address=address, packet=packet)
        self._drain()

    def _enqueue(self, address: SocketAddress, packet: Magpie):
        """Append a task to the per-source waiting deque.

        Args:
            address: the source socket address.
            packet: the parsed packet.
        """
        deq = self.__bid_deques.get(packet.source)
        if deq is None:
            deq = self.__bid_deques[packet.source] = deque()
        deq.append((address, packet))

    def _drain(self):
        """Forward queued tasks with a sliding-window rate limit.

        Stops when the window quota is used up or every deque is empty.
        """
        while True:
            now = time.time()
            # sliding window rate limit
            if now - self.__window_start >= self.__config.forward_window:
                self.__window_start = now
                self.__window_count = 0
            if self.__window_count >= self.__config.forward_limit_per_window:
                return
            progressed = False
            for source in list(self.__bid_deques.keys()):
                deq = self.__bid_deques.get(source)
                if not deq:
                    continue
                address, packet = deq.popleft()
                if not deq:
                    del self.__bid_deques[source]
                self.__window_count += 1
                progressed = True
                self._relay_packet(address=address, packet=packet)
            if not progressed:
                return

    #
    #   forwarding chain (docs/server.md 3.2)
    #

    def _relay_packet(self, address: SocketAddress, packet: Magpie):
        """Run the forwarding validation chain and relay the packet.

        Args:
            address: the source socket address.
            packet: the parsed packet.
        """
        now = time.time()
        record = self.__bids.record_by_key(key=address.key())
        if record is None:
            self.maybe_reply_unconfirmed_fail(address=address, packet=packet)
            return
        if record.bid != packet.source:
            return
        # bound clients must carry a valid attachment; anything else is a
        # forged packet: drop silently, do not refresh last_time
        ok = isinstance(packet, ReliablePacket) and packet.verify(secret=record.secret)
        if not ok:
            log.warning('HMAC verification failed from bid %d', record.bid)
            return
        if record.offline:
            return
        record.touch(now)

        target = self.__bids.record_by_bid(bid=packet.target)
        if target is None:
            return
        # permit check: either side, both sockets must match
        view = record.search_permit(record=target)
        if view is None:
            view = target.search_permit(record=record)
        if view is None or not view.valid \
                or not view.match(record=record) \
                or not view.match(record=target):
            return
        # target state
        if target.offline or now - target.last_time > self.__config.record_active_timeout:
            body = self._offline_payload(packet=packet)
            fail = self.packet_factory.fail(body, target=record.bid)
            fail = fail.sign(secret=record.secret)
            self.send(address=address, data=fail.pack())
            return
        # re-sign with target's secret and forward (sign() replaces the
        # attachment of an already-signed packet, see docs/server.md 3.8)
        packet = packet.sign(secret=target.secret)
        self.send(address=target.socket, data=packet.pack())

    @staticmethod
    def _offline_payload(packet: Magpie) -> bytes:
        """Build the FAIL payload for an offline or expired target.

        Args:
            packet: the original packet being forwarded.

        Returns:
            the JSON payload bytes.
        """
        return utf8_encode(json_encode({
            'src-command': '%08X' % packet.command,
            'src-target': packet.target,
            'time': time.time(),
        }))
