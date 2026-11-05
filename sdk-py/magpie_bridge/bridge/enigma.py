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

import os
from typing import Optional, Dict

from .utils import base64_encode, base64_decode, hex_decode, json_decode

#
#   optional cryptography dependency
#

try:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes
    ENIGMA_AVAILABLE = True
except ImportError:  # pragma: no cover
    AESGCM = None
    HKDF = None
    hashes = None
    ENIGMA_AVAILABLE = False


_ENIGMA_INFO_PREFIX = b'enigma-v1:bid='


class Enigma:
    """Application secret (enigma) handler: HKDF-SHA256 + AES-256-GCM."""

    @staticmethod
    def available() -> bool:
        """ Whether the optional cryptography dependency is importable. """
        return ENIGMA_AVAILABLE

    @staticmethod
    def load_secrets(path: Optional[str]) -> Optional[Dict[str, bytes]]:
        """Load the enigma map from the JSON app-secret file.

        File format:
            {"enigma": {"secrets": {"KEY": "hex,..." | "base64,..."}}}
        Returns:
            {}          -- no path configured, or an explicitly empty map
                           (legal switch back to the plain handshake mode);
            {key: bytes} -- parsed map;
            None        -- the file is missing / unreadable / unparsable;
                           callers must keep their previous table.
        """
        if not path:
            return {}
        try:
            with open(path, 'r', encoding='utf-8') as f:
                data = json_decode(f.read())
        except (IOError, OSError):
            return None
        if data is None:
            # unparsable file: callers keep their previous table
            return None
        enigmas = data.get('enigma')
        if not isinstance(enigmas, dict):
            # missing / non-object map: legal switch back to plain mode
            return {}
        enigmas = enigmas.get('secrets')
        if not isinstance(enigmas, dict):
            # missing / non-object map: legal switch back to plain mode
            return {}
        result: Dict[str, bytes] = {}
        for key, value in enigmas.items():
            if not isinstance(key, str) or not isinstance(value, str):
                continue
            decoded = Enigma._decode(value)
            if decoded is not None:
                result[key] = decoded
        return result

    @staticmethod
    def _decode(value: str) -> Optional[bytes]:
        if value.startswith('base64,'):
            return base64_decode(value[7:])
        elif value.startswith('hex,'):
            return hex_decode(value[4:])

    @staticmethod
    def encrypt(ikm: bytes, plaintext: bytes, bid: int) -> Dict[str, str]:
        """Encrypt the plaintext secret.

        Returns a dict of base64-encoded salt/info/nonce/tag/ciphertext.
        """
        if not ENIGMA_AVAILABLE:
            raise RuntimeError('cryptography package is not available')
        salt = os.urandom(16)
        info = _ENIGMA_INFO_PREFIX + str(bid).encode('ascii')
        nonce = os.urandom(12)
        hkdf = HKDF(algorithm=hashes.SHA256(), length=32, salt=salt,
                    info=info)
        key = hkdf.derive(ikm)
        aes = AESGCM(key)
        ciphertext_and_tag = aes.encrypt(nonce, plaintext, b'')
        ciphertext = ciphertext_and_tag[:-16]
        tag = ciphertext_and_tag[-16:]
        return {
            'salt': base64_encode(salt),
            'info': base64_encode(info),
            'nonce': base64_encode(nonce),
            'tag': base64_encode(tag),
            'ciphertext': base64_encode(ciphertext),
        }

    @staticmethod
    def decrypt(ikm: bytes, salt: bytes, info: bytes, nonce: bytes,
                ciphertext: bytes, tag: bytes) -> bytes:
        """Decrypt the ciphertext; raises on tag mismatch."""
        if not ENIGMA_AVAILABLE:
            raise RuntimeError('cryptography package is not available')
        hkdf = HKDF(algorithm=hashes.SHA256(), length=32, salt=salt,
                    info=info)
        key = hkdf.derive(ikm)
        aes = AESGCM(key)
        return aes.decrypt(nonce, ciphertext + tag, b'')
