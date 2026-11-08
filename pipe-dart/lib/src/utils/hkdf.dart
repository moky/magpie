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

/// Interface for HKDF-SHA256 key derivation + AES-256-GCM encryption:
/// the AES key is derived from the ikm with (salt, info), then the
/// plaintext is encrypted/decrypted with AES-256-GCM (nonce, aad).
abstract interface class HkdfCipher {
  /// Derive the 32-byte AES key: HKDF-SHA256(ikm, salt, info).
  Uint8List derive(Uint8List ikm, {
    required Uint8List salt,
    required Uint8List info,
  });

  /// Encrypt [plaintext] with the [key]: AES-256-GCM.
  /// [aad] is the additional authenticated data (may be empty).
  /// Returns ciphertext + tag(16).
  Uint8List encrypt(Uint8List plaintext, {
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  });

  /// Decrypt [ciphertext] + [tag] with the [key].
  /// [aad] is the additional authenticated data (may be empty).
  /// Returns the plaintext, or null when the tag does not verify.
  Uint8List? decrypt(Uint8List ciphertext, {
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List tag,
    required Uint8List aad,
  });
}

/// HKDF-SHA256 + AES-256-GCM utility (facade for [HkdfCipher]).
///
/// The three static methods mirror the [HkdfCipher] interface one-to-one:
/// derive the 32-byte AES key from the ikm, then encrypt/decrypt with
/// AES-256-GCM (nonce, aad).
class HkdfSha256 {
  HkdfSha256._();

  /// The pluggable cipher (pointycastle-backed by default).
  static HkdfCipher cipher = _PointycastleHkdf();

  /// Derive the 32-byte AES key: HKDF-SHA256(ikm, salt, info).
  static Uint8List derive(Uint8List ikm, {
    required Uint8List salt,
    required Uint8List info,
  }) => cipher.derive(ikm, salt: salt, info: info);

  /// Encrypt [plaintext] with the [key]: AES-256-GCM.
  /// [aad] is the additional authenticated data (may be empty).
  /// Returns ciphertext + tag(16).
  static Uint8List encrypt(Uint8List plaintext, {
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) => cipher.encrypt(plaintext, key: key, nonce: nonce, aad: aad);

  /// Decrypt [ciphertext] + [tag] with the [key].
  /// [aad] is the additional authenticated data (may be empty).
  /// Returns the plaintext, or null when the tag does not verify.
  static Uint8List? decrypt(Uint8List ciphertext, {
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List tag,
    required Uint8List aad,
  }) => cipher.decrypt(ciphertext, key: key, nonce: nonce, tag: tag, aad: aad);
}

/// pointycastle-backed default implementation
class _PointycastleHkdf implements HkdfCipher {
  const _PointycastleHkdf();

  /// the protocol fixes the GCM tag at 128 bit (16 bytes)
  // ignore: constant_identifier_names
  static const TAG_BITS = 128;

  @override
  Uint8List derive(Uint8List ikm, {
    required Uint8List salt,
    required Uint8List info,
  }) {
    final hkdf = HKDFKeyDerivator(SHA256Digest());
    hkdf.init(HkdfParameters(ikm, 32, salt, info));
    final aesKey = Uint8List(32);
    hkdf.deriveKey(null, 0, aesKey, 0);
    return aesKey;
  }

  @override
  Uint8List encrypt(Uint8List plaintext, {
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List aad,
  }) {
    final gcm = GCMBlockCipher(AESEngine());
    gcm.init(true, AEADParameters(KeyParameter(key), TAG_BITS, nonce, aad));
    return gcm.process(plaintext);
  }

  @override
  Uint8List? decrypt(Uint8List ciphertext, {
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List tag,
    required Uint8List aad,
  }) {
    final gcm = GCMBlockCipher(AESEngine());
    final input = Uint8List(ciphertext.length + tag.length);
    input.setRange(0, ciphertext.length, ciphertext);
    input.setRange(ciphertext.length, input.length, tag);
    try {
      // the tag length itself determines the macSize: self-adapting
      gcm.init(false, AEADParameters(KeyParameter(key), tag.length * 8, nonce, aad));
      return gcm.process(input);
    } on InvalidCipherTextException {
      return null;  // tag mismatch: tampered or wrong key
    }
  }
}
