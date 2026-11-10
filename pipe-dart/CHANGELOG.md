## 0.3.1

- `HkdfEnc`: encryption context of the encrypted handshake - info/aad
  follow pre-agreed formulas derived from the bid (never transmitted).
- `HkdfCipher` / `HkdfSha256`: pluggable HKDF-SHA256 + AES-256-GCM.
- `Enigma.encryptSecret` / `decryptSecret` reworked around `HkdfEnc`.
- `MagHub`: `getDirectPipe` / `getBridgePipe` / `sendPacket`, plus a
  run loop that heartbeats idle links and re-connects dead ones
  (no packet received for `record_active_timeout`).
- Default `processPacket`: answers "COPY" to data packets and "PONG"
  to heartbeats.

## 0.3.0

- Initial release, split out of the Magpie Bridge Dart SDK
  (`sdk-dart`) as an independent package.
- Wire format: packet interfaces, MessagePacket, bridge/direct packets,
  reliable (signed) packets and packet factories.
