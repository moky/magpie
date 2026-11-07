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

from .protocol import calc_cmd, calc_dsn, calc_ext
from .protocol import calc_header_length
from .protocol import Packet

from .packet import MessagePacket
from .reliable import BasePacket


class BridgePacket(BasePacket):
    """ BridgePacket (B=1): packets exchanged with the relay server, or
        forwarded by the server between two clients. These packets carry
        target/source bids and MAY be signed (HMAC-SHA256) once a secret has
        been established.

        Instruction factories live on BridgePacketFactory; this class only
        exposes the parse-facing constructor, the create() constructor and
        the sign() method inherited from BasePacket.
    """

    def __init__(self, packet: Packet):
        """ Wrap a parsed or freshly built inner packet as a bridge packet,
            asserting that the bridge flag is set (B=1).

            End users normally obtain bridge packets from BridgePacketFactory
            (instructions) or from its parse() (received datagrams), so this
            constructor is rarely called directly.

            Args:
                packet: inner packet to wrap (must carry B=1).
        """
        # wrap a parsed or freshly built inner packet as a bridge packet,
        # asserting that the bridge flag is set (B=1).
        super().__init__(packet=packet)
        assert self.bid == 1, 'packet bid error:' \
            ' bid=%d, target=%d, source=%d.' % (self.bid, self.target, self.source)

    #
    #   factory
    #

    @classmethod
    def create(cls, *, ack: int,
               target: int, source: int,
               sn: int, index: int, count: int,
               command: int,
               payload: bytes) -> 'BridgePacket':
        """ Build a fresh BridgePacket from scratch (wire bytes not yet packed). """
        cmd = calc_cmd(command=command)
        dsn = calc_dsn(sn=sn)
        ext = calc_ext(count=count)
        packet = MessagePacket(
            None,
            ack=ack,
            bid=1,
            cmd=cmd,
            dsn=dsn,
            ext=ext,
            header_length=calc_header_length(bid=1, cmd=cmd, dsn=dsn, ext=ext),
            payload_length=len(payload),
            target=target,
            source=source,
            sn=sn,
            index=index,
            count=count,
            command=command,
            payload=payload,
        )
        return cls(packet=packet)
