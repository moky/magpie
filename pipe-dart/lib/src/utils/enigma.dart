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
import 'dart:math';
import 'dart:typed_data';

import 'coding.dart';
import 'hkdf.dart';

/// Encryption context of the encrypted handshake (docs/protocol.md 6.1).
///
/// [key] names the shared enigma; [info]/[aad] follow the pre-agreed
/// formulas (both sides derive them from the bid instead of transmitting
/// them); [salt]/[nonce] are fresh randoms; [tag]/[ciphertext] are filled
/// in by the encryption.
class HkdfEnc {
  HkdfEnc(this.key, {
    required this.info,
    required this.salt,
    required this.nonce,
    required this.aad,
    this.tag,
  });

  final String key;
  final Uint8List info;
  final Uint8List salt;
  final Uint8List nonce;
  final Uint8List aad;
  Uint8List? tag;
  Uint8List? ciphertext;

  /// Serialise into the wire bundle ('enigma' field, docs/protocol.md 6.1).
  Map<String, String> toDict() {
    return {
      'key': key,
      'algorithm': 'HKDF-SHA256+AES-256-GCM',
      'salt': Base64.encode(salt),
      'nonce': Base64.encode(nonce),
      'tag': Base64.encode(tag!),
    };
  }

  /// The pre-agreed HKDF info: both sides derive it from the bid
  /// instead of transmitting it with the ciphertext.
  static Uint8List _buildInfo(int bid) => UTF8.encode('enigma-v1:bid=$bid');

  /// The pre-agreed additional authenticated data.
  static Uint8List _buildAad(int bid) => UTF8.encode('magpie-v1:bid=$bid');

  /// Build an encryption context with fresh random salt/nonce
  /// (server side).
  static HkdfEnc create(String key, {required int bid}) {
    final random = Random.secure();
    final salt = Uint8List(16);
    for (var i = 0; i < salt.length; ++i) {
      salt[i] = random.nextInt(256);
    }
    final nonce = Uint8List(12);
    for (var i = 0; i < nonce.length; ++i) {
      nonce[i] = random.nextInt(256);
    }
    return HkdfEnc(key,
      info: _buildInfo(bid),
      aad: _buildAad(bid),
      salt: salt,
      nonce: nonce,
    );
  }

  /// Rebuild the encryption context from the wire bundle (client side).
  ///
  /// Returns null when the bundle is malformed.
  static HkdfEnc? parse(Map<Object?, Object?> bundle, {required int bid}) {
    if (bundle['algorithm'] != 'HKDF-SHA256+AES-256-GCM') {
      assert(false, 'hkdf error: $bundle');
      return null;
    }
    final key = bundle['key'];
    final saltB64 = bundle['salt'];
    final nonceB64 = bundle['nonce'];
    final tagB64 = bundle['tag'];
    if (key is! String || saltB64 is! String || nonceB64 is! String || tagB64 is! String) {
      assert(false, 'hkdf error: $bundle');
      return null;
    }
    final salt = Base64.decode(saltB64);
    final nonce = Base64.decode(nonceB64);
    final tag = Base64.decode(tagB64);
    if (salt == null || nonce == null || tag == null) {
      assert(false, 'hkdf error: $bundle');
      return null;
    }
    return HkdfEnc(key,
      info: _buildInfo(bid),
      aad: _buildAad(bid),
      salt: salt,
      nonce: nonce,
      tag: tag,
    );
  }
}

/// Application secret (enigma) handler: HKDF-SHA256 + AES-256-GCM.
///
/// The key table maps names to their input key material (ikm);
/// `encryptSecret` derives the AES-256 key from the ikm with HKDF-SHA256
/// (salt, and info/aad derived from the bid by the pre-agreed formulas),
/// then encrypts the plaintext with AES-256-GCM (nonce, tag);
/// `decryptSecret` does the reverse.
class Enigma {
  Enigma([Map<String, Uint8List>? secrets]) {
    if (secrets != null) {
      _secrets.addAll(secrets);
    } else {
      final b64 = 'TW9reSBsb3ZlcyBNYXkgTGVlIGZvcmV2ZXIh';
      final ikm = Base64.decode(b64);
      assert(ikm != null, 'failed to decode "$b64"');
      _secrets.addAll({
        'TW9reS': ikm!,
      });
    }
  }

  /// Key table: name -> ikm.
  final Map<String, Uint8List> _secrets = {};

  /// Update the key table: entries in [secrets] are added, replacing
  /// existing entries with the same name; other keys are kept.
  void updateSecrets(Map<String, Uint8List> secrets) {
    _secrets.addAll(secrets);
  }

  /// The key names held in the key table (sent as the 'enigmas' list
  /// in the "SYN?" payload).
  List<String> get keyNames => _secrets.keys.toList();

  /// Encrypt the plaintext secret with the named enigma.
  ///
  /// Fills [enc].ciphertext and [enc].tag, and returns it; returns null
  /// when the key is unknown to this handler.
  HkdfEnc? encryptSecret(Uint8List secret, HkdfEnc enc) {
    final ikm = _secrets[enc.key];
    if (ikm == null) {
      return null;
    }
    final aesKey = HkdfSha256.derive(ikm, salt: enc.salt, info: enc.info);
    final ctAndTag = HkdfSha256.encrypt(secret, key: aesKey, nonce: enc.nonce, aad: enc.aad);
    enc.tag = ctAndTag.sublist(ctAndTag.length - 16);
    enc.ciphertext = ctAndTag.sublist(0, ctAndTag.length - 16);
    return enc;
  }

  /// Decrypt the base64-encoded secret with the named enigma
  /// (docs/client.md 5.2): the [enc].salt field feeds HKDF-SHA256,
  /// whose info/aad follow the pre-agreed formulas.
  ///
  /// Returns the plaintext secret bytes, or null when the key is
  /// unknown or the tag does not verify.
  Uint8List? decryptSecret(String secretB64, HkdfEnc enc) {
    final ikm = _secrets[enc.key];
    if (ikm == null) {
      return null;
    }
    final ciphertext = Base64.decode(secretB64);
    if (ciphertext == null) {
      return null;
    }
    final aesKey = HkdfSha256.derive(ikm, salt: enc.salt, info: enc.info);
    return HkdfSha256.decrypt(ciphertext,
      key: aesKey,
      nonce: enc.nonce,
      tag: enc.tag!,
      aad: enc.aad,
    );
  }

}
