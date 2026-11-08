import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'package:magpipe/src/utils/coding.dart';
import 'package:magpipe/src/utils/enigma.dart';

int failed = 0;
void check(bool ok, String name) {
  print('${ok ? "PASS" : "FAIL"}: $name');
  if (!ok) failed++;
}

/// manual HKDF-SHA256 (RFC 5869) for cross-validation
Uint8List manualHkdf(Uint8List ikm, Uint8List salt, Uint8List info) {
  final hmac = HMac(SHA256Digest(), 64)..init(KeyParameter(salt));
  var prk = hmac.process(ikm);
  // the expand phase keys with PRK (RFC 5869)
  hmac.init(KeyParameter(prk));
  var okm = BytesBuilder();
  var t = Uint8List(0);
  var counter = 1;
  while (okm.length < 32) {
    var input = BytesBuilder()..add(t)..add(info)..addByte(counter);
    t = hmac.process(input.toBytes());
    okm.add(t);
    counter++;
  }
  return Uint8List.fromList(okm.toBytes().sublist(0, 32));
}

/// server-style AEAD: returns ciphertext + tag(16)
Uint8List encrypt(Uint8List key, Uint8List nonce, Uint8List aad, Uint8List plaintext) {
  final gcm = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, nonce, aad));
  return gcm.process(plaintext);
}

void main() {
  final ikm = Base64.decode('TW9reSBsb3ZlcyBNYXkgTGVlIGZvcmV2ZXIh');
  final enigma = Enigma({
    'TW9reS': ikm!,
  });
  enigma.updateSecrets({'KEY1': ikm});

  var salt = Uint8List.fromList(List.generate(16, (i) => i));
  var info = Uint8List.fromList(UTF8.encode('enigma-v1:bid=7'));
  var aad = Uint8List.fromList(UTF8.encode('magpie-v1:bid=7'));
  var nonce = Uint8List.fromList(List.generate(12, (i) => 100 + i));
  var plaintext = UTF8.encode('topsecret-token-1234567890');

  // server side: derive key with independent HKDF, then encrypt
  var key = manualHkdf(ikm, salt, info);
  var full = encrypt(key, nonce, aad, plaintext);
  var ciphertext = full.sublist(0, full.length - 16);
  var tag = full.sublist(full.length - 16);

  // the "enigma" bundle the way the server sends it (base64 fields);
  // 'info' is NOT transmitted - both sides derive it from the bid
  Map<String, dynamic> bundleFor(String keyName, Uint8List tagBytes) => {
    'key': keyName,
    'algorithm': 'HKDF-SHA256+AES-256-GCM',
    'salt': Base64.encode(salt),
    'nonce': Base64.encode(nonce),
    'tag': Base64.encode(tagBytes),
  };
  final secretB64 = Base64.encode(ciphertext);

  // 1. happy path: bundle built the server way, HKDF + GCM wired correctly
  var enc = HkdfEnc.parse(bundleFor('KEY1', tag), bid: 7)!;
  var out = enigma.decryptSecret(secretB64, enc);
  check(out != null && UTF8.decode(out) == 'topsecret-token-1234567890', '1: decrypt roundtrip');

  // 2. unknown key name -> null
  check(enigma.decryptSecret(secretB64, HkdfEnc.parse(bundleFor('KEY2', tag), bid: 7)!) == null,
      '2: unknown key name -> null');

  // 3. tampered tag -> null
  var badTag = Uint8List.fromList(tag);
  badTag[0] = badTag[0] ^ 0xFF;
  check(enigma.decryptSecret(secretB64, HkdfEnc.parse(bundleFor('KEY1', badTag), bid: 7)!) == null,
      '3: tampered tag -> null');

  // 4. tampered ciphertext -> null
  var badCt = Uint8List.fromList(ciphertext);
  badCt[0] = badCt[0] ^ 0xFF;
  check(enigma.decryptSecret(Base64.encode(badCt), HkdfEnc.parse(bundleFor('KEY1', tag), bid: 7)!) == null,
      '4: tampered ciphertext -> null');

  // 5. updateSecrets merges: old keys survive, new keys are added
  enigma.updateSecrets({'KEY2': ikm});
  var out3 = enigma.decryptSecret(secretB64, HkdfEnc.parse(bundleFor('KEY1', tag), bid: 7)!);
  check(out3 != null, '5: merge keeps old key');
  var out4 = enigma.decryptSecret(secretB64, HkdfEnc.parse(bundleFor('KEY2', tag), bid: 7)!);
  check(out4 != null, '5: new key works');

  print(failed == 0 ? '\nAll tests passed' : '\n$failed test(s) FAILED');
}
