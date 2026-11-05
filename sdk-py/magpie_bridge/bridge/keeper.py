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
import os
import random
import threading
from typing import Optional, Tuple, List, Dict, Any

from .utils import log, generate_token, verify_token
from .config import ServerConfig
from .enigma import Enigma


class SecretKeeper:
    """Owns the token keys and the enigma table.

    - client secrets: freshly generated per handshake (32-byte random);
    - token keys: rotated every token_key_rotate_interval, the latest two
      are kept so tokens created before a rotation stay valid;
    - enigma table: reloaded from the app-secret file every
      app_secret_reload_interval (docs/server.md 6).
    """

    def __init__(self, config: ServerConfig):
        super().__init__()
        self.__config = config
        # token keys
        self.__token_keys: List[bytes] = [os.urandom(32)]
        self.__last_token_key_rotate = 0.0
        # enigma
        self.__lock = threading.Lock()  # guards the enigma table
        self.__enigma_secrets: Dict[str, bytes] = {}
        self.__last_enigma_load = 0.0

    # noinspection PyMethodMayBeStatic
    def new_secret(self) -> bytes:
        """Generate a fresh 32-byte client secret."""
        return os.urandom(32)

    # noinspection PyMethodMayBeStatic
    def encode_secret(self, secret: bytes) -> str:
        """Encode a secret as base64 (ASCII).

        Args:
            secret: the raw secret bytes.

        Returns:
            the base64 string.
        """
        return base64.b64encode(secret).decode('ascii')

    # noinspection PyMethodMayBeStatic
    def decode_secret(self, secret_b64: str) -> Optional[bytes]:
        """Decode a secret from base64 (ASCII).

        Args:
            secret_b64: the base64 string.

        Returns:
            the raw secret bytes.
        """
        return base64.b64decode(secret_b64)

    #
    #   Enigma
    #

    @property
    def enigma_empty(self) -> bool:
        return len(self.__enigma_secrets) == 0

    @property
    def enigma_count(self) -> int:
        return len(self.__enigma_secrets)

    def load_enigma_secrets(self, now: float):
        """Reload the app-secret (enigma) table from the config file.

        On reload failure the previous table is kept; the reload timer is reset
        so the next attempt happens after app_secret_reload_interval.
        """
        if now - self.__last_enigma_load < self.__config.app_secret_reload_interval:
            return
        else:
            self.__last_enigma_load = now
        # load from path
        path = self.__config.app_secret_file
        if not path:
            new = {}
        else:
            new = Enigma.load_secrets(path=path)
            if new is None:
                # reload failure (missing / unreadable / unparsable file):
                # keep the previous table, never degrade mid-flight
                log.warning('app secret reload failed; keeping old table')
                return
            if not Enigma.available():
                log.warning('cryptography not available; encrypted mode disabled')
                new = {}
        with self.__lock:
            self.__enigma_secrets = new

    def get_enigma_secret(self, key: str) -> Optional[bytes]:
        """ Look up an enigma key's secret bytes. """
        if key is None:
            return None
        with self.__lock:
            return self.__enigma_secrets.get(key)

    def _choose_enigma(self, candidates: List[str]) -> Optional[str]:
        """Pick one enigma key from the candidates that the server knows.

        Args:
            candidates: keys proposed by the client.

        Returns:
            a known key, or None when none matches.
        """
        with self.__lock:
            keys = [k for k in candidates if k in self.__enigma_secrets]
        count = len(keys)
        if count == 0:
            return None
        elif count == 1:
            return keys[0]
        else:
            return random.choice(keys)

    def enigma_encrypt(self, plaintext: bytes, candidates: List[str],
                       bid: int) -> Tuple[Optional[str], Optional[Dict[str, Any]]]:
        """ Encrypt the client secret with a mutually-held enigma.

            Returns (ciphertext_b64, bundle) or (None, None) when no
            candidate matches; the bundle follows the JSON format of
            docs/protocol.md 6.1.
        """
        key = self._choose_enigma(candidates=candidates)
        if key is None:
            return None, None
        with self.__lock:
            ikm = self.__enigma_secrets.get(key)
        if ikm is None:
            return None, None
        box = Enigma.encrypt(ikm=ikm, plaintext=plaintext, bid=bid)
        return box['ciphertext'], {
            'key': key,
            'algorithm': 'HKDF-SHA256+AES-256-GCM',
            'hkdf': {
                'salt': box['salt'],
                'info': box['info'],
            },
            'nonce': box['nonce'],
            'tag': box['tag'],
            'aad': '',
        }

    def enigma_decrypt(self, bundle: Dict[str, Any], secret_b64: str) -> Optional[bytes]:
        """ Decrypt the ciphertext secret with the named enigma.

            Returns the plaintext secret bytes, or None when the key is
            unknown to the server.
        """
        key = bundle.get('key')
        with self.__lock:
            ikm = self.__enigma_secrets.get(key)
        if ikm is None:
            return None
        # decrypt
        return Enigma.decrypt(
            ikm=ikm,
            salt=base64.b64decode(bundle['hkdf']['salt']),
            info=base64.b64decode(bundle['hkdf']['info']),
            nonce=base64.b64decode(bundle['nonce']),
            ciphertext=base64.b64decode(secret_b64),
            tag=base64.b64decode(bundle['tag'])
        )

    #
    #   Token Keys
    #

    def rotate_token_keys(self, now: float):
        """Rotate the token signing keys, keeping the latest two.

        Args:
            now: current epoch seconds.
        """
        if now - self.__last_token_key_rotate < self.__config.token_key_rotate_interval:
            return
        else:
            self.__last_token_key_rotate = now
        # shift new key
        self.__token_keys.insert(0, os.urandom(32))
        del self.__token_keys[2:]

    def create_token(self, bid: int, secret_b64: str, socket_key: str) -> str:
        """ Create the handshake token with the newest token key. """
        token_key = self.__token_keys[0]
        return generate_token(token_key=token_key,
                              bid=bid, secret_b64=secret_b64, socket_key=socket_key)

    def check_token(self, token: str, bid: int, secret_b64: str, socket_key: str) -> bool:
        """ Verify the token against any of the active token keys. """
        token_keys = self.__token_keys
        return verify_token(token=token, token_keys=token_keys,
                            bid=bid, secret_b64=secret_b64, socket_key=socket_key)
