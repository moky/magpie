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
from typing import Optional, Dict, List

from .coding import base64_encode, base64_decode, hex_decode, json_decode
from .hkdf import HKDF_AVAILABLE, HkdfSha256


class HkdfEnc:
    """Encryption context of the encrypted handshake (docs/protocol.md 6.1).

    `info`/`aad` follow the pre-agreed formulas (both sides derive them
    from the bid instead of transmitting them); `to_dict()` serialises
    the wire bundle, `parse()` rebuilds it from the wire.
    """

    def __init__(self, key: str, *,
                 info: bytes, salt: bytes, nonce: bytes,
                 aad: bytes, tag: Optional[bytes] = None):
        """Create the encryption context with the given fields.

        Args:
            key: name of the shared enigma.
            info: HKDF context (pre-agreed formula, never transmitted).
            salt: 16-byte HKDF salt (one-shot CSPRNG).
            nonce: 12-byte AES-GCM nonce (one-shot CSPRNG).
            aad: additional authenticated data (pre-agreed formula).
            tag: 16-byte GCM authentication tag, None before encryption.
        """
        super().__init__()
        self.key = key
        self.info = info
        self.salt = salt
        self.nonce = nonce
        self.aad = aad
        self.tag = tag
        self.ciphertext: Optional[bytes] = None

    def to_dict(self) -> Dict[str, str]:
        """Serialise into the wire bundle ('enigma' field of
        docs/protocol.md 6.1).

        Returns:
            The bundle dict: key/algorithm/salt/nonce/tag, with the
            binary fields base64-encoded.
        """
        return {
            'key': self.key,
            'algorithm': 'HKDF-SHA256+AES-256-GCM',
            'salt': base64_encode(self.salt),
            'nonce': base64_encode(self.nonce),
            'tag': base64_encode(self.tag),
        }

    @classmethod
    def _build_info(cls, bid: int) -> bytes:
        """The pre-agreed HKDF info: both sides derive it from the bid
        instead of transmitting it with the ciphertext."""
        return f'enigma-v1:bid={bid}'.encode('ascii')

    @classmethod
    def _build_aad(cls, bid: int) -> bytes:
        """The pre-agreed additional authenticated data."""
        return f'magpie-v1:bid={bid}'.encode('ascii')

    @classmethod
    def create(cls, key: str, *, bid: int) -> 'HkdfEnc':
        """Build an encryption context with fresh random salt/nonce
        (server side).

        Args:
            key: name of the shared enigma.
            bid: the bridge id binding this ciphertext to a context.

        Returns:
            A new HkdfEnc ready for Enigma.encrypt_secret().
        """
        salt = os.urandom(16)
        nonce = os.urandom(12)
        info = cls._build_info(bid=bid)
        aad = cls._build_aad(bid=bid)
        return cls(key=key, info=info, salt=salt, nonce=nonce, aad=aad)

    @classmethod
    def parse(cls, bundle: Dict[str, str], *, bid: int) -> 'HkdfEnc':
        """Rebuild the encryption context from the wire bundle (client
        side).

        Args:
            bundle: the 'enigma' field received in the "SYN!" payload.
            bid: the bridge id binding this ciphertext to a context.

        Returns:
            A new HkdfEnc matching the sender's context.

        Raises:
            AssertionError: when the bundle is malformed (wrong
                algorithm or missing fields).
        """
        if bundle.get('algorithm') != 'HKDF-SHA256+AES-256-GCM':
            assert False, f'hkdf error: {bundle}'
        else:
            key = bundle.get('key')
            salt = bundle.get('salt')
            nonce = bundle.get('nonce')
            tag = bundle.get('tag')
            if key is None or salt is None or nonce is None or tag is None:
                assert False, f'hkdf error: {bundle}'
            else:
                return cls(key=key,
                           info=cls._build_info(bid=bid),
                           aad=cls._build_aad(bid=bid),
                           salt=base64_decode(salt),
                           nonce=base64_decode(nonce),
                           tag=base64_decode(tag))


class Enigma:
    """Application secret (enigma) handler: HKDF-SHA256 + AES-256-GCM.

    The key table maps names to their input key material (ikm);
    `decrypt_secret` derives the AES-256 key from the ikm with
    HKDF-SHA256 (salt, and info/aad derived from the bid by the
    pre-agreed formulas), then decrypts the AES-256-GCM datagram
    (nonce, tag).
    """

    def __init__(self, secrets: Dict[str, bytes] = None):
        """Create the enigma handler with an initial key table.

        Args:
            secrets: name -> ikm map; when omitted, a demo secret
                     ('TW9reS') is registered for development.
        """
        super().__init__()
        self.__secrets: Dict[str, bytes] = {}
        if secrets is not None:
            self.__secrets.update(secrets)
        else:
            b64 = 'TW9reSBsb3ZlcyBNYXkgTGVlIGZvcmV2ZXIh'
            ikm = base64_decode(b64)
            assert ikm is not None, f'failed to decode "{b64}"'
            self.__secrets['TW9reS'] = ikm

    @property
    def empty(self) -> bool:
        """Whether the key table is empty (plain handshake mode)."""
        return len(self.__secrets) == 0

    @property
    def count(self) -> int:
        """Number of enigma keys in the table."""
        return len(self.__secrets)

    @property
    def key_names(self) -> List[str]:
        """The key names held in the key table (sent as the 'enigmas'
        list in the "SYN?" payload)."""
        return list(self.__secrets.keys())

    def get_secret(self, key: str) -> Optional[bytes]:
        """ Look up an enigma key's secret bytes (ikm). """
        return self.__secrets.get(key)

    def encrypt_secret(self, secret: bytes, enc: HkdfEnc) -> Optional[HkdfEnc]:
        """Encrypt the plaintext secret with the named enigma.

        Fills [enc].ciphertext and [enc].tag, and returns it; returns
        None when the key is unknown to this handler.
        """
        ikm = self.__secrets.get(enc.key)
        if ikm is None:
            return None
        aes_key = HkdfSha256.derive(ikm, salt=enc.salt, info=enc.info)
        results = HkdfSha256.encrypt(secret, key=aes_key, nonce=enc.nonce, aad=enc.aad)
        enc.ciphertext = results[:-16]
        enc.tag = results[-16:]
        return enc

    def decrypt_secret(self, secret_b64: str, enc: HkdfEnc) -> Optional[bytes]:
        """Decrypt the base64-encoded secret with the named enigma
        (docs/client.md 5.2): the [enc].salt field feeds HKDF-SHA256,
        whose info/aad follow the pre-agreed formulas.

        Returns the plaintext secret bytes, or None when the key is
        unknown or the tag does not verify.
        """
        ikm = self.__secrets.get(enc.key)
        if ikm is not None:
            ciphertext = base64_decode(secret_b64)
            aes_key = HkdfSha256.derive(ikm, salt=enc.salt, info=enc.info)
            return HkdfSha256.decrypt(ciphertext,
                                      key=aes_key,
                                      nonce=enc.nonce,
                                      tag=enc.tag,
                                      aad=enc.aad)

    @classmethod
    def available(cls) -> bool:
        """ Whether the optional cryptography dependency is importable. """
        return HKDF_AVAILABLE

    @classmethod
    def load_secrets(cls, path: Optional[str]) -> Optional[Dict[str, bytes]]:
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
            decoded = cls._decode(value)
            if decoded is not None:
                result[key] = decoded
        return result

    @classmethod
    def _decode(cls, value: str) -> Optional[bytes]:
        """Decode a prefixed value from the secrets file.

        Args:
            value: raw string value, either 'base64,...' or 'hex,...'.

        Returns:
            The decoded bytes, or None when the prefix is unknown.
        """
        if value.startswith('base64,'):
            return base64_decode(value[7:])
        elif value.startswith('hex,'):
            return hex_decode(value[4:])
