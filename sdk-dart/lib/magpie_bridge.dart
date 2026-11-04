/// Magpie Bridge (MP) — UDP relay messaging protocol SDK for Dart.
///
/// The SDK is organised into three facades, re-exported here:
///   * `protocol` — wire-format constants, header calculations, the
///     [Magpie] / [Packet] interfaces and the reserved [Command] values;
///   * `magpie`   — the concrete packet classes ([MessagePacket],
///     [BridgePacket], [DirectPacket], [ReliablePacket]) plus the
///     [BasePacket] delegation base they share;
///   * `factory`  — datagram validation ([MessagePacketFactory]) and the
///     per-kind instruction factories ([BridgePacketFactory],
///     [DirectPacketFactory]).
///
/// See `docs/protocol.md` for the wire format.
library magpie_bridge;

export 'protocol.dart';
export 'magpie.dart';
export 'factory.dart';
