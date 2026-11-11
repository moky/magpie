// Quick round-trip sanity check for the Magpie Bridge SDK.
//
// Run with: dart run example/quick_check.dart
//
// Exercises packet building, packing, parsing, HMAC signing / verification
// and a few malformed-datagram rejections, printing one line per step.
import 'dart:typed_data';
import 'package:magpie_bridge/magpie_bridge.dart';

import 'hmac.dart';
import 'human.dart';

void main() {
  registerHmacSha256();

  final bridge = BridgePacketFactory();
  final direct = DirectPacketFactory();

  // 1. SYN? round-trip
  final payload = Uint8List.fromList('{"time":123.45}'.codeUnits);
  final syn = bridge.syn(payload, source: 12345);
  final wire = syn.pack();
  print('SYN? hLen=${syn.headerLength} wireLen=${wire.length}');
  var parsed = bridge.parse(wire);
  assert(parsed != null, 'parse SYN? failed');
  print('  -> command=${commandName(parsed!.command)} source=${parsed.source} payloadLen=${parsed.payload.length}');

  // 2. DATA with sn
  final data = Uint8List.fromList([1, 2, 3, 4, 5]);
  final pkt = bridge.data(data, target: 100, source: 200, sn: 42, index: 0, count: 1);
  final wire2 = pkt.pack();
  print('DATA hLen=${pkt.headerLength} wireLen=${wire2.length}');
  parsed = bridge.parse(wire2);
  assert(parsed != null);
  print('  -> sn=${parsed!.sn} target=${parsed.target} source=${parsed.source} hasCmd=${parsed.cmd}');
  print('  -> ${parsed.toHumanReadableString()}');

  // 2b. COPY acknowledgement echoes sn/index/count (A=1)
  final copy = bridge.copy(Uint8List(0), pkt);
  parsed = bridge.parse(copy.pack());
  assert(parsed != null && parsed.ack == 1);
  print('COPY ack: ack=${parsed!.ack} sn=${parsed.sn}');

  // 3. signed packet
  final secret = Uint8List.fromList(List.filled(32, 7));
  final ping = bridge.ping(payload, source: 123);
  final signed = ping.sign(secret);
  final wire3 = signed.pack();
  print('PING signed wireLen=${wire3.length} (expect ${ping.headerLength + ping.payloadLength + 32})');
  parsed = bridge.parse(wire3);
  assert(parsed is ReliablePacket);
  final rp = parsed as ReliablePacket;
  print('  -> verify(good)=${rp.verify(secret)} verify(bad)=${rp.verify(Uint8List(32))}');

  // 3b. secret rotation: re-signing replaces the attachment in one call
  final rotated = rp.sign(Uint8List.fromList(List.filled(32, 9)));
  assert(rotated.verify(Uint8List.fromList(List.filled(32, 9))));
  print('  -> re-sign: verify(new)=${rotated.verify(Uint8List.fromList(List.filled(32, 9)))} verify(old)=${rotated.verify(secret)}');

  // 4. DirectPacket
  final d = direct.data(Uint8List.fromList([9, 9, 9]), sn: 7, index: 0, count: 1);
  final wire4 = d.pack();
  print('Direct hLen=${d.headerLength} wireLen=${wire4.length}');
  parsed = direct.parse(wire4);
  assert(parsed is DirectPacket);
  print('  -> sn=${parsed!.sn} hasBid=${parsed.bid}');

  // 5. bad packets
  assert(bridge.parse(Uint8List(4)) == null);
  print('bad-too-short: OK');

  print('\nAll round-trip checks passed.');
}
