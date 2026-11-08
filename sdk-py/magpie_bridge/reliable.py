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

from .protocol import Packet
from .protocol import ATTACHMENT_LENGTH

from .x import HmacSha256


class BasePacket(Packet):
    """ Delegation base shared by all public packet classes.

        BasePacket wraps an inner Packet (usually a MessagePacket) and
        forwards every field and pack() to it, so BridgePacket, DirectPacket
        and ReliablePacket stay thin wrappers around the same validated
        payload. It also carries the sign() capability: signing is computed
        over the bare header + payload of the inner packet, so calling
        sign() on an already-signed ReliablePacket simply re-signs it.
    """

    def __init__(self, packet: Packet):
        """ Wrap the inner packet as the delegation target.

            Args:
                packet: inner packet whose fields and wire bytes are exposed.
        """
        super().__init__()
        # inner packet whose fields and wire bytes are exposed
        self.__packet = packet

    #
    #   Flags
    #

    @property  # Override
    def ack(self) -> int:
        return self.__packet.ack

    @property  # Override
    def bid(self) -> int:
        return self.__packet.bid

    @property  # Override
    def cmd(self) -> int:
        return self.__packet.cmd

    @property  # Override
    def dsn(self) -> int:
        return self.__packet.dsn

    @property  # Override
    def ext(self) -> int:
        return self.__packet.ext

    #
    #   Lengths
    #

    @property  # Override
    def header_length(self) -> int:
        return self.__packet.header_length

    @property  # Override
    def payload_length(self) -> int:
        return self.__packet.payload_length

    #
    #   Fields
    #

    @property  # Override
    def target(self) -> int:
        return self.__packet.target

    @property  # Override
    def source(self) -> int:
        return self.__packet.source

    @property  # Override
    def sn(self) -> int:
        return self.__packet.sn

    @property  # Override
    def index(self) -> int:
        return self.__packet.index

    @property  # Override
    def count(self) -> int:
        return self.__packet.count

    @property  # Override
    def command(self) -> int:
        return self.__packet.command

    @property  # Override
    def payload(self) -> bytes:
        return self.__packet.payload

    #
    #   Serialization
    #

    # Override
    def pack(self) -> bytes:
        return self.__packet.pack()

    #
    #   Attachment (HMAC-SHA256)
    #

    def sign(self, secret: bytes) -> 'ReliablePacket':
        """ Compute HMAC-SHA256 over (header + payload) and return a signed
            packet. DirectPacket inherits this as well; signing a direct
            packet is a reserved capability (the app decides whether it
            needs one).
        """
        # pack() yields header + payload only; the attachment stays separate.
        base = self.__packet.pack()
        digest = HmacSha256.generate(secret=secret, message=base)
        return ReliablePacket(packet=self.__packet, attachment=digest)


class ReliablePacket(BasePacket):
    """ A packet that carries a 32-byte HMAC-SHA256 attachment (verify code).

        ReliablePacket wraps the same inner packet and appends the digest
        when serialising, so the wire bytes are
        'header + payload + attachment(32)'. Its inherited sign() re-computes
        the digest over the bare header + payload of the inner packet, which
        makes re-signing (secret rotation) a plain packet.sign(new_secret)
        call that replaces the attachment.
    """

    def __init__(self, packet: Packet, attachment: bytes):
        """ Wrap a packet with an already computed attachment (32 bytes).

            Args:
                packet: inner packet to wrap.
                attachment: 32-byte HMAC-SHA256 digest.
        """
        super().__init__(packet=packet)
        self.__attachment = attachment

    @property
    def attachment(self) -> bytes:
        """ The 32-byte HMAC-SHA256 digest. """
        return self.__attachment

    #
    #   Serialization
    #

    # Override
    def pack(self) -> bytes:
        base = super().pack()
        digest = self.__attachment
        return base + digest

    #
    #   Attachment (HMAC-SHA256)
    #

    def verify(self, secret: bytes) -> bool:
        """ Verify the attachment with the secret.

            Constant-time comparison (defends against timing attacks).

            Args:
                secret: HMAC key.

            Returns:
                True if the digest matches, False otherwise.
        """
        digest = self.__attachment
        if len(digest) != ATTACHMENT_LENGTH:
            return False
        elif not secret:
            return False
        # Re-pack header + payload (without attachment) the same way sign() did.
        base = super().pack()
        return HmacSha256.verify(digest, secret=secret, message=base)
