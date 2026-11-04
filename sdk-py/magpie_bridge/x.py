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

import hashlib
import hmac as hmac_module

from abc import ABC, abstractmethod


class MacGenerator(ABC):
    """ Interface for computing MAC (Message Authentication Code) values,
        e.g. HMAC with various underlying hash algorithms.

        Supported MAC algorithms include (but are not limited to):
        - HMAC-SHA-256
        - HMAC-SHA-512
        - HMAC-SHA-1
    """

    @abstractmethod
    def generate(self, key: bytes, data: bytes) -> bytes:
        """ Generate MAC tag from secret key and input data.

            Args:
                key: secret cryptographic key.
                data: input binary payload.

            Returns:
                Fixed-size MAC tag as bytes.
        """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.generate()'
        )

    @abstractmethod
    def verify(self, key: bytes, data: bytes, tag: bytes) -> bool:
        """ Constant-time verify MAC tag.

            Re-computes MAC from key and data, then compares against tag
            using side-channel safe comparison.

            Args:
                key: secret cryptographic key.
                data: input binary payload.
                tag: MAC tag to check.

            Returns:
                True only if the tag matches.
        """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.verify()'
        )


class _StdlibMacGenerator(MacGenerator):
    """ Default MacGenerator on top of the standard hmac module. """

    # Override
    def generate(self, key: bytes, data: bytes) -> bytes:
        return hmac_module.new(key, data, hashlib.sha256).digest()

    # Override
    def verify(self, key: bytes, data: bytes, tag: bytes) -> bool:
        computed = self.generate(key=key, data=data)
        return _constant_time_eq(a=tag, b=computed)


def _constant_time_eq(a: bytes, b: bytes) -> bool:
    """ Constant-time byte comparison (defends against timing attacks).

        Args:
            a: first byte string.
            b: second byte string.

        Returns:
            True if both strings are equal, False otherwise.
    """
    size = len(a)
    if size != len(b):
        return False
    diff = 0
    for i in range(size):
        diff |= (a[i] ^ b[i])
    return diff == 0


class HmacSha256:
    """ HMAC-SHA256 utility (facade for MacGenerator).

        A default implementation on top of the standard hmac module is
        registered out of the box; applications may replace HmacSha256.generator
        with their own MacGenerator (e.g. a platform crypto API) at any time.
    """

    # The MacGenerator implementation (replaced by assignment).
    generator: MacGenerator = _StdlibMacGenerator()

    @staticmethod
    def generate(key: bytes, data: bytes) -> bytes:
        """ Generate HMAC-SHA256 MAC tag.

            Args:
                key: secret cryptographic key.
                data: input binary payload.

            Returns:
                The 32-byte MAC tag as bytes.
        """
        return HmacSha256.generator.generate(key=key, data=data)

    @staticmethod
    def verify(key: bytes, data: bytes, tag: bytes) -> bool:
        """ Constant-time verify HMAC-SHA256 tag.

            Re-computes MAC from key and data, then compares against tag
            using side-channel safe comparison.

            Args:
                key: secret cryptographic key.
                data: input binary payload.
                tag: MAC tag to check.

            Returns:
                True only if the tag matches.
        """
        return HmacSha256.generator.verify(key=key, data=data, tag=tag)
