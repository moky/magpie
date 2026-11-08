# magpie_bridge

[![License](https://img.shields.io/github/license/moky/magpie)](https://github.com/moky/magpie/blob/main/LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen)](https://github.com/moky/magpie/pulls)
[![Platform](https://img.shields.io/badge/Platform-Dart%203-brightgreen.svg)](https://github.com/moky/magpie/tree/main/docs)
[![Issues](https://img.shields.io/github/issues/moky/magpie)](https://github.com/moky/magpie/issues)
[![Repo Size](https://img.shields.io/github/repo-size/moky/magpie)](https://github.com/moky/magpie/archive/refs/heads/main.zip)
[![Tags](https://img.shields.io/github/tag/moky/magpie)](https://github.com/moky/magpie/tags)
[![Version](https://img.shields.io/pub/v/magpie_bridge)](https://pub.dev/packages/magpie_bridge)

[![Watchers](https://img.shields.io/github/watchers/moky/magpie)](https://github.com/moky/magpie/watchers)
[![Forks](https://img.shields.io/github/forks/moky/magpie)](https://github.com/moky/magpie/forks)
[![Stars](https://img.shields.io/github/stars/moky/magpie)](https://github.com/moky/magpie/stargazers)
[![Followers](https://img.shields.io/github/followers/moky)](https://github.com/orgs/moky/followers)

Magpie Bridge (MP) — UDP relay messaging protocol SDK for Dart.

A compact datagram protocol for messaging over UDP: a fixed 8-byte header
with optional fields, two transport kinds (client↔server **bridge** and
peer-to-peer **direct**), and an optional HMAC-SHA256 integrity tag.

## Features

- **Small wire format** — fixed 8-byte prefix `magic(4) | type(1) | headerLen(1) | payloadLen(2)` plus optional `target/source/sn/index/count/command` fields, packed in a fixed order (big-endian).
- **Two packet kinds** — `BridgePacket` (B=1, exchanged with a relay server, carries target/source bids) and `DirectPacket` (B=0, peer-to-peer, no bids).
- **Reliability layer** — `ReliablePacket` appends a 32-byte HMAC-SHA256 tag; `sign()` / `verify()` are constant-time and re-signing is a single call.
- **Strict validation** — the factories check magic code, header-length formula, flag combinations, fragment ranges and the attachment tail on every received datagram; invalid ones return `null`.
- **Pluggable MAC** — no third-party runtime dependencies; the MAC implementation is injected through `MacGenerator`.
- **No codegen, no async** — plain Dart, synchronous, read-only packet objects.

## Install

```yaml
dependencies:
  magpie_bridge: ^0.3.0
```

```dart
import 'package:magpie_bridge/magpie_bridge.dart';
```

## Quick start

### Build and parse a bridge packet

```dart
import 'dart:convert';
import 'dart:typed_data';

final bridge = BridgePacketFactory();

// 1st handshake: ask the server for a bridge id (0 = let the server assign)
final syn = bridge.syn(utf8.encode('{"time":123.45}'), source: 12345);
final wire = syn.pack();   // header + payload, no attachment

// Parse a received datagram. Returns null when the datagram is invalid
// (bad magic code, wrong header length, out-of-range flags, ...).
final packet = bridge.parse(wire);
if (packet == null) {
  // drop it
} else {
  print(packet.source);      // 12345
  print(packet.command);     // Command.SYN
}
```

### Build a data packet and its acknowledgement

```dart
// ordinary data: command stays 0 (C=0) to keep the header small
final pkt = bridge.data(
  Uint8List.fromList([1, 2, 3, 4, 5]),
  target: 100,
  source: 200,
  sn: 42,
  index: 0,
  count: 1,
);
final wire = pkt.pack();

// the receiver replies COPY (A=1) echoing sn/index/count
final copy = bridge.copy(Uint8List(0), pkt);   // empty ack body
```

### Direct (peer-to-peer) packets

```dart
final direct = DirectPacketFactory();

final data = direct.data(
  Uint8List.fromList([9, 9, 9]),
  sn: 7,
  index: 0,
  count: 1,
);
final packet = direct.parse(data.pack());
// packet is a DirectPacket (B=0, no bids)
```

### Signing (HMAC-SHA256)

Signing is opt-in. Because the SDK deliberately has **no third-party
runtime dependency**, you must inject a MAC implementation once before
calling `sign()`:

```dart
// 1. Provide an HMAC-SHA256 implementation (any library or your own)
//    implementing the MacGenerator interface, then inject it once.
//    A reference implementation built on package:crypto is provided
//    in example/hmac.dart (see registerHmacSha256()).
HmacSha256.generator = MyHmacSha256();   // your implementation

// 2. Sign a packet: returns a ReliablePacket (header + payload + 32-byte tag)
final ping = bridge.ping(Uint8List.fromList('{}'.codeUnits), source: 9);
final secret = Uint8List.fromList(List.filled(32, 7));
final signed = ping.sign(secret);
final wire = signed.pack();   // wire = header + payload + tag(32)

// 3. Verify on receipt (constant-time comparison)
final received = bridge.parse(wire) as ReliablePacket;
received.verify(secret);   // true
received.verify(other);    // false

// 4. Rotate the secret: re-signing replaces the attachment in one call
final rotated = signed.sign(newSecret);
```

The `MacGenerator` interface you inject is:

```dart
abstract interface class MacGenerator {
  Uint8List generate({required Uint8List secret, required Uint8List message});
  bool verify(Uint8List tag, {required Uint8List secret, required Uint8List message});
}
```

> **Note**: without an injected generator, `sign()` / `verify()` throw a
> `Null check operator used on a null value` error. This is intentional —
> the SDK stays dependency-free and lets the application choose its MAC
> implementation (e.g. `package:crypto` or a platform crypto API).

## Protocol overview

| field | bytes | description |
|---|---|---|
| magic | 4 | `0x4D500001` ("MP\0\1") |
| type | 1 | flags A B C D + E width (bits 7..0) |
| header length | 1 | `8 + 8·B + 4·D + 2·E + 4·C` |
| payload length | 2 | big-endian |
| target / source | 4×2 | only when B=1 |
| sn | 4 | only when D=1 |
| index / count | E×2 | only when E>0 (E = byte width) |
| command | 4 | only when C=1 |
| payload | pLen | |
| attachment | 32 | only for signed (Reliable) packets |

Reserved commands: `SYN?` `SYN!` `ACK!` `FAIL` `DONE` `ACPT` `DENY`
`PING` `PONG` `FIN?` `FIN!` `NOOP` `DATA` `COPY` — plus `0` for plain
DATA (C=0). See `docs/protocol.md` in the repository for the full design.

## Library layout

The package re-exports three facades from the entry point:

| facade | contents |
|---|---|
| `protocol.dart` | constants, header calculations, `Magpie` / `Packet` interfaces, `Command` values |
| `magpie.dart` | `MessagePacket`, `BasePacket`, `BridgePacket`, `DirectPacket`, `ReliablePacket` |
| `factory.dart` | `MessagePacketFactory`, `BridgePacketFactory`, `DirectPacketFactory` |

You can import the whole SDK with one line:

```dart
import 'package:magpie_bridge/magpie_bridge.dart';
```

## Examples and tests

```sh
dart run example/quick_check.dart   # round-trip sanity checks
dart test                          # unit tests
```

## License

[MIT](LICENSE) © 2026 Albert Moky
