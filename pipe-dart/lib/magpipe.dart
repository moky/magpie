/// Magpie Bridge pipe transport.
///
/// Import this facade for the full surface: wire format primitives,
/// packet classes, packet factories and the pipe layer (links,
/// hub and enigma). See `docs/protocol.md` for the wire format.
library magpipe;

export 'package:magpie_bridge/protocol.dart';  // wire format primitives
export 'package:magpie_bridge/magpie.dart';    // packet classes
export 'package:magpie_bridge/factory.dart';   // packet factories

export 'src/utils/coding.dart';                // JSONMap / UTF8 / Base64
export 'src/utils/config.dart';                // Config
export 'src/utils/enigma.dart';                // Enigma / HkdfEnc
export 'src/utils/hkdf.dart';                  // HkdfCipher / HkdfSha256
export 'src/utils/hmac.dart';                  // registerHmacSha256
export 'src/utils/payload.dart';               // PayloadMixIn

export 'src/ext.dart';                         // PipeFactory / MagpieDelegate
export 'src/link.dart';                        // MagLink / BaseLink
export 'src/hub.dart';                         // MagHub
export 'src/pipe.dart';                        // MagPipe
export 'src/bridge.dart';                      // BridgeLink
export 'src/direct.dart';                      // DirectLink
