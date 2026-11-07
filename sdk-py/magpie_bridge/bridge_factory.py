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
from .bridge_packet import BridgePacket
from .packet_factory import MessagePacketFactory


# noinspection PyMethodMayBeStatic
class BridgePacketFactory(MessagePacketFactory):
    """ Creates and parses bridge packets (B=1, client <-> server).

        The server only ever uses this factory; the client keeps one per
        bridge pipe. Instruction methods build fresh packets; parse()
        validates received datagrams and rejects direct (B=0) packets.
    """

    #
    #   Handshake
    #

    def syn(self, request: bytes, *, source: int = 0) -> BridgePacket:
        """ 1st handshake (SYN?): ask the server for a bridge id.

            Args:
                request: handshake body (e.g. the session token).
                source: bid the client requests (0 = let the server assign).

            Returns:
                A SYN? packet from the client to the server.
        """
        return BridgePacket.create(ack=0, target=0, source=source,
                                   sn=0, index=0, count=1,
                                   command=Command.SYN, payload=request)

    def syn_ack(self, response: bytes, *, target: int) -> BridgePacket:
        """ 2nd handshake (SYN!, A=1): server assigns target to the client.

            Args:
                response: echoed handshake body.
                target: bridge id assigned by the server.

            Returns:
                The server's reply to the client's SYN?.
        """
        return BridgePacket.create(ack=1, target=target, source=0,
                                   sn=0, index=0, count=1,
                                   command=Command.SYN_ACK, payload=response)

    def ack(self, response: bytes, *, source: int) -> BridgePacket:
        """ 3rd handshake (ACK!, A=1): client confirms the established session.

            Args:
                response: echoes back secret/token from the SYN!.
                source: client's bridge id.

            Returns:
                The final handshake packet from the client.
        """
        return BridgePacket.create(ack=1, target=0, source=source,
                                   sn=0, index=0, count=1,
                                   command=Command.ACK, payload=response)

    #
    #   Result (server -> client)
    #

    def fail(self, response: bytes, *, target: int,
             sn: int = 0, index: int = 0, count: int = 1) -> BridgePacket:
        """ Result (FAIL): the server rejects a previous request.

            Args:
                response: failure detail.
                target: bid of the client being answered.
                sn: mirror the request's data serial number when it was
                    fragmented.
                index: mirror the request's fragment index.
                count: mirror the request's fragment count.

            Returns:
                A FAIL packet (server -> client).
        """
        return BridgePacket.create(ack=1, target=target, source=0,
                                   sn=sn, index=index, count=count,
                                   command=Command.FAIL, payload=response)

    def done(self, response: bytes, *, target: int,
             sn: int = 0, index: int = 0, count: int = 1) -> BridgePacket:
        """ Result (DONE): the server reports a previous request completed.

            Args:
                response: result body.
                target: bid of the client being answered.
                sn: mirror the request's data serial number when it was
                    fragmented.
                index: mirror the request's fragment index.
                count: mirror the request's fragment count.

            Returns:
                A DONE packet (server -> client).
        """
        return BridgePacket.create(ack=1, target=target, source=0,
                                   sn=sn, index=index, count=count,
                                   command=Command.DONE, payload=response)

    #
    #   Permit
    #

    def acpt(self, request: bytes, *, source: int) -> BridgePacket:
        """ Permit (ACPT): the server accepts a client's handshake.

            Args:
                request: handshake body to pass back.
                source: bid granted to the client.

            Returns:
                The server's ACPT packet.
        """
        return BridgePacket.create(ack=0, target=0, source=source,
                                   sn=0, index=0, count=1,
                                   command=Command.ACPT, payload=request)

    def deny(self, request: bytes, *, source: int) -> BridgePacket:
        """ Permit (DENY): the server refuses a client's handshake.

            Args:
                request: handshake body to pass back.
                source: bid being refused.

            Returns:
                The server's DENY packet.
        """
        return BridgePacket.create(ack=0, target=0, source=source,
                                   sn=0, index=0, count=1,
                                   command=Command.DENY, payload=request)

    #
    #   Heartbeat / shutdown / noop
    #

    def ping(self, request: bytes, *, source: int) -> BridgePacket:
        """ Heartbeat (PING): client keep-alive while the pipe is idle.

            Args:
                request: optional application data.
                source: client's bid.

            Returns:
                A PING packet to the server.
        """
        return BridgePacket.create(ack=0, target=0, source=source,
                                   sn=0, index=0, count=1,
                                   command=Command.PING, payload=request)

    def fin(self, request: bytes, *, source: int) -> BridgePacket:
        """ Shutdown (FIN?): client asks to close the bridge connection.

            Args:
                request: optional farewell data.
                source: client's bid.

            Returns:
                A FIN? packet to the server.
        """
        return BridgePacket.create(ack=0, target=0, source=source,
                                   sn=0, index=0, count=1,
                                   command=Command.FIN, payload=request)

    def noop(self, request: bytes, *, source: int) -> BridgePacket:
        """ No-op (NOOP): keep the pipe warm without any payload semantics.

            Args:
                request: ignored by the protocol.
                source: client's bid.

            Returns:
                A NOOP packet to the server.
        """
        return BridgePacket.create(ack=0, target=0, source=source,
                                   sn=0, index=0, count=1,
                                   command=Command.NOOP, payload=request)

    #
    #   Reply factories (fields copied from the request).
    #

    def pong(self, response: bytes, packet: Magpie) -> BridgePacket:
        """ Reply (PONG, A=1): answer a client's PING.

            Args:
                packet: the PING being answered.
                response: optional application data.

            Returns:
                A PONG packet with target/source swapped (server -> the ping
                source).
        """
        return BridgePacket.create(ack=1, target=packet.source, source=packet.target,
                                   sn=packet.sn, index=packet.index, count=packet.count,
                                   command=Command.PONG, payload=response)

    def fin_ack(self, response: bytes, packet: Magpie) -> BridgePacket:
        """ Reply (FIN!, A=1): confirm a client's FIN shutdown request.

            Args:
                packet: the FIN? being answered.
                response: optional application data.

            Returns:
                A FIN! packet with target/source swapped.
        """
        return BridgePacket.create(ack=1, target=packet.source, source=packet.target,
                                   sn=packet.sn, index=packet.index, count=packet.count,
                                   command=Command.FIN_ACK, payload=response)

    #
    #   Data
    #

    def data(self, payload: bytes, *, target: int, source: int,
             sn: int, index: int = 0, count: int = 1) -> BridgePacket:
        """ Ordinary data packet (client -> server / forwarded between clients).

            Args:
                payload: data bytes of the message.
                target: receiver's bid (0 = server).
                source: sender's bid.
                sn: data serial number.
                index: fragment offset within the transfer.
                count: total number of fragments.

            Returns:
                A DATA packet; command stays 0 (C=0) to keep the header small.
        """
        return BridgePacket.create(ack=0, target=target, source=source,
                                   sn=sn, index=index, count=count,
                                   command=Command.EMPTY, payload=payload)

    def copy(self, response: bytes, packet: Magpie) -> BridgePacket:
        """ Reply: acknowledge a received DATA packet with COPY (A=1).

            Args:
                packet: data packet being acknowledged; its sn/index/count
                    are copied so the sender can match the acknowledgement,
                    and target/source are swapped.
                response: optional app-defined acknowledgement content.

            Returns:
                A COPY reply addressed to packet.source.
        """
        return BridgePacket.create(ack=1, target=packet.source, source=packet.target,
                                   sn=packet.sn, index=packet.index, count=packet.count,
                                   command=Command.COPY, payload=response)

    #
    #   parse (B=1 only)
    #

    # Override
    def parse(self, data: bytes) -> Optional[Packet]:
        """ Validate and parse a received bridge datagram.

            Basic header validation is shared with MessagePacketFactory.parse;
            here we then enforce B=1 and the tail rule: tail < 0 is rejected,
            tail == 0 yields a plain BridgePacket, tail == 32 yields a
            ReliablePacket whose attachment is the trailing 32 bytes. The
            attachment is NOT verified here; the caller does that once the
            secret is known.

            Args:
                data: raw UDP datagram to parse.

            Returns:
                A BridgePacket / ReliablePacket, or None if the datagram is
                invalid.
        """
        packet = super().parse(data=data)
        if packet is None or packet.bid != 1:
            # direct packet not for this factory.
            return None
        size = packet.header_length + packet.payload_length
        tail = len(data) - size
        if tail == 0:
            # bridge packet without attachment
            return BridgePacket(packet=packet)
        if tail != ATTACHMENT_LENGTH:
            # tail is neither 0 nor 32: bad packet.
            return None
        # reliable packet with verify code
        attachment = data[size:size + ATTACHMENT_LENGTH]
        return ReliablePacket(packet=packet, attachment=attachment)
