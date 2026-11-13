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
  ones (docs/client.md §6, §8). `hub.close()` disconnects everything and
  closes the shared socket.
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
- **Observing**: a `MagpieDelegate` receives every packet received
  through the link - handshake waves included; pass it to
  `MagHub.create` / the `MagHub` constructor (`delegate`) without
  subclassing anything.

See `docs/protocol.md` in the Magpie Bridge repository for the wire
format and `docs/client.md` for the client behaviour.

## Usage

```dart
var enigma = Enigma();  // feeds the encrypted handshake
var config = Config();  // timing knobs (heartbeat/handshake intervals, ...)
var delegate = MyDelegate();  // observes every packet (a no-op works too)

var hub = await MagHub.create(enigma: enigma, config: config, delegate: delegate);

// bridge connection to the relay server (B=1):
var bridge = hub.connectBridge(server);
// the handshake runs in the background: getBridgePipe returns null
// until it completes (bridge.ready)
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

// done: disconnects every link and closes the shared socket
hub.close();
```

## License

MIT — see [LICENSE](LICENSE).
