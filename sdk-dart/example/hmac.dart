/*
 * Copyright (c) 2026, Albert Moky. All rights reserved.
 * Use of this source code is governed by a MIT-style license
 * that can be found in the LICENSE file.
 */
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:magpie_bridge/magpie.dart';

/// Compute HMAC-SHA256 over the [message] with the [secret] key.
///
/// [secret] is the HMAC key.
/// [message] is the raw binary message.
///
/// Returns the 32-byte HMAC digest.
Uint8List _hmacSha256({
  required Uint8List secret,
  required Uint8List message,
}) {
  final hmac = Hmac(sha256, secret);
  final digest = hmac.convert(message);
  return Uint8List.fromList(digest.bytes);
}


/// Constant-time byte comparison (defends against timing attacks).
///
/// [other] is the bytes to compare against.
///
/// Returns whether every byte matches.
extension _ConstantTimeComparison on Uint8List {

  bool equals(Uint8List other) {
    final size = length;
    if (size != other.length) {
      return false;
    }
    var diff = 0;
    for (var i = 0; i < size; i++) {
      diff |= this[i] ^ other[i];
    }
    return diff == 0;
  }

}


class _Hmac implements MacGenerator {

  @override
  Uint8List generate({
    required Uint8List secret,
    required Uint8List message
  }) => _hmacSha256(secret: secret, message: message);

  @override
  bool verify(Uint8List tag, {
    required Uint8List secret,
    required Uint8List message
  }) => _hmacSha256(secret: secret, message: message).equals(tag);

}

void registerHmacSha256() {
  HmacSha256.generator = _Hmac();
}
