/// Message layer: the concrete packet classes exchanged on the wire.
///
/// Import this facade to build or carry packet objects: [MessagePacket]
/// is the pure pack implementation, [BasePacket] is the delegation base
/// that [BridgePacket] / [DirectPacket] / [ReliablePacket] extend, and
/// [ReliablePacket] adds the 32-byte HMAC-SHA256 attachment plus [sign].
///
/// All packet classes are read-only and thread-safe to share once built.
library;

export 'src/protocol/magpie.dart';  // Magpie / Packet interfaces

export 'src/packet.dart';    // MessagePacket: pure pack logic
export 'src/reliable.dart';  // BasePacket / ReliablePacket / sign / verify
export 'src/direct.dart';    // DirectPacket (B=0)
export 'src/bridge.dart';    // BridgePacket (B=1)

export 'src/x.dart';     // Hash-Based Message Authentication Code
