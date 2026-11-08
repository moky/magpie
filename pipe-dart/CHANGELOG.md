## 0.3.0

- Initial release, split out of the Magpie Bridge Dart SDK
  (`sdk-dart`) as an independent package.
- Wire format: packet interfaces, MessagePacket, bridge/direct packets,
  reliable (signed) packets and packet factories.
- Pipe layer: MagLink / BaseLink (BridgeLink, DirectLink), MagHub
  (shared UDP socket multiplexer with a run loop: idle heartbeats and
  dead-link re-handshakes), and Enigma (HKDF-SHA256 + AES-256-GCM
  secret box: HkdfEnc / HkdfSha256).
