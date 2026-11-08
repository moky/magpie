# magpipe

[![License](https://img.shields.io/github/license/moky/magpie)](https://github.com/moky/magpie/blob/main/LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/moky/magpie/pulls)
[![Platform](https://img.shields.io/badge/Platform-Dart%203-brightgreen.svg)](https://github.com/moky/magpie/tree/main/docs)
[![Issues](https://img.shields.io/github/issues/moky/magpie)](https://github.com/moky/magpie/issues)
[![Repo Size](https://img.shields.io/github/repo-size/moky/magpie)](https://github.com/moky/magpie/archive/refs/heads/main.zip)
[![Tags](https://img.shields.io/github/tag/moky/magpie)](https://github.com/moky/magpie/tags)
[![Version](https://img.shields.io/pub/v/magpipe)](https://pub.dev/packages/magpipe)

[![Watchers](https://img.shields.io/github/watchers/moky/magpie)](https://github.com/moky/magpie/watchers)
[![Forks](https://img.shields.io/github/forks/moky/magpie)](https://github.com/moky/magpie/forks)
[![Stars](https://img.shields.io/github/stars/moky/magpie)](https://github.com/moky/magpie/stargazers)
[![Followers](https://img.shields.io/github/followers/moky)](https://github.com/orgs/moky/followers)

Magpie Bridge pipe transport for Dart: one shared UDP socket, many
connections.

- **MagHub**: binds the shared socket once and multiplexes every connection
  registered on it (inbound datagrams are routed by remote endpoint), with
  a run loop that heartbeats idle links and re-connects dead ones
  (docs/client.md §6, §8).
- **BridgeLink / DirectLink**: connection to the relay
  server (B=1, with the SYN?/SYN!/ACK! handshake, heartbeat and enigma)
  or directly to a peer (B=0, stateless).
- **Packet framing**: bridge/direct packet classes and factories
  (SYN?/SYN!/ACK!, FAIL/DONE, ACPT/DENY, PING/PONG, FIN?/FIN!, NOOP,
  DATA/COPY), including signed `ReliablePacket` (HMAC-SHA256).
- **Enigma**: decrypts the handshake secret with HKDF-SHA256 +
  AES-256-GCM (`HkdfEnc` / `HkdfSha256`).

See `docs/protocol.md` in the Magpie Bridge repository for the wire
format and `docs/client.md` for the client behaviour.

## Usage

```dart
var hub = await MagHub.create();

// bridge connection to the relay server (B=1):
var bridge = hub.connectBridge(server);
var bridgePipe = hub.getBridgePipe(server, targetBid);

// direct connection to a peer (B=0):
var direct = hub.connect(peer);
var directPipe = hub.getDirectPipe(peer);

...
hub.disconnect(server);
```

## License

MIT — see [LICENSE](LICENSE).
