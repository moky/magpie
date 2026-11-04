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
from typing import List

from ..protocol import Magpie

from .utils import log
from .utils import SocketAddress

from .thr_worker import Worker
from .thr_forwarder import Forwarder


class Preprocessor(Worker):
    """Preprocessor thread: validate and dispatch tasks (docs/server.md 2).

    target=0 goes to the manager queue; anything else is assigned to a
    forwarder by source bid % W.
    """

    def __init__(self, waiting_queue: queue.Queue, manager_queue: queue.Queue,
                 forwarders: List[Forwarder]):
        """Initialize the preprocessor thread with its queues.

        Args:
            waiting_queue: the receiver queue feeding raw datagrams.
            manager_queue: the target queue for management packets.
            forwarders: the worker list for data-packet dispatch.
        """
        super().__init__()
        self.__waiting_queue = waiting_queue
        self.__manager_queue = manager_queue
        self.__forwarders = forwarders

    # Override
    def process(self):
        """Validate and dispatch one task to the manager or forwarders."""
        try:
            address, data = self.__waiting_queue.get(timeout=0.05)
        except queue.Empty:
            return
        # 1. source address check
        if address.is_broadcast_or_multicast():
            log.debug('drop: broadcast/multicast from %s', address.key())
            return
        # 2. header / payload validation
        #    A malformed datagram can trip the constructor asserts
        #    (e.g. payload > 1024): log and drop instead of killing
        #    the pre-processing thread.
        try:
            packet = self.packet_factory.parse(data=data)
        except AssertionError:
            log.warning('drop: invalid packet from %s (%d bytes)', address.key(), len(data))
            return
        if packet is None:
            log.debug('drop: bad packet from %s (%d bytes)', address.key(), len(data))
            return
        # 3. uplink violations
        if packet.bid != 1:
            log.debug('drop: B=0 from %s', address.key())
            return
        if packet.target != 0:
            if packet.source == 0:
                log.debug('drop: target!=0 but source=0 from %s', address.key())
                return
            if packet.target == packet.source:
                log.debug('drop: target==source from %s', address.key())
                return
        # 4. dispatch
        if packet.target == 0:
            self._put(self.__manager_queue, address=address, packet=packet)
        else:
            fwd = self.__forwarders[packet.source % len(self.__forwarders)]
            self._put(fwd.forward_queue, address=address, packet=packet)

    @staticmethod
    def _put(q: queue.Queue, address: SocketAddress, packet: Magpie):
        """Put a task into a bounded queue, dropping it when full.

        Args:
            q: the target queue.
            address: the source socket address.
            packet: the parsed packet.
        """
        try:
            q.put_nowait((address, packet))
        except queue.Full:
            log.warning('queue full, dropped packet')
