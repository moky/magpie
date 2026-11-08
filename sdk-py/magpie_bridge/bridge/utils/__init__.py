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

import logging

from .coding import utf8_encode, utf8_decode
from .coding import hex_encode, hex_decode
from .coding import base64_encode, base64_decode
from .coding import json_encode, json_decode
from .coding import parse_json
from .coding import socket_identity_hash
from .coding import generate_token, verify_token

from .coding import SocketAddress
from .coding import SharedCounters

from .config import ServerConfig
from .enigma import Enigma, HkdfEnc
from .hkdf import HkdfCipher, HkdfSha256


log = logging.getLogger('magpie_bridge')


__all__ = [

    'utf8_encode', 'utf8_decode',
    'hex_encode', 'hex_decode',
    'base64_encode', 'base64_decode',
    'json_encode', 'json_decode',
    'parse_json',
    'socket_identity_hash',
    'generate_token', 'verify_token',

    'SocketAddress',
    'SharedCounters',

    'ServerConfig',
    'Enigma', 'HkdfEnc',
    'HkdfCipher', 'HkdfSha256',

    'log',

]
