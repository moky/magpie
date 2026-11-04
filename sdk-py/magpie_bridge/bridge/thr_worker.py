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

import json
import socket
import threading
import time
from abc import ABC, abstractmethod
from typing import Optional

from ..bridge_factory import BridgePacketFactory
from ..protocol import Command, Magpie
from ..reliable import ReliablePacket

from .utils import SocketAddress
from .utils import SharedCounters
from .utils import log


class Worker(ABC):
    """ Threads """

    def __init__(self, sock: Optional[socket.socket] = None,
                 counters: Optional[SharedCounters] = None):
        super().__init__()
        self.__running = False
        self.__sock = sock
        self.__counters = counters
        self.__packet_factory = BridgePacketFactory()

    @property
    def packet_factory(self) -> BridgePacketFactory:
        return self.__packet_factory

    @property
    def running(self) -> bool:
        return self.__running

    def start(self):
        if self.__running:
            return False
        self.__running = True
        thr = threading.Thread(target=self.run, daemon=True)
        thr.start()
        return True

    def stop(self):
        self.__running = False

    def run(self):
        self.setup()
        try:
            self.handle()
        finally:
            self.finish()

    def setup(self):
        """ Prepare """
        pass

    def finish(self):
        """ Cleanup """
        pass

    def handle(self):
        while self.running:
            try:
                self.process()
            except Exception as error:
                clazz = f'{type(self).__module__}.{type(self).__name__}'
                log.error('%s > process error: %s', clazz, error)

    @abstractmethod
    def process(self):
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.process()'
        )

    #
    #   Send packet data
    #

    def send(self, address: SocketAddress, data: bytes):
        """Send a datagram to the address, swallowing socket errors.

        Args:
            address: the destination socket address.
            data: the wire bytes.
        """
        try:
            self.__sock.sendto(data, (address.ip, address.port))
        except OSError:
            pass

    def maybe_reply_unconfirmed_fail(self, address: SocketAddress,
                                     packet: Magpie):
        """Reply FAIL to an unconfirmed packet, bounded by the shared counter.

        Args:
            address: the source socket address.
            packet: the parsed packet.
        """
        # must carry an attachment
        if not isinstance(packet, ReliablePacket):
            return
        # manager-side whitelist: only PING/ACPT/DENY expect an error hint
        if packet.target == 0 and packet.command not in \
                (Command.PING, Command.ACPT, Command.DENY):
            return
        if not self.__counters.hit(address.key()):
            return
        response = json.dumps({
            'src-command': '%08X' % packet.command,
            'time': time.time(),
        }).encode('utf-8')
        fail = self.packet_factory.fail(response, target=0)
        self.send(address=address, data=fail.pack())
