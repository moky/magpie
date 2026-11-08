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

from abc import ABC, abstractmethod
from typing import Optional

#
#   optional cryptography dependency
#

try:
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes
    HKDF_AVAILABLE = True
except ImportError:  # pragma: no cover
    InvalidTag = None
    AESGCM = None
    HKDF = None
    hashes = None
    HKDF_AVAILABLE = False


class HkdfCipher(ABC):
    """ Interface for HKDF-SHA256 key derivation + AES-256-GCM encryption:
        the AES key is derived from the ikm with (salt, info), then the
        plaintext is encrypted/decrypted with AES-256-GCM (nonce, aad).
    """

    @abstractmethod
    def derive(self, ikm: bytes, *, salt: bytes, info: bytes) -> bytes:
        """ Derive the 32-byte AES key: HKDF-SHA256(ikm, salt, info).

            Args:
                ikm: input key material (e.g. the app secret).
                salt: optional random salt (16 bytes in this protocol).
                info: context string (pre-agreed formula, not transmitted).

            Returns:
                The 32-byte derived AES key.
        """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.derive()'
        )

    @abstractmethod
    def encrypt(self, plaintext: bytes, *,
                key: bytes, nonce: bytes, aad: bytes) -> bytes:
        """ Encrypt [plaintext] with the [key]: AES-256-GCM.

            Args:
                plaintext: raw binary payload to encrypt.
                key: the 32-byte AES-256 key.
                nonce: 12-byte per-encryption random nonce.
                aad: additional authenticated data (may be empty).

            Returns:
                Ciphertext + tag(16).
        """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.encrypt()'
        )

    @abstractmethod
    def decrypt(self, ciphertext: bytes, *,
                key: bytes, nonce: bytes, tag: bytes, aad: bytes) -> Optional[bytes]:
        """ Decrypt [ciphertext] + [tag] with the [key].

            Args:
                ciphertext: encrypted payload without the tag.
                key: the 32-byte AES-256 key.
                nonce: 12-byte nonce used on encryption.
                tag: 16-byte GCM authentication tag.
                aad: additional authenticated data (may be empty).

            Returns:
                The plaintext, or None when the tag does not verify.
        """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.decrypt()'
        )


class _CryptographyHkdf(HkdfCipher):
    """ Default HkdfCipher on top of the cryptography package. """

    @staticmethod
    def _require_available():
        """ Raise RuntimeError when the cryptography package is missing. """
        if not HKDF_AVAILABLE:
            raise RuntimeError('cryptography package is not available')

    # Override
    def derive(self, ikm: bytes, *, salt: bytes, info: bytes) -> bytes:
        self._require_available()
        hkdf = HKDF(algorithm=hashes.SHA256(), length=32, salt=salt, info=info)
        return hkdf.derive(ikm)

    # Override
    def encrypt(self, plaintext: bytes, *,
                key: bytes, nonce: bytes, aad: bytes) -> bytes:
        self._require_available()
        aes = AESGCM(key)
        return aes.encrypt(nonce, plaintext, aad)

    # Override
    def decrypt(self, ciphertext: bytes, *,
                key: bytes, nonce: bytes, tag: bytes, aad: bytes) -> Optional[bytes]:
        self._require_available()
        aes = AESGCM(key)
        try:
            return aes.decrypt(nonce, ciphertext + tag, aad)
        except InvalidTag:
            return None  # tag mismatch: tampered or wrong key


class HkdfSha256:
    """ HKDF-SHA256 + AES-256-GCM utility (facade for HkdfCipher).

        The three static methods mirror the HkdfCipher interface
        one-to-one: derive the 32-byte AES key from the ikm, then
        encrypt/decrypt with AES-256-GCM (nonce, aad).

        A default implementation on top of the cryptography package is
        registered out of the box; applications may replace HkdfSha256.cipher
        with their own HkdfCipher (e.g. a platform crypto API) at any time.
    """

    # The HkdfCipher implementation (replaced by assignment).
    cipher: HkdfCipher = _CryptographyHkdf()

    @staticmethod
    def derive(ikm: bytes, *, salt: bytes, info: bytes) -> bytes:
        """ Derive the 32-byte AES key: HKDF-SHA256(ikm, salt, info). """
        return HkdfSha256.cipher.derive(ikm, salt=salt, info=info)

    @staticmethod
    def encrypt(plaintext: bytes, *,
                key: bytes, nonce: bytes, aad: bytes) -> bytes:
        """ Encrypt plaintext with the key: AES-256-GCM.

            Returns ciphertext + tag(16).
        """
        return HkdfSha256.cipher.encrypt(plaintext, key=key, nonce=nonce, aad=aad)

    @staticmethod
    def decrypt(ciphertext: bytes, *,
                key: bytes, nonce: bytes, tag: bytes, aad: bytes) -> Optional[bytes]:
        """ Decrypt ciphertext + tag with the key (constant-time tag check).

            Returns the plaintext, or None when the tag does not verify.
        """
        return HkdfSha256.cipher.decrypt(ciphertext, key=key, nonce=nonce, tag=tag, aad=aad)
