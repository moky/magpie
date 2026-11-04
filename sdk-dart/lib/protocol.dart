/// Protocol layer: wire-format constants, header calculations and the
/// [Magpie] / [Packet] interfaces.
///
/// Import this facade when you only need the wire format primitives
/// (constants, calculators, command values, interfaces), without the
/// concrete packet classes. See `docs/protocol.md` for the wire format.
library;

export 'src/protocol/protocol.dart';  // constants & header calculations
export 'src/protocol/command.dart';   // reserved command values
export 'src/protocol/magpie.dart';    // Magpie / Packet interfaces
