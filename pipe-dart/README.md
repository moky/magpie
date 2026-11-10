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
  registered on it (inbound datagrams are routed by remote endpoint). The
  hub runs no timers: call `hub.keepAlive(now)` periodically (e.g. once a
  second on your own timer) to heartbeat idle links and re-connect dead
  ones (docs/client.md §6, §8).
- **BridgeLink / DirectLink**: connection to the relay
  server (B=1, with the SYN?/SYN!/ACK! handshake, heartbeat and enigma)
  or directly to a peer (B=0, stateless).
- **Packet framing**: bridge/direct packet classes and factories
  (SYN?/SYN!/ACK!, FAIL/DONE, ACPT/DENY, PING/PONG, FIN?/FIN!, NOOP,
  DATA/COPY), including signed `ReliablePacket` (HMAC-SHA256).
- **Enigma**: decrypts the handshake secret with HKDF-SHA256 +
  AES-256-GCM (`HkdfEnc` / `HkdfSha256`).
- **Receiving**: the default `processPacket` answers "COPY" to data
  packets and "PONG" to heartbeats; override it on your pipe subclass
  to plug in your own dedup, fragment reassembly and delivery.
- **Observing**: a `MagPipeDelegate` receives every packet forwarded
  through the pipes - set it on the registered `PipeFactory`
  (`pipeDelegate`) without subclassing anything, or override the
  `delegate` getter on your pipe subclass for a per-pipe observer.

See `docs/protocol.md` in the Magpie Bridge repository for the wire
format and `docs/client.md` for the client behaviour.

## Usage

```dart
var hub = await MagHub.create();

// pipes are built by the registered factory (required):
sharedPipeExtensions.pipeFactory = PipeFactory();

// bridge connection to the relay server (B=1):
var bridge = hub.connectBridge(server);
var bridgePipe = hub.getBridgePipe(server, targetBid);

// direct connection to a peer (B=0):
var direct = hub.connect(peer);
var directPipe = hub.getDirectPipe(peer);

// send data through a pipe (sn/index/count for the reliability layer):
directPipe.sendData(payload, sn: 1);

// or send a pre-built packet (routed by its B flag):
hub.sendPacket(packet, remote: server);

// keep-alive pass: call periodically, e.g. once a second
hub.keepAlive(DateTime.now());

...
hub.disconnect(server);
```

## License

MIT — see [LICENSE](LICENSE).
