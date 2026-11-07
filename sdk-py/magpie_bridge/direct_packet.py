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


class DirectPacket(BasePacket):
    """ DirectPacket (B=0): peer-to-peer packets without relay. No
        target/source bids and no attachment (data integrity is the app's
        responsibility).

        Instruction factories live on DirectPacketFactory; this class only
        exposes the parse-facing constructor and the create() constructor.
    """

    def __init__(self, packet: Packet):
        """ Wrap a parsed or freshly built inner packet as a direct packet,
            asserting that no bridge ids are carried (B=0, target=source=0).

            End users normally obtain direct packets from DirectPacketFactory
            (instructions) or from its parse() (received datagrams), so this
            constructor is rarely called directly.

            Args:
                packet: inner packet to wrap (must carry B=0).
        """
        # wrap a parsed or freshly built inner packet as a direct packet,
        # asserting that no bridge ids are carried (B=0, target=source=0).
        super().__init__(packet=packet)
        assert self.bid == 0 and self.target == 0 and self.source == 0, 'packet bid error:' \
            ' bid=%d, target=%d, source=%d.' % (self.bid, self.target, self.source)

    #
    #   Factory
    #

    @classmethod
    def create(cls, *, ack: int,
               sn: int, index: int, count: int,
               command: int,
               payload: bytes) -> 'DirectPacket':
        """ Build a fresh DirectPacket from scratch (wire bytes not yet packed). """
        cmd = calc_cmd(command=command)
        dsn = calc_dsn(sn=sn)
        ext = calc_ext(count=count)
        packet = MessagePacket(
            None,
            ack=ack,
            bid=0,
            cmd=cmd,
            dsn=dsn,
            ext=ext,
            header_length=calc_header_length(bid=0, cmd=cmd, dsn=dsn, ext=ext),
            payload_length=len(payload),
            target=0,
            source=0,
            sn=sn,
            index=index,
            count=count,
            command=command,
            payload=payload,
        )
        return cls(packet=packet)
