#! /usr/bin/env python3
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

import argparse
import logging
import logging.handlers
import os
import sys
from typing import List, Optional

from magpie_bridge.bridge.server import ServerConfig, Server

DATE_FORMAT = '%Y-%m-%d %H:%M:%S'
LOG_FORMAT = '[{asctime}] {message}'

# keep the most recent 30 days of log files
LOG_BACKUP_DAYS = 30

# default INI path tried when --config is omitted; a missing file falls back
# to the code defaults without raising (see docs/server.md 9.3).
DEFAULT_CONFIG_PATH = '/etc/magpie/config.ini'


class _ColorFormatter(logging.Formatter):
    """Console formatter: colorize records by level.

    ERROR red, WARNING yellow, DEBUG gray; INFO keeps the terminal's
    default color. File handlers keep the plain formatter, so log files
    stay free of ANSI escape sequences.
    """

    _COLORS = {
        logging.DEBUG: '\033[90m',    # gray
        logging.WARNING: '\033[93m',  # yellow
        logging.ERROR: '\033[91m',    # red
    }
    _RESET = '\033[0m'

    def format(self, record: logging.LogRecord) -> str:
        message = super().format(record)
        color = self._COLORS.get(record.levelno)
        return '%s%s%s' % (color, message, self._RESET) if color else message


def _configure_logging(log_dir: str) -> None:
    """Write colorized records to the console and the log file (tail -f
    renders the ANSI colors in the terminal)."""
    root = logging.getLogger()
    root.setLevel(logging.INFO)

    formatter = _ColorFormatter(LOG_FORMAT, datefmt=DATE_FORMAT, style='{')
    console = logging.StreamHandler(sys.stdout)
    console.setFormatter(formatter)
    root.addHandler(console)

    if not log_dir:
        return

    if not os.path.isdir(log_dir):
        sys.stderr.write('error: log directory does not exist: %s\n' % log_dir)
        sys.exit(2)

    log_file = os.path.join(log_dir, 'magpie-bridge.log')
    try:
        handler = logging.handlers.TimedRotatingFileHandler(
            log_file,
            when='midnight',
            interval=1,
            backupCount=LOG_BACKUP_DAYS,
            encoding='utf-8',
        )
    except OSError as e:
        sys.stderr.write('error: cannot open log file %s: %s\n' % (log_file, e))
        sys.exit(2)

    handler.setLevel(logging.INFO)
    handler.setFormatter(formatter)
    root.addHandler(handler)


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog='magpie-bridge',
        description='Magpie Bridge UDP relay server')
    parser.add_argument('--host', default='',
                        help='bind address (INI "host" by default)')
    parser.add_argument('--port', type=int, default=0,
                        help='UDP port (INI "port" by default)')
    parser.add_argument('--config', default='',
                        help='path to the INI configuration file')
    parser.add_argument('--log-dir', default='',
                        help='directory for log files (console by default)')
    args = parser.parse_args(argv)

    _configure_logging(args.log_dir)

    config = ServerConfig.load(args.config or DEFAULT_CONFIG_PATH)
    # CLI overrides take precedence over the INI file
    if args.host:
        config.set_value(key='host', value=args.host)
    if args.port:
        config.set_value(key='port', value=str(args.port))
    Server(config).run()
    return 0


if __name__ == '__main__':
    sys.exit(main())
