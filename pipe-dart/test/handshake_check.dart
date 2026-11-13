import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'package:magpipe/src/base.dart';
import 'package:magpipe/src/bridge.dart';
import 'package:magpipe/src/utils/config.dart';
import 'package:magpipe/src/utils/hmac.dart';
import 'package:magpipe/src/utils/coding.dart';
import 'package:magpipe/src/utils/enigma.dart';
import 'package:magpie_bridge/factory.dart';
import 'package:magpie_bridge/protocol.dart';

int failed = 0;
void check(bool ok, String name) {
  print('${ok ? "PASS" : "FAIL"}: $name');
  if (!ok) failed++;
}

/// poll the socket until a datagram arrives or the timeout elapses
Future<Datagram?> receive(RawDatagramSocket s, Duration timeout) async {
  var deadline = DateTime.now().add(timeout);
  do {
    var dg = s.receive();
    if (dg != null) return dg;
    await Future.delayed(const Duration(milliseconds: 20));
  } while (DateTime.now().isBefore(deadline));
  return null;
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
Uint8List aeadEncrypt(Uint8List key, Uint8List nonce, Uint8List aad, Uint8List plaintext) {
  final gcm = GCMBlockCipher(AESEngine())
    ..init(true, AEADParameters(KeyParameter(key), 128, nonce, aad));
  return gcm.process(plaintext);
}

/// no-op delegate: satisfies the link's observer contract
class _NoopDelegate implements MagpieDelegate {
  @override
  void onPacketReceived(Packet packet, MagPipe? pipe, MagLink link) {}
  @override
  void onPacketSent(Magpie packet, MagPipe? pipe, MagLink link) {}
  @override
  void onPacketFailed(Magpie packet, MagPipe? pipe, MagLink link) {}
}

Future<void> main() async {
  var enigma = Enigma();  // default key table ('TW9reS')
  var config = Config();
  var ikm = Base64.decode('TW9reSBsb3ZlcyBNYXkgTGVlIGZvcmV2ZXIh')!;
  registerHmacSha256();

  final server = await RawDatagramSocket.bind('127.0.0.1', 0);
  final client = await RawDatagramSocket.bind('127.0.0.1', 0);
  var factory = BridgeFactory(enigma, config, _NoopDelegate());
  var link = factory.createLink(client, (host: server.address, port: server.port));

  // 1. connect() -> SYN? announcing key names, padded to >= 512
  link.connect();
  var dg = await receive(server, const Duration(seconds: 1));
  check(dg != null, '1: SYN? sent');
  var syn = dg == null ? null : BridgePacketFactory().parse(dg.data);
  check(syn != null && syn.command == Command.SYN, '1: is SYN?');
  check(syn!.payload.length >= 512, '1: payload >= 512');
  var synBody = JSONMap.decode(UTF8.decode(syn.payload)!)!;
  check(synBody['enigmas'] is List && (synBody['enigmas'] as List).isNotEmpty,
      '1: announces enigmas');

  // 2. server replies SYN! (encrypted) -> link binds the session
  var messageKey = UTF8.encode('the-session-secret-32-bytes-ok!');
  var salt = Uint8List.fromList(List.generate(16, (i) => i));
  var info = UTF8.encode('enigma-v1:bid=7');
  var aad = UTF8.encode('magpie-v1:bid=7');
  var nonce = Uint8List.fromList(List.generate(12, (i) => 50 + i));
  var aesKey = manualHkdf(ikm, salt, info);
  var ctAndTag = aeadEncrypt(aesKey, nonce, aad, messageKey);
  var bundle = {
    'key': 'TW9reS',
    'algorithm': 'HKDF-SHA256+AES-256-GCM',
    'salt': Base64.encode(salt),
    'nonce': Base64.encode(nonce),
    'tag': Base64.encode(ctAndTag.sublist(ctAndTag.length - 16)),
  };
  var synAckBody = {
    'secret': Base64.encode(ctAndTag.sublist(0, ctAndTag.length - 16)),
    'token': 'token-xyz',
    'time': 123.456,
    'UDP': '[127.0.0.1]:5000',
    'enigma': bundle,
  };
  var synAck = BridgePacketFactory().synAck(
      UTF8.encode(JSONMap.encode(synAckBody)!), target: 7);
  server.send(synAck.pack(), client.address, client.port);
  var fromServer = await receive(client, const Duration(seconds: 1));
  check(fromServer != null, '2: SYN! delivered');
  link.received(fromServer!.data);
  check(link.bid == 7, '2: bid bound');
  check(link.secret.toString() == messageKey.toString(), '2: session secret saved');
  check(link.ready, '2: link ready');

  // 3. link answers ACK! echoing the handshake parameters
  dg = await receive(server, const Duration(seconds: 1));
  check(dg != null, '3: ACK! sent');
  var ack = dg == null ? null : BridgePacketFactory().parse(dg.data);
  check(ack != null && ack.command == Command.ACK, '3: is ACK!');
  check(ack!.source == 7, '3: source = bid');
  check(ack.payload.length >= 512, '3: ACK! payload >= 512');

  server.close();
  client.close();
  print(failed == 0 ? '\nAll tests passed' : '\n$failed test(s) FAILED');
}
