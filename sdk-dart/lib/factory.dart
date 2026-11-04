/// Factory layer: datagram validation and per-kind instruction factories.
///
/// Import this facade to decode received datagrams or to build instruction
/// packets (SYN?/SYN!/ACK!, FAIL/DONE, ACPT/DENY, PING/PONG, FIN?/FIN!,
/// NOOP, DATA/COPY). [MessagePacketFactory] performs the shared wire
/// validation; [BridgePacketFactory] and [DirectPacketFactory] extend it
/// with the B-bit filter and their instruction builders.
library;

export 'src/packet_factory.dart';   // shared datagram validator
export 'src/direct_factory.dart';   // DirectPacketFactory (B=0)
export 'src/bridge_factory.dart';   // BridgePacketFactory (B=1)
