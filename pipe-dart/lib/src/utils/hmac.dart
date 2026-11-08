/* license: https://mit-license.org
 *
 *  Magpie Bridge
 *
 *                               Written in 2026 by Moky <albert.moky@gmail.com>
 *
 * ==============================================================================
 * The MIT License (MIT)
 *
 * Copyright (c) 2026 Albert Moky
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 * ==============================================================================
 */
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

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
  final hmac = HMac(SHA256Digest(), 64);
  hmac.init(KeyParameter(secret));
  return hmac.process(message);
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

/// Register the default HMAC-SHA256 generator (backed by pointycastle):
/// the connection signs every post-handshake packet with it.
void registerHmacSha256() {
  HmacSha256.generator = _Hmac();
}
