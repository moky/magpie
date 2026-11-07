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

from typing import Optional

from .protocol import Command
from .protocol import Magpie, Packet
from .protocol import ATTACHMENT_LENGTH

from .reliable import ReliablePacket
from .direct_packet import DirectPacket
from .packet_factory import MessagePacketFactory


# noinspection PyMethodMayBeStatic
class DirectPacketFactory(MessagePacketFactory):
    """ Creates and parses direct packets (B=0, client <-> client).

        Only carries the ten instructions that make sense off-relay:
        handshake, heartbeat, shutdown, noop and data. It never includes
        acpt/deny/fail/done, which only exist on the server side.
    """

    #
    #   Handshake
    #

    def syn(self, request: bytes) -> DirectPacket:
        """ 1st handshake (SYN?): propose a peer-to-peer session.

            Args:
                request: handshake body.

            Returns:
                A SYN? packet to the peer.
        """
        return DirectPacket.create(ack=0, sn=0, index=0, count=1,
                                   command=Command.SYN, payload=request)

    def syn_ack(self, response: bytes) -> DirectPacket:
        """ 2nd handshake (SYN!, A=1): accept the peer's proposal.

            Args:
                response: echoed handshake body.

            Returns:
                The SYN! reply to the peer's SYN?.
        """
        return DirectPacket.create(ack=1, sn=0, index=0, count=1,
                                   command=Command.SYN_ACK, payload=response)

    def ack(self, response: bytes) -> DirectPacket:
        """ 3rd handshake (ACK!, A=1): final acknowledgment of the session.

            Args:
                response: echoes back the token material from the SYN!.

            Returns:
                The closing handshake packet.
        """
        return DirectPacket.create(ack=1, sn=0, index=0, count=1,
                                   command=Command.ACK, payload=response)

    #
    #   Heartbeat / shutdown / noop
    #

    def ping(self, request: bytes) -> DirectPacket:
        """ Heartbeat (PING): keep-alive between peers.

            Args:
                request: optional application data.

            Returns:
                A PING packet to the peer.
        """
        return DirectPacket.create(ack=0, sn=0, index=0, count=1,
                                   command=Command.PING, payload=request)

    def fin(self, request: bytes) -> DirectPacket:
        """ Shutdown (FIN?): close the peer-to-peer session.

            Args:
                request: optional farewell data.

            Returns:
                A FIN? packet to the peer.
        """
        return DirectPacket.create(ack=0, sn=0, index=0, count=1,
                                   command=Command.FIN, payload=request)

    def noop(self, request: bytes) -> DirectPacket:
        """ No-op (NOOP): keep the channel warm.

            Args:
                request: ignored by the protocol.

            Returns:
                A NOOP packet to the peer.
        """
        return DirectPacket.create(ack=0, sn=0, index=0, count=1,
                                   command=Command.NOOP, payload=request)

    #
    #   Reply factories (fields copied from the request).
    #

    def pong(self, response: bytes, packet: Magpie) -> DirectPacket:
        """ Reply (PONG, A=1): answer a peer's PING.

            Args:
                packet: the PING being answered.
                response: optional application data.

            Returns:
                A PONG packet carrying the same sn/index/count as the request.
        """
        return DirectPacket.create(ack=1, sn=packet.sn, index=packet.index, count=packet.count,
                                   command=Command.PONG, payload=response)

    def fin_ack(self, response: bytes, packet: Magpie) -> DirectPacket:
        """ Reply (FIN!, A=1): confirm a peer's FIN shutdown request.

            Args:
                packet: the FIN? being answered.
                response: optional application data.

            Returns:
                A FIN! packet carrying the same sn/index/count as the request.
        """
        return DirectPacket.create(ack=1, sn=packet.sn, index=packet.index, count=packet.count,
                                   command=Command.FIN_ACK, payload=response)

    #
    #   Data
    #

    def data(self, payload: bytes, *, sn: int, index: int = 0, count: int = 1) -> DirectPacket:
        """ Ordinary data packet (peer -> peer).

            Args:
                payload: data bytes of the message.
                sn: data serial number.
                index: fragment offset within the transfer.
                count: total number of fragments.

            Returns:
                A DATA packet; command stays 0 (C=0) to keep the header small.
        """
        return DirectPacket.create(ack=0, sn=sn, index=index, count=count,
                                   command=Command.EMPTY, payload=payload)

    def copy(self, response: bytes, packet: Magpie) -> DirectPacket:
        """ Reply (COPY, A=1): acknowledge a received DATA packet.

            Args:
                packet: data packet being acknowledged; its sn/index/count
                    are copied so the sender can match the acknowledgement.
                response: optional app-defined acknowledgement content.

            Returns:
                A COPY reply to the sender.
        """
        return DirectPacket.create(ack=1, sn=packet.sn, index=packet.index, count=packet.count,
                                   command=Command.COPY, payload=response)

    #
    #   parse (B=0 only)
    #

    # Override
    def parse(self, data: bytes) -> Optional[Packet]:
        """ Validate and parse a received direct datagram.

            Direct packets never carry an attachment: the whole buffer must
            equal header + payload, and B must be 0.

            Args:
                data: raw UDP datagram to parse.

            Returns:
                A DirectPacket / ReliablePacket, or None if the datagram is
                invalid.
        """
        packet = super().parse(data=data)
        if packet is None or packet.bid != 0:
            # bridge packet not for this factory.
            return None
        size = packet.header_length + packet.payload_length
        tail = len(data) - size
        if tail == 0:
            # direct packet without attachment
            return DirectPacket(packet=packet)
        if tail != ATTACHMENT_LENGTH:
            # tail is neither 0 nor 32: bad packet.
            return None
        # reliable packet with verify code
        attachment = data[size:size + ATTACHMENT_LENGTH]
        return ReliablePacket(packet=packet, attachment=attachment)
