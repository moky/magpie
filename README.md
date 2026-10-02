# Magpie Bridge

[![License](https://img.shields.io/github/license/moky/magpie)](https://github.com/moky/magpie/blob/main/LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreeng)](https://github.com/moky/magpie/pulls)
[![Issues](https://img.shields.io/github/issues/moky/magpie)](https://github.com/moky/magpie/issues)
[![Repo Size](https://img.shields.io/github/repo-size/moky/magpie)](https://github.com/moky/magpie/archive/refs/heads/main.zip)
[![Tags](https://img.shields.io/github/tag/moky/magpie)](https://github.com/moky/magpie/tags)

[![Watchers](https://img.shields.io/github/watchers/moky/magpie)](https://github.com/moky/magpie/watchers)
[![Forks](https://img.shields.io/github/forks/moky/magpie)](https://github.com/moky/magpie/forks)
[![Stars](https://img.shields.io/github/stars/moky/magpie)](https://github.com/moky/magpie/stargazers)
[![Followers](https://img.shields.io/github/followers/moky)](https://github.com/orgs/moky/followers)

**Reliable UDP Relay Network** — an application-layer messaging protocol on top of UDP,
with bridge (server-relayed) and direct (peer-to-peer) modes, multi-language SDKs, and a
configurable relay server.

## Features

- **Reliable transport over UDP**: reliable packets (D=1) are acknowledged with
  `"COPY"` (sn-based pairing); the sender retransmits on timeout and the receiver
  deduplicates on arrival.
- **Bridge & Direct modes**: packets are relayed by the server (B=1, addressed by
  Bridge ID) or sent directly between clients (B=0, addressed by socket).
- **Bridge ID (bid) management**: 32-bit `bid = (H << 16) | L` with automatic
  allocation, client reservation, and loopback internal assignment — about
  2.15 billion allocatable ids.
- **Anti-amplification**: packets from broadcast/multicast source addresses are
  dropped without response or relay.
- **Session lifecycle**: 3-way handshake (`"SYN?"`/`"SYN!"`/`"ACK!"`), heartbeat
  (`"PING"`/`"PONG"`), 2-step wave-off (`"FIN?"`/`"FIN!"`), and idle-timeout
  recycling of bridge ids.
- **Multi-language SDK**: Java (`sdk-java/`), Python (`sdk-py/`), and Dart
  (`sdk-dart/`, planned).
- **Configurable server**: INI configuration for threads, rate limits, queue
  capacities and the kernel socket buffer — defaults preserved, overridable via
  `--config`.

## Quickstart

### 1. Start the relay server

Java:

```bash
cd server-java
gradle run        # listens on 0.0.0.0:9527 by default
# optional: gradle run --args='--config=/path/to/config.ini --log-dir=/path/to/logs'
```

Python:

```bash
cd sdk-py
python3 -m magpie_bridge.bridge.run    # listens on 0.0.0.0:9527 by default
```

### 2. Run the test clients

Publish the Java SDK to the local Maven repository first (once):

```bash
cd sdk-java
gradle publishToMavenLocal
```

Then run the two example clients in separate terminals:

```bash
cd tests-java
gradle :tests-java:clientA --args="--host 127.0.0.1 --port 9527"    # terminal 1 (passive)
gradle :tests-java:clientB --args="--host 127.0.0.1 --port 9527"    # terminal 2 (active)
```

Each client binds UDP, obtains a bid from the server, and exchanges messages through it.

## Documentation

| Doc                                                           | Audience                                            |
|---------------------------------------------------------------|-----------------------------------------------------|
| [docs/protocol.md](docs/protocol.md)                          | protocol implementors — wire format, fields, validation, error codes |
| [docs/architecture.md](docs/architecture.md)                  | anyone — system architecture and threading model   |
| [docs/workflow.md](docs/workflow.md)                          | anyone — handshake, heartbeat, wave-off, relay flows |
| [docs/sdk.md](docs/sdk.md)                                    | SDK users — interfaces, factories, parsers         |
| [docs/server.md](docs/server.md)                              | server operators — deployment, configuration, tuning |
| [docs/client.md](docs/client.md)                              | example apps — test client walkthrough             |

Design notes (任务说明) live in [`design/`](design/), from which these docs are
generated.

## License

[MIT](LICENSE) © 2026 Albert Moky
