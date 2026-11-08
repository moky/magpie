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
from typing import List, Optional

from .utils import log
from .utils import SocketAddress, SharedCounters
from .utils import ServerConfig
from .bid_manager import BidManager

from .thr_pre import Preprocessor
from .thr_manager import Manager
from .thr_forwarder import Forwarder


class Server:
    """The Magpie Bridge relay server.

    Owns the shared state (socket, queues) and the thread lifecycle;
    receives datagrams on the main thread and runs the preprocessor /
    manager / forwarder workers (docs/server.md 1).  The workers receive
    their dependencies (queues, config, bid index, socket, rate counter)
    through their constructors; the manager owns the secrets and the
    enigma table.
    """

    def __init__(self, config: Optional[ServerConfig] = None):
        """Initialize the shared state and the worker threads.

        Args:
            config: server configuration; defaults to ServerConfig().
        """
        super().__init__()
        if config is None:
            config = ServerConfig()
        self.__config = config
        self.__running = False

        self.__sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.__waiting_queue: queue.Queue = queue.Queue(maxsize=config.waiting_queue_size)
        self.__manager_queue: queue.Queue = queue.Queue(maxsize=config.manager_queue_size)
        self.__bids = BidManager(config=config)

        counters = SharedCounters(buckets=config.unconfirmed_reply_buckets,
                                  limit=config.reply_rate_limit)

        # the worker threads (docs/server.md 1)
        self.__forwarders: List[Forwarder] = [
            Forwarder(index=i,
                      forward_queue=queue.Queue(maxsize=config.forwarder_queue_size),
                      config=config, bids=self.__bids, sock=self.__sock, counters=counters)
            for i in range(config.forwarders)
        ]
        self.__preprocessor = Preprocessor(waiting_queue=self.__waiting_queue,
                                           manager_queue=self.__manager_queue,
                                           forwarders=self.__forwarders)
        self.__manager = Manager(self.__manager_queue, self.__config,
                                 self.__bids, self.__sock, counters)

    #
    #   lifecycle
    #

    def run(self):
        """Bind the UDP socket, load enigma_secrets, start the worker threads and
        receive datagrams on the main thread."""
        self._bind()
        preprocessor = self.__preprocessor
        forwarders = self.__forwarders
        manager = self.__manager
        config = self.__config
        manager.load_enigma_secrets()
        log.info('================================================')
        log.info('')
        log.info('  Magpie Bridge')
        log.info('')
        log.info('    UDP listening on %s:%d', config.host, config.port)
        log.info('')
        if manager.encrypted_mode:
            log.info('    Encrypted mode: %s, with %d secret(s)', manager.encrypted_mode, manager.enigma_count)
        else:
            log.info('    Encrypted mode: OFF')
        log.info('')
        log.info('================================================')
        # starting workers
        self.__running = True
        for f in forwarders:
            f.start()
        manager.start()
        preprocessor.start()
        # the main thread is the receiver: blocking recvfrom feeds the
        # waiting queue; stop() closes the socket to wake it up
        try:
            while self.__running:
                data, addr = self.__sock.recvfrom(65535)
                address = SocketAddress.from_addr(addr)
                log.debug('recv %d bytes from %s', len(data), address.key())
                try:
                    self.__waiting_queue.put_nowait((address, data))
                except queue.Full:
                    log.warning('waiting queue full, dropped %d bytes from %s',
                                len(data), address.key())
        except OSError:
            pass
        except KeyboardInterrupt:
            self.stop()

    def stop(self):
        """Stop the workers and close the UDP socket."""
        preprocessor = self.__preprocessor
        forwarders = self.__forwarders
        manager = self.__manager
        preprocessor.stop()
        manager.stop()
        for f in forwarders:
            f.stop()
        self.__running = False
        if self.__sock:
            try:
                self.__sock.close()
            except OSError:
                pass

    def _bind(self):
        """Configure and bind the UDP socket with the given buffer size."""
        self.__sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.__sock.setsockopt(socket.SOL_SOCKET,
                                   socket.SO_RCVBUF,
                                   self.__config.socket_buffer_length)
        except OSError:
            pass
        self.__sock.bind((self.__config.host, self.__config.port))
