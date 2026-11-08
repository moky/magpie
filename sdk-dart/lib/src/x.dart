/* license: https://mit-license.org
 *
 *  Magpie Bridge Messaging Protocol
 *
 *                               Written in 2026 by Moky <albert.moky@gmail.com>
 *
 * =============================================================================
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
 * =============================================================================
 */
import 'dart:typed_data';

/// Interface for computing MAC (Message Authentication Code) values,
/// e.g. HMAC with various underlying hash algorithms.
///
/// Supported MAC algorithms include (but are not limited to):
/// - HMAC-SHA-256
/// - HMAC-SHA-512
/// - HMAC-SHA-1
///
/// A MAC is a fixed-size byte tag derived from a secret key and input data,
/// providing both data integrity and origin authentication.
abstract interface class MacGenerator {
  /// Generate MAC tag over the [message] with the [secret] key.
  ///
  /// [secret] is the secret cryptographic key.
  /// [message] is the input binary payload.
  ///
  /// Returns fixed-size MAC tag as [Uint8List].
  Uint8List generate({required Uint8List secret, required Uint8List message});

  /// Constant-time verify MAC tag.
  ///
  /// Re-computes MAC from [secret] and [message], then compares against [tag]
  /// using side-channel safe comparison.
  ///
  /// Returns true only if the tag matches.
  bool verify(Uint8List tag, {required Uint8List secret, required Uint8List message});
}

/// HMAC-SHA-256 utility (facade for [MacGenerator]).
///
/// Computes and verifies HMAC-SHA-256 authentication tag (32-byte / 256-bit).
class HmacSha256 {
  HmacSha256._();

  /// Generate HMAC-SHA-256 MAC tag.
  ///
  /// [secret] is the secret key.
  /// [message] is the input binary payload.
  ///
  /// Returns the 32-byte MAC tag as [Uint8List].
  static Uint8List generate({
    required Uint8List secret,
    required Uint8List message
  }) => generator!.generate(secret: secret, message: message);

  /// Constant-time verify HMAC-SHA-256 tag.
  ///
  /// Re-computes MAC from [secret] and [message], then compares against [tag]
  /// using side-channel safe comparison.
  ///
  /// Returns true only if the tag matches.
  static bool verify(Uint8List tag, {
    required Uint8List secret,
    required Uint8List message
  }) => generator!.verify(tag, secret: secret, message: message);

  /// The [MacGenerator] implementation (null before set).
  static MacGenerator? generator;
}
