## 0.3.6

- Breaking: `MagpieExtensions` is removed - pipes and the delegate are
  ctor-injected per link/hub now.
- New callbacks: `onPacketSent` / `onPacketFailed`.
- `BaseLink.processPacket`: template - every packet received through
  the link reaches the delegate (handshake waves included; `pipe` is
  null for packets arriving before their pipe exists).
- The queue-full drop fires `onPacketFailed` for the dropped packet.
- Fix: the "ACK!" resent after a "connection unconfirmed" FAIL is
  pre-signed in the encrypted mode (docs/protocol.md §5.1).

## 0.3.5

- `MagpieDelegate` (was `MagPipeDelegate`): the app observer now sees
  every packet received through the link - handshake waves included;
  `pipe` is null for packets arriving before their pipe exists.
- `MagpieExtensions` (was `PipeExtensions`): holds the pipe factory and
  the delegate - `PipeFactory` no longer does.
- `MagHub`: public constructor - inject a pre-bound socket, an enigma
  and the config; `socket`/`enigma`/link maps are private now.
- `MagHub.close()`: disconnects every registered link (FIN? waves) and
  closes the shared socket; idempotent.
- Breaking: `BridgePipe` constructor parameters renamed remote/local
  to target/source; `maxPendingPackets` is a Config knob now (was a
  static field on BaseLink).

## 0.3.4

- `keepAlive(now)` reworked: re-connects stuck handshakes (rate-limited
  "SYN?" retries - one per `handshake_interval`, up to
  `handshake_retry_limit`) and stale bridge sessions (nothing received
  for `record_active_timeout`), else heartbeats idle links.
- `closed` flag: `disconnect()` marks the link intentionally closed -
  the run loop stops re-dialing; `connect()` clears it on re-open.
- Breaking: `heartbeat(now)` / `reconnect(now)` take the tick
  timestamp - the idle checks moved into the `needsXxx` predicates.

## 0.3.3

- `MagPipeDelegate`: receives every packet forwarded through the
  pipes; plug it via `PipeFactory.pipeDelegate` - read at dispatch
  time, so setting/clearing it affects all pipes at once.
- `PipeFactory`: concrete class with default `createXxx`
  implementations - apps without custom pipes just register an
  instance via `sharedPipeExtensions.pipeFactory`; custom factories
  extend it to build their own pipes.
- Direct handshake: the "SYN!" reply carries the peer's observed
  address in the "UDP" field (`ip:port`, same format as the bridge
  server).
- `DirectLink`: the pipe is created on handshake completion (both
  roles) - `connect()` for the initiator, `_handleAck` for the
  responder.
- Deferred packets: the queue keeps the newest packets when full.
- `MagHub.sendPacket` / `sendData`: assert on pre-ready bridge sends
  in debug builds.
- Example: `ChatPipe` forwards to the base `processPacket` so data
  packets are answered "COPY" (docs/client.md §4.2).

## 0.3.2

- `MagHub`: `getDirectPipe` / `getBridgePipe` / `sendPacket`, plus
  `keepAlive(now)` - heartbeats idle links and re-connects dead ones
  (app-driven schedule, no timers inside the hub).
- Default `processPacket`: answers "COPY" to data packets and "PONG"
  to heartbeats.
- `MagPipeDelegate`: receives every packet forwarded through the
  pipes; plug it via `PipeFactory.pipeDelegate` - read at dispatch
  time, so setting/clearing it affects all pipes at once.
- `PipeFactory`: now a concrete class with default `createXxx`
  implementations - apps without custom pipes just register an
  instance via `sharedPipeExtensions.pipeFactory`; custom factories
  extend it (was `implements`).
- Example: `ChatPipe` forwards to the base `processPacket` so data
  packets are answered "COPY" (docs/client.md §4.2).

## 0.3.1

- `HkdfEnc`: encryption context of the encrypted handshake - info/aad
  follow pre-agreed formulas derived from the bid (never transmitted).
- `HkdfCipher` / `HkdfSha256`: pluggable HKDF-SHA256 + AES-256-GCM.
- `Enigma.encryptSecret` / `decryptSecret` reworked around `HkdfEnc`.

## 0.3.0

- Initial release, split out of the Magpie Bridge Dart SDK
  (`sdk-dart`) as an independent package.
- Wire format: packet interfaces, MessagePacket, bridge/direct packets,
  reliable (signed) packets and packet factories.
