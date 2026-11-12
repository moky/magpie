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

from .protocol import Packet
from .protocol import MAGIC_CODE
from .protocol import MAX_PAYLOAD_LENGTH, MSS
from .protocol import calc_header_length
from .protocol import calc_type


class MessagePacket(Packet):
    """ The concrete, pack-only implementation of Packet.

        MessagePacket holds a fully validated header (flags, lengths and
        optional fields) plus the payload, and serialises them to the wire
        format in pack(). It is an implementation detail: end users normally
        receive BridgePacket / DirectPacket / ReliablePacket wrappers from
        the factories, which delegate back to an inner MessagePacket.

        It inherits __str__ from Packet, so printing a packet renders a
        one-line human-readable dump.

        The header length obeys the formula N = 8 + 8*B + 4*D + 2*E + 4*C.
    """

    def __init__(self, buffer: Optional[bytes] = None, *,
                 ack: int, bid: int, cmd: int, dsn: int, ext: int,
                 header_length: int, payload_length: int,
                 target: int, source: int,
                 sn: int, index: int, count: int,
                 command: int,
                 payload: bytes):
        """ Create a packet from already computed header fields.

            Args:
                buffer: cached wire bytes when the packet came from parsing,
                    or None for a freshly built packet (serialised lazily by
                    pack()).
                ack: reply flag (A), 1 = answers the peer's request.
                bid: bridge flag (B), 1 = carries target/source bids.
                cmd: command presence flag (C), 1 = the header carries command.
                dsn: data serial number flag (D), 1 = the header carries sn.
                ext: fragment parameter width (E), byte width of index/count
                     (0/2/4 on the wire; 1/3 accepted when parsing).
                header_length: computed header length.
                payload_length: payload length.
                target: receiver's bid.
                source: sender's bid.
                sn: data serial number.
                index: fragment offset within the transfer.
                count: total number of fragments.
                command: reserved command value (0 for plain DATA).
                payload: payload bytes.

            The constructor asserts the length formula, the payload cap and
            the fragment range; wire-validated packets from
            MessagePacketFactory always satisfy them.
        """
        super().__init__()
        # buffer is the cached wire bytes when the packet came from parsing,
        # or None for a freshly built packet (serialised lazily by pack()).
        self.__buffer = buffer
        # flags
        self.__ack = ack
        self.__bid = bid
        self.__cmd = cmd
        self.__dsn = dsn
        self.__ext = ext
        # lengths
        self.__header_length = header_length
        self.__payload_length = payload_length
        # fields
        self.__target = target
        self.__source = source
        self.__sn = sn
        self.__index = index
        self.__count = count
        self.__command = command
        self.__payload = payload
        # sanity checks (wire-validated packets always satisfy them)
        assert header_length == calc_header_length(bid=bid, cmd=cmd, dsn=dsn, ext=ext) \
            and len(payload) == payload_length \
            and payload_length <= MAX_PAYLOAD_LENGTH \
            and header_length + payload_length <= MSS, \
            'packet lengths error: bid=%d, cmd=%d, dsn=%d, ext=%d, ' \
            'header=%d, payload=%d byte(s).' % (bid, cmd, dsn, ext,
                                                header_length, payload_length)
        assert 0 <= index < count, 'range error: index=%d, count=%d.' % (index, count)

    #
    #   Flags
    #

    @property  # Override
    def ack(self) -> int:
        """ A (0x80): 1 = reply to the peer's request. """
        return self.__ack

    @property  # Override
    def bid(self) -> int:
        """ B (0x40): 1 = bridge packet (client <-> server, has target/source). """
        return self.__bid

    @property  # Override
    def cmd(self) -> int:
        """ C (0x20): 1 = carries a command; 0 = plain DATA. """
        return self.__cmd

    @property  # Override
    def dsn(self) -> int:
        """ D (0x10): 1 = carries an sn; 0 = system command. """
        return self.__dsn

    @property  # Override
    def ext(self) -> int:
        """ E (0x07): byte width of the index/count fields
            (0/2/4 on the wire; 1/3 accepted when parsing). """
        return self.__ext

    #
    #   Lengths
    #

    @property  # Override
    def header_length(self) -> int:
        """ Full header length in bytes (8 ~ 32), always matches
            calc_header_length. """
        return self.__header_length

    @property  # Override
    def payload_length(self) -> int:
        """ Payload length in bytes (0 ~ 1024 recommended for senders). """
        return self.__payload_length

    #
    #   Fields
    #

    @property  # Override
    def target(self) -> int:
        """ Target bridge id (0 = addressed to the server). """
        return self.__target

    @property  # Override
    def source(self) -> int:
        """ Source bridge id (0 = handshake / server-down). """
        return self.__source

    @property  # Override
    def sn(self) -> int:
        """ Data serial number (0 for system commands). """
        return self.__sn

    @property  # Override
    def index(self) -> int:
        """ Fragment index (0 for mini packets). """
        return self.__index

    @property  # Override
    def count(self) -> int:
        """ Fragment count (1 for mini packets; >1 when fragmented). """
        return self.__count

    @property  # Override
    def command(self) -> int:
        """ Reserved command value (0 = empty command, plain DATA). """
        return self.__command

    @property  # Override
    def payload(self) -> bytes:
        """ Payload bytes (empty for none). """
        return self.__payload

    #
    #   Serialization
    #

    # Override
    def pack(self) -> bytes:
        """ Serialise to the wire bytes (header + payload, no attachment).

            The result is cached, so repeated calls are O(1) after the first.
        """
        data = self.__buffer
        if data is None:
            data = self.__pack()
            self.__buffer = data
        return data

    def __pack(self) -> bytes:
        """ Build the wire bytes from scratch, in the fixed field order:

            magic(4) | type(1) | headerLen(1) | payloadLen(2)
            | [target(4) source(4)]     if B=1
            | [sn(4)]                   if D=1
            | [index(E) count(E)]       if E>0
            | [command(4)]              if C=1
            | payload(payloadLen)
        """
        h_len = self.header_length
        p_len = self.payload_length
        data = bytearray(h_len + p_len)
        data[0:4] = MAGIC_CODE
        data[4] = calc_type(ack=self.ack, bid=self.bid, cmd=self.cmd, dsn=self.dsn, ext=self.ext)
        data[5] = h_len
        data[6:8] = p_len.to_bytes(2, 'big')
        offset = 8
        if self.bid != 0:
            _write_uint32(data=data, offset=offset, value=self.target)
            offset += 4
            _write_uint32(data=data, offset=offset, value=self.source)
            offset += 4
        if self.dsn != 0:
            _write_uint32(data=data, offset=offset, value=self.sn)
            offset += 4
        if self.ext > 0:
            width = self.ext
            _write_ext(data=data, offset=offset, width=width, value=self.index)
            offset += width
            _write_ext(data=data, offset=offset, width=width, value=self.count)
            offset += width
        if self.cmd != 0:
            _write_uint32(data=data, offset=offset, value=self.command)
            offset += 4
        # assert offset == h_len, 'pack failed: %d != %d, payload length: %d' % (offset, h_len, p_len)
        if p_len > 0:
            data[offset:offset + p_len] = self.payload
        return bytes(data)


#
#   byte helpers
#

def _write_uint32(data: bytearray, offset: int, value: int):
    """ Write a big-endian unsigned 32-bit integer into data at offset. """
    data[offset:offset + 4] = value.to_bytes(4, 'big')


def _write_ext(data: bytearray, offset: int, width: int, value: int):
    """ Write a big-endian unsigned integer of width bytes (1, 2, 3 or 4). """
    data[offset:offset + width] = value.to_bytes(width, 'big')
