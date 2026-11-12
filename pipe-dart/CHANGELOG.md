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
