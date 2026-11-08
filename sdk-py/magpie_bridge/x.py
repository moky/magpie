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
    def generate(self, *, secret: bytes, message: bytes) -> bytes:
        """ Generate MAC tag over the message with the secret key.

            Args:
                secret: secret cryptographic key.
                message: input binary payload.

            Returns:
                Fixed-size MAC tag as bytes.
        """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.generate()'
        )

    @abstractmethod
    def verify(self, tag: bytes, *, secret: bytes, message: bytes) -> bool:
        """ Constant-time verify MAC tag.

            Re-computes MAC from secret and message, then compares against
            the tag using side-channel safe comparison.

            Args:
                tag: MAC tag to check.
                secret: secret cryptographic key.
                message: input binary payload.

            Returns:
                True only if the tag matches.
        """
        raise NotImplementedError(
            f'Not implemented: {type(self).__module__}.{type(self).__name__}.verify()'
        )


class _StdlibMacGenerator(MacGenerator):
    """ Default MacGenerator on top of the standard hmac module. """

    # Override
    def generate(self, *, secret: bytes, message: bytes) -> bytes:
        # return hmac_module.new(secret, message, hashlib.sha256).digest()
        return hmac_module.digest(secret, message, 'sha256')

    # Override
    def verify(self, tag: bytes, *, secret: bytes, message: bytes) -> bool:
        computed = self.generate(secret=secret, message=message)
        return hmac_module.compare_digest(tag, computed)


class HmacSha256:
    """ HMAC-SHA256 utility (facade for MacGenerator).

        A default implementation on top of the standard hmac module is
        registered out of the box; applications may replace HmacSha256.generator
        with their own MacGenerator (e.g. a platform crypto API) at any time.
    """

    # The MacGenerator implementation (replaced by assignment).
    generator: MacGenerator = _StdlibMacGenerator()

    @staticmethod
    def generate(*, secret: bytes, message: bytes) -> bytes:
        """ Generate HMAC-SHA256 MAC tag.

            Args:
                secret: secret cryptographic key.
                message: input binary payload.

            Returns:
                The 32-byte MAC tag as bytes.
        """
        return HmacSha256.generator.generate(secret=secret, message=message)

    @staticmethod
    def verify(tag: bytes, *, secret: bytes, message: bytes) -> bool:
        """ Constant-time verify HMAC-SHA256 tag.

            Re-computes MAC from secret and message, then compares against
            the tag using side-channel safe comparison.

            Args:
                tag: MAC tag to check.
                secret: secret cryptographic key.
                message: input binary payload.

            Returns:
                True only if the tag matches.
        """
        return HmacSha256.generator.verify(tag, secret=secret, message=message)
