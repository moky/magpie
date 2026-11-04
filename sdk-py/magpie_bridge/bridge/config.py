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

import configparser
from typing import Optional, Dict


class ServerConfig:
    """Runtime configuration with code defaults (INI overrides per-key)."""

    DEFAULTS = {
        'host': '0.0.0.0',
        'port': '9527',
        'socket_buffer_length': '4194304',
        # forward threads
        'forwarders': '8',
        'forward_limit_per_window': '4096',
        'forward_window': '0.1',
        # bid record
        'record_active_timeout': '60.0',
        'record_expires': '86400.0',
        'record_recycle_interval': '600.0',
        'max_records': '65536',
        'allowlist_max_entries': '256',
        'bid_allocation_retries': '16',
        # security
        'handshake_token_timeout': '60.0',
        'handshake_min_payload': '512',
        'unconfirmed_reply_buckets': '1024',
        'reply_rate_limit': '10',
        'noop_immunity_window': '2.0',
        # secrets
        'app_secret_file': '',
        'app_secret_reload_interval': '600.0',
        'server_secret_rotate_interval': '600.0',
        # task queue
        'waiting_queue_size': '4096',
        'manager_queue_size': '1024',
        'forwarder_queue_size': '65536',
    }

    def __init__(self, values: Optional[Dict[str, str]] = None):
        super().__init__()
        self.__values: Dict[str, str] = dict(self.DEFAULTS)
        if values:
            self.__values.update(values)

    @classmethod
    def load(cls, path: Optional[str], section: str = 'magpie-bridge') -> 'ServerConfig':
        values: Dict[str, str] = {}
        try:
            cp = configparser.ConfigParser()
            # read() silently ignores a missing/unreadable file; the caller
            # then keeps the code defaults (docs/server.md 9.1 rule 3).
            if path is not None:
                cp.read(path, encoding='utf-8')
            if cp.has_section(section):
                for key, value in cp.items(section):
                    values[key] = value
        except (IOError, OSError, configparser.Error):
            pass
        return cls(values)

    def set_value(self, key: str, value: str) -> None:
        """ Set one config key, overriding the code default. """
        self.__values[key] = value

    def get_value(self, key: str) -> str:
        """ Read one config key, falling back to the code default. """
        value = self.__values.get(key)
        if value is None:
            return self.DEFAULTS[key]
        else:
            return value

    def get_int(self, key: str) -> int:
        """ Read one config key as an integer. """
        return int(self.get_value(key=key))

    def get_float(self, key: str) -> float:
        """ Read one config key as a float. """
        return float(self.get_value(key=key))

    @property
    def host(self) -> str:
        return self.get_value(key='host')

    @property
    def port(self) -> int:
        return self.get_int(key='port')

    @property
    def socket_buffer_length(self) -> int:
        return self.get_int(key='socket_buffer_length')

    #
    #   Forward Threads
    #

    @property
    def forwarders(self) -> int:
        return self.get_int(key='forwarders')

    @property
    def forward_limit_per_window(self) -> int:
        return self.get_int(key='forward_limit_per_window')

    @property
    def forward_window(self) -> float:
        return self.get_float(key='forward_window')

    #
    #   BID Records
    #

    @property
    def record_active_timeout(self) -> float:
        return self.get_float(key='record_active_timeout')

    @property
    def record_expires(self) -> float:
        return self.get_float(key='record_expires')

    @property
    def record_recycle_interval(self) -> float:
        return self.get_float(key='record_recycle_interval')

    @property
    def max_records(self) -> int:
        return self.get_int(key='max_records')

    @property
    def allowlist_max_entries(self) -> int:
        return self.get_int(key='allowlist_max_entries')

    @property
    def bid_allocation_retries(self) -> int:
        return self.get_int(key='bid_allocation_retries')

    #
    #   Security Limits
    #

    @property
    def handshake_token_timeout(self) -> float:
        return self.get_float(key='handshake_token_timeout')

    @property
    def handshake_min_payload(self) -> int:
        return self.get_int(key='handshake_min_payload')

    @property
    def unconfirmed_reply_buckets(self) -> int:
        return self.get_int(key='unconfirmed_reply_buckets')

    @property
    def reply_rate_limit(self) -> int:
        return self.get_int(key='reply_rate_limit')

    @property
    def noop_immunity_window(self) -> float:
        return self.get_float(key='noop_immunity_window')

    #
    #   Secrets
    #

    @property
    def app_secret_file(self) -> str:
        return self.get_value(key='app_secret_file')

    @property
    def app_secret_reload_interval(self) -> float:
        return self.get_float(key='app_secret_reload_interval')

    @property
    def server_secret_rotate_interval(self) -> float:
        return self.get_float(key='server_secret_rotate_interval')

    #
    #   Task Queue
    #

    @property
    def waiting_queue_size(self) -> int:
        return self.get_int(key='waiting_queue_size')

    @property
    def manager_queue_size(self) -> int:
        return self.get_int(key='manager_queue_size')

    @property
    def forwarder_queue_size(self) -> int:
        return self.get_int(key='forwarder_queue_size')
