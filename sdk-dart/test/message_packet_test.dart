// Unit tests for the Magpie Bridge SDK packet classes.
//
// Run with: dart test
//
// Covers bridge/direct packet round-trips, signed (ReliablePacket) wire
// layout and verify(), plus malformed-datagram rejections.
import 'dart:typed_data';

import 'package:magpie_bridge/magpie_bridge.dart';
import 'package:test/test.dart';

import '../example/hmac.dart';

void main() {
  registerHmacSha256();

  final bridge = BridgePacketFactory();
  final direct = DirectPacketFactory();

  group('BridgePacket round-trip', () {
    test('SYN? packet', () {
      final payload = Uint8List.fromList('{"time":123.45}'.codeUnits);
      final syn = bridge.syn(payload, source: 12345);
      final wire = syn.pack();

      // header = 8 + 8*1 + 0*4 + 0*2 + 1*4 = 20
      expect(syn.headerLength, 20);
      expect(wire.length, 20 + payload.length);

      final parsed = bridge.parse(wire);
      expect(parsed, isA<BridgePacket>());
      expect(parsed!.command, Command.SYN);
      expect(parsed.source, 12345);
      expect(parsed.target, 0);
      expect(parsed.ack, 0);
      expect(parsed.payload, equals(payload));
    });

    test('DATA packet with sn', () {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      final pkt = bridge.data(data, target: 100, source: 200, sn: 42, index: 0, count: 1);
      final wire = pkt.pack();

      // 8 + 8 (bid) + 4 (dsn) = 20, C=0 so no command
      expect(pkt.headerLength, 20);

      final parsed = bridge.parse(wire);
      expect(parsed, isA<BridgePacket>());
      expect(parsed!.sn, 42);
      expect(parsed.target, 100);
      expect(parsed.source, 200);
      expect(parsed.cmd, 0);
      expect(parsed.payload, equals(data));
    });

    test('signed packet verifies', () {
      final secret = Uint8List.fromList(List.filled(32, 7));
      final payload = Uint8List.fromList('{"time":1.0}'.codeUnits);
      final ping = bridge.ping(payload, source: 123);
      final signed = ping.sign(secret);
      final wire = signed.pack();

      // header + payload + 32-byte attachment
      expect(wire.length, ping.headerLength + ping.payloadLength + 32);

      final parsed = bridge.parse(wire);
      expect(parsed, isA<ReliablePacket>());
      expect((parsed as ReliablePacket).verify(secret), isTrue);
      expect(parsed.verify(Uint8List(32)), isFalse);
    });

    test('signed packet re-packs to the same wire bytes', () {
      final secret = Uint8List.fromList(List.filled(32, 7));
      final ping = bridge.ping(Uint8List.fromList('{}'.codeUnits), source: 9);
      final wire = ping.sign(secret).pack();

      final parsed = bridge.parse(wire) as ReliablePacket;
      // Re-packing a parsed signed packet must yield the identical datagram.
      expect(parsed.pack(), equals(wire));
    });

    test('bridge factory rejects direct packets', () {
      final wire = direct.data(Uint8List.fromList([9, 9]), sn: 1, index: 0, count: 1).pack();
      expect(bridge.parse(wire), isNull);
    });
  });

  group('DirectPacket round-trip', () {
    test('direct DATA', () {
      final data = Uint8List.fromList([9, 9, 9]);
      final pkt = direct.data(data, sn: 7, index: 0, count: 1);
      final wire = pkt.pack();
      // 8 + 0 + 4 (dsn) = 12
      expect(pkt.headerLength, 12);

      final parsed = direct.parse(wire);
      expect(parsed, isA<DirectPacket>());
      expect(parsed!.sn, 7);
      expect(parsed.bid, 0);
    });

    test('direct factory rejects bridge packets', () {
      final wire = bridge.ack(Uint8List.fromList('{}'.codeUnits), source: 1).pack();
      expect(direct.parse(wire), isNull);
    });
  });

  group('bad packets', () {
    test('too short', () {
      expect(bridge.parse(Uint8List(4)), isNull);
      expect(direct.parse(Uint8List(4)), isNull);
    });
    test('bad magic', () {
      final bad = Uint8List.fromList([0x00, 0x11, 0x22, 0x33, 0, 8, 0, 0]);
      expect(bridge.parse(bad), isNull);
    });
    test('truncated packet with a long declared header returns null', () {
      // magic + type=0x60 (B=1,C=1) + header_length=20 (matches the formula)
      // + pLen=0, but only 8 bytes on the wire. Must be dropped, not throw.
      final bad = Uint8List.fromList([0x4D, 0x50, 0x00, 0x01, 0x60, 20, 0, 0]);
      expect(bridge.parse(bad), isNull);
      expect(direct.parse(bad), isNull);
    });
    test('truncated packet with D=1 returns null', () {
      // type=0x10 (D=1), header_length=12 (8 + 4), but no sn bytes follow.
      final bad = Uint8List.fromList([0x4D, 0x50, 0x00, 0x01, 0x10, 12, 0, 0]);
      expect(bridge.parse(bad), isNull);
    });
  });
}
