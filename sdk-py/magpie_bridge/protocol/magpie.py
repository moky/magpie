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

from abc import ABC, abstractmethod


class Magpie(ABC):
    """ Core message interface: every packet on the wire is a Magpie.

        All properties are read-only.
    """

    @property
    @abstractmethod
    def target(self) -> int:
        """ Target bridge id (0 = addressed to the server). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.target getter'
        )

    @property
    @abstractmethod
    def source(self) -> int:
        """ Source bridge id (0 = first handshake / server-down). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.source getter'
        )

    @property
    @abstractmethod
    def sn(self) -> int:
        """ Data serial number (0 for system commands). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.sn getter'
        )

    @property
    @abstractmethod
    def index(self) -> int:
        """ Fragment index (0 for mini packets). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.index getter'
        )

    @property
    @abstractmethod
    def count(self) -> int:
        """ Fragment count (1 for mini packets). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.count getter'
        )

    @property
    @abstractmethod
    def command(self) -> int:
        """ Command value (0 = empty command, plain DATA). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.command getter'
        )

    @property
    @abstractmethod
    def payload(self) -> bytes:
        """ Payload bytes (empty for none). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.payload getter'
        )

    @abstractmethod
    def pack(self) -> bytes:
        """ Pack this packet into the wire bytes (header + payload, + attachment for a ReliablePacket). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.pack()'
        )


class Packet(Magpie, ABC):
    """ A Magpie whose header-level flags (A/B/C/D/E) and the two lengths
        are visible; this is the shape MessagePacket implements. """

    @property
    @abstractmethod
    def ack(self) -> int:
        """ A (0x80): 1 = reply to the peer's request. """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.ack getter'
        )

    @property
    @abstractmethod
    def bid(self) -> int:
        """ B (0x40): 1 = bridge packet (carries target/source bids). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.bid getter'
        )

    @property
    @abstractmethod
    def cmd(self) -> int:
        """ C (0x20): 1 = carries a command; 0 = plain DATA. """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.cmd getter'
        )

    @property
    @abstractmethod
    def dsn(self) -> int:
        """ D (0x10): 1 = carries an sn; 0 = system command. """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.dsn getter'
        )

    @property
    @abstractmethod
    def ext(self) -> int:
        """ E (0x07): byte width of the index/count fields (0/2/4). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.ext getter'
        )

    @property
    @abstractmethod
    def header_length(self) -> int:
        """ Full header length in bytes, buffer[5] (8 ~ 32). """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.header_length getter'
        )

    @property
    @abstractmethod
    def payload_length(self) -> int:
        """ Payload length in bytes, buffer[6] << 8 | buffer[7]. """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.payload_length getter'
        )

    #
    #   Human-readable dump
    #

    # Override
    def __len__(self) -> int:
        """ Total size of the bare packet in bytes: header plus payload.

            Subclasses may refine it - e.g. ReliablePacket counts the
            32-byte attachment as well.
        """
        return self.header_length + self.payload_length

    # Override
    def __str__(self) -> str:
        """ One-line dump, e.g.
                ReliablePacket{BID,CMD,EXT=0; target=0, source=123, command=0x50494e47, header=20B, payload=1B, packet=53B}

            The flags block stays compact and is closed by a semicolon; each
            optional field is separated by a comma and a space.
        """
        sb = type(self).__name__ + '{'
        if self.ack == 1:
            sb += 'ACK,'
        if self.bid == 1:
            sb += 'BID,'
        if self.cmd == 1:
            sb += 'CMD,'
        if self.dsn == 1:
            sb += 'DSN,'
        sb += 'EXT=%d;' % self.ext
        if self.bid == 1:
            sb += ' target=%d, source=%d,' % (self.target, self.source)
        if self.dsn == 1:
            sb += ' sn=%d,' % self.sn
        if self.ext != 0:
            sb += ' index=%d/%d,' % (self.index, self.count)
        if self.cmd == 1:
            sb += ' command=0x%x,' % self.command
        sb += ' header=%dB,' % self.header_length
        sb += ' payload=%dB,' % self.payload_length
        sb += ' packet=%dB}' % len(self)
        return sb
