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

import base64
import hashlib
import json
import logging
import time
from typing import Optional, Sequence, Any, List, Dict

from ..x import HmacSha256


log = logging.getLogger('magpie_bridge')


def utf8_encode(s: str) -> bytes:
    """ Encode a string as UTF-8 bytes. """
    return s.encode('utf-8')


def utf8_decode(d: bytes) -> Optional[str]:
    """ Decode UTF-8 bytes; undecodable bytes are replaced with U+FFFD.

        Returns None when `d` is not a bytes-like object.
    """
    try:
        return d.decode('utf-8', errors='replace')
    except (UnicodeDecodeError, AttributeError):
        return None


def hex_encode(d: bytes) -> str:
    return d.hex()


def hex_decode(s: str) -> Optional[bytes]:
    try:
        return bytes.fromhex(s)
    except ValueError:
        return None


def base64_encode(d: bytes) -> str:
    """ Encode bytes as a Base64 (ASCII) string. """
    b64 = base64.b64encode(d)
    return b64.decode('ascii')


def base64_decode(s: str) -> Optional[bytes]:
    """ Decode a Base64 (ASCII) string.

        Returns None when `s` is not valid Base64 (e.g. forged input with
        broken padding), so callers can drop it like any other malformed
        field instead of crashing.
    """
    try:
        return base64.b64decode(s)
    except (ValueError, TypeError):
        return None


def json_encode(o: Dict[str, Any]) -> str:
    """Serialize a dict to a JSON string.

        Args:
            o: the dict to serialize.

        Returns:
            the JSON string.
    """
    return json.dumps(o)


def json_decode(s: str) -> Optional[Dict[str, Any]]:
    """Parse the leading JSON object from a string, ignoring trailing
    garbage (same lenient behaviour as parse_json).

        Args:
            s: the JSON string.

        Returns:
            the parsed dict, or None when `s` is not valid JSON.
    """
    # return json.load(s)
    try:
        obj, _ = json.JSONDecoder().raw_decode(s)
        return obj
    except ValueError:
        return None


def parse_json(payload: Optional[bytes]) -> Optional[Dict[str, Any]]:
    """Parse the leading JSON object, ignoring trailing padding bytes.

    Java's org.json.JSONObject uses a JSONTokener that stops at the end of
    the first value; Python's json.loads is strict and rejects trailing
    garbage. Clients pad handshake payloads to 512 bytes with raw bytes,
    so we must mirror the lenient behaviour.
    """
    text = utf8_decode(payload)
    if text:
        return json_decode(text)


def socket_identity_hash(socket_key: str) -> int:
    """31-bit identity hash of a socket: SHA-256(key) truncated to 32 bits,
    bit0 cleared (bit0 is reused as the permit valid flag)."""
    data = utf8_encode(socket_key)
    digest = hashlib.sha256(data).digest()
    return int.from_bytes(digest[:4], 'big') & 0xFFFFFFFE


#
#   handshake token
#

def _concat_token(bid: int, secret: str, socket: str) -> bytes:
    text = f'bid={bid}&secret={secret}&socket={socket}'
    return utf8_encode(text)


def generate_token(token_key: bytes,
                   bid: int, secret_b64: str, socket_key: str) -> str:
    """token = Base64(HMAC-SHA256(token_key,
       "bid={bid}&secret={secret}&socket={socket}"))
       fields are merged in key alphabetical order."""
    data = _concat_token(bid=bid, secret=secret_b64, socket=socket_key)
    tag = HmacSha256.generate(secret=token_key, message=data)
    return base64_encode(tag)


def verify_token(token: str, token_keys: Sequence[bytes],
                 bid: int, secret_b64: str, socket_key: str) -> bool:
    """Recompute and compare against all known token keys (up to 2)."""
    tag = base64_decode(token)
    if tag is None:
        return False
    data = _concat_token(bid=bid, secret=secret_b64, socket=socket_key)
    for key in token_keys:
        if HmacSha256.verify(tag, secret=key, message=data):
            return True
    return False


class SocketAddress:
    """Client socket identity: (ip, port)."""

    __slots__ = ['__ip', '__port']

    def __init__(self, ip: str, port: int):
        super().__init__()
        self.__ip = ip
        self.__port = port

    @classmethod
    def from_addr(cls, addr: tuple) -> 'SocketAddress':
        """Build from a recvfrom() address tuple."""
        return cls(addr[0], int(addr[1]))

    @property
    def ip(self) -> str:
        return self.__ip

    @property
    def port(self) -> int:
        return self.__port

    @property
    def host(self) -> str:
        return self.__ip

    def key(self) -> str:
        """String key used as the allocation-table index."""
        if ':' in self.__ip:
            return '[%s]:%d' % (self.__ip, self.__port)
        return '%s:%d' % (self.__ip, self.__port)

    def is_loopback(self) -> bool:
        if self.__ip == '::1' or self.__ip == '0:0:0:0:0:0:0:1':
            return True
        return self.__ip.startswith('127.')

    def is_broadcast_or_multicast(self) -> bool:
        ip = self.__ip
        if ':' in ip:
            return ip.lower().startswith('ff')
        if ip == '255.255.255.255':
            return True
        first = int(ip.split('.')[0])
        return 224 <= first <= 239

    def __eq__(self, other: object) -> bool:
        return isinstance(other, SocketAddress) \
            and other.__ip == self.__ip and other.__port == self.__port

    def __ne__(self, other: object) -> bool:
        return not self.__eq__(other)

    def __hash__(self) -> int:
        return hash((self.__ip, self.__port))

    def __str__(self) -> str:
        return '(%r, %d)' % (self.__ip, self.__port)

    def __repr__(self) -> str:
        return 'SocketAddress(%r, %d)' % (self.__ip, self.__port)


class SharedCounters:
    """Rate limiter for "unconfirmed" FAIL replies.

    Bucketed quota limiter: requests are routed to a bucket by
    hash(socket) % buckets; each bucket starts with `limit` replies per
    second (lazy refresh), one reply consumes one unit. Bound clients
    never go through this limiter.
    """

    def __init__(self, buckets: int, limit: int):
        super().__init__()
        self.__buckets = int(buckets)
        self.__limit = int(limit)
        self.__quota: List[int] = [self.__limit] * self.__buckets
        self.__expires: List[float] = [0.0] * self.__buckets

    def hit(self, socket_key: str) -> bool:
        """Consume one unit; return True when the rate limit allows."""
        idx = hash(socket_key) % self.__buckets
        now = time.time()
        if now >= self.__expires[idx]:
            self.__quota[idx] = self.__limit
            self.__expires[idx] = now + 1.0
        if self.__quota[idx] > 0:
            self.__quota[idx] -= 1
            return True
        return False
