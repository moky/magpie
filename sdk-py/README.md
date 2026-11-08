# Magpie Bridge (Python)

[![License](https://img.shields.io/github/license/moky/magpie)](https://github.com/moky/magpie/blob/main/LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](https://github.com/moky/magpie/pulls)
[![Platform](https://img.shields.io/badge/Platform-Python%203-brightgreen.svg)](https://github.com/moky/magpie/tree/main/docs)
[![Issues](https://img.shields.io/github/issues/moky/magpie)](https://github.com/moky/magpie/issues)
[![Repo Size](https://img.shields.io/github/repo-size/moky/magpie)](https://github.com/moky/magpie/archive/refs/heads/main.zip)
[![Tags](https://img.shields.io/github/tag/moky/magpie)](https://github.com/moky/magpie/tags)
[![Version](https://img.shields.io/pypi/v/magpie-bridge)](https://pypi.org/project/magpie-bridge)

[![Watchers](https://img.shields.io/github/watchers/moky/magpie)](https://github.com/moky/magpie/watchers)
[![Forks](https://img.shields.io/github/forks/moky/magpie)](https://github.com/moky/magpie/forks)
[![Stars](https://img.shields.io/github/stars/moky/magpie)](https://github.com/moky/magpie/stargazers)
[![Followers](https://img.shields.io/github/followers/moky)](https://github.com/orgs/moky/followers)

Reliable UDP Relay Network protocol library (Python).

## Modules

- `magpie_bridge/protocol/` — protocol definitions (commands, types, formulas)
- `magpie_bridge/` — packet classes and packet factories (SDK layer)
- `magpie_bridge/bridge/` — relay server and server-side tools

## Install

```bash
pip install magpie-bridge
```

Requires Python 3.6+. The base package has **no third-party runtime
dependencies** (pure standard library).

The encrypted handshake mode (MIP 320) additionally needs the
`cryptography` package — install it through the `enigma` extra:

```bash
pip install magpie-bridge[enigma]    # base package + cryptography
```

Without it, the SDK still works: packet packing/parsing and the
plain-handshake mode are unaffected; only the encrypted handshake mode
is unavailable (`Enigma.encrypt_secret/decrypt_secret` raise an explicit
`RuntimeError`).

## Server

After installation, start the relay server with:

```bash
magpie-bridge [--host=<ADDR>] [--port=<NUM>] [--config=<FILE>] [--log-dir=/tmp]
```

All arguments are named and optional:

- `--host`: bind address (default: INI `host`, otherwise `0.0.0.0`);
- `--port`: UDP listen port (default: INI `port`, otherwise `9527`); CLI
  `--host`/`--port` override the same-named INI keys;
- `--config`: config file path (default: `/etc/magpie/config.ini`; when the
  file, the section or a key is missing, the code default is used);
- `--log-dir`: log directory (default empty: no log file is written).

Unknown arguments print the usage and exit.

## Logs

Without `--log-dir`, records go to the console (stdout) only.

With `--log-dir=<dir>`, the records are written to the console **and** to a
daily-rotating log file under the directory:

- file: `<dir>/magpie-bridge.log` (rotates at midnight, 30 days retained);
- records are colorized by level — ERROR red, WARNING yellow, DEBUG gray,
  INFO in the terminal's default color — so `tail -f` renders them directly;
- the file contains ANSI escape codes; strip them with
  `sed 's/\x1b\[[0-9;]*m//g'` before feeding line-based analysis tools.

## Configuration

The config file is an INI file with a single section `[magpie-bridge]`:

```ini
[magpie-bridge]
host = 0.0.0.0
port = 9527
socket_buffer_length = 4194304
# forward threads
forwarders = 8
forward_limit_per_window = 4096
forward_window = 0.1
# bid record
record_active_timeout = 60.0
record_expires = 86400.0
record_recycle_interval = 600.0
max_records = 65536
allowlist_max_entries = 256
bid_allocation_retries = 16
# security
handshake_min_payload = 512
unconfirmed_reply_buckets = 1024
reply_rate_limit = 10
noop_immunity_window = 2.0
# secrets
app_secret_file = /etc/magpie/private/enigma.json
app_secret_reload_interval = 600.0
token_key_rotate_interval = 60.0
# task queue
waiting_queue_size = 4096
manager_queue_size = 1024
forwarder_queue_size = 65536
```

Time values are floating-point seconds; capacity values are integers
(packet counts, except `socket_buffer_length` which is bytes).

The server validates every datagram before relaying: it drops invalid
packets (bad magic / lengths), packets from broadcast or multicast
sources (amplification attack protection), packets whose source socket
does not match the recorded bid, and packets whose target bid is
missing, unpermitted or inactive.

## Message Packets

```python
from magpie_bridge import (BridgePacketFactory, DirectPacketFactory,
                           ReliablePacket)

bridge = BridgePacketFactory()
direct = DirectPacketFactory()

# handshake with the server
syn = bridge.syn(request=payload)                 # SYN? (source=0)
syn_ack = bridge.syn_ack(response=payload, target=bid)  # SYN! from the server
ack = bridge.ack(response=payload, source=bid)    # ACK! to the server

# normal data (relayed by the server; C=0 saves 4 bytes)
data = bridge.data(payload=payload,
                   target=target, source=source,
                   sn=sn, index=0, count=1)
signed = data.sign(secret=secret)                 # ReliablePacket: 32-byte
                                                  # attachment
copy = bridge.copy(response=b'', packet=data)     # COPY acknowledgement

# direct client-to-client packets (no bids, no attachment)
d = direct.data(payload=payload, sn=sn, index=0, count=1)

# parse a received packet (B-bit filtered per factory)
magpie = bridge.parse(data=data_bytes)
```

## Tests

```bash
cd sdk-py
/usr/bin/python3 -m unittest discover -s tests
```
