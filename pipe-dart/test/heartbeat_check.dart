import 'dart:async';
import 'dart:io';
import 'dart:typed_data';


import 'package:magpipe/src/bridge.dart';
import 'package:magpipe/src/utils/hmac.dart';
import 'package:magpipe/src/utils/coding.dart';
import 'package:magpipe/src/utils/enigma.dart';
import 'package:magpie_bridge/factory.dart';
import 'package:magpie_bridge/magpie.dart';
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

Future<void> main() async {
  registerHmacSha256();

  // fake server + client on loopback
  final server = await RawDatagramSocket.bind('127.0.0.1', 0);
  final client = await RawDatagramSocket.bind('127.0.0.1', 0);
  final conn = BridgeLink(client, (host: server.address, port: server.port), enigma: Enigma());
  Datagram? dg;

  // 0a: connect() -> SYN? built via JSONMap/UTF8 utils
  conn.connect();
  dg = await receive(server, const Duration(seconds: 1));
  var synPacket = dg == null ? null : BridgePacketFactory().parse(dg.data);
  check(synPacket != null && synPacket.command == Command.SYN, '0a: connect -> SYN? sent');
  check(synPacket!.payload.length >= 512, '0a: SYN? payload >= 512');

  // 0b: disconnect() -> FIN? built via JSONMap/UTF8 utils
  conn.bid = 7;  // simulate the bound session before the wave
  conn.disconnect();
  dg = await receive(server, const Duration(milliseconds: 500));
  var finPacket = dg == null ? null : BridgePacketFactory().parse(dg.data);
  check(finPacket != null && finPacket.command == Command.FIN, '0b: disconnect -> FIN? sent');

  // simulate a bound session
  conn.bid = 7;
  conn.secret = Uint8List.fromList(List.generate(32, (i) => i));

  // A: idle for 11s -> PING sent, signed
  conn.ready = true;  // the record survived the wave
  conn.lastSendTime = DateTime.now().subtract(const Duration(seconds: 11));
  conn.lastReceivedTime = null;
  conn.heartbeat();
  dg = await receive(server, const Duration(seconds: 1));
  check(dg != null, 'A: idle -> PING sent');
  final packet = BridgePacketFactory().parse(dg!.data);
  check(packet != null && packet.command == Command.PING, 'A: is PING');
  final reliable = packet is ReliablePacket ? packet : null;
  check(reliable != null && reliable.verify(conn.secret!), 'A: signed with secret');
  check(packet!.source == 7, 'A: source = bid');
  check(UTF8.decode(packet.payload)!.contains('time'), 'A: payload {"time":...}');
  var refreshed = conn.lastSendTime!.difference(DateTime.now()).abs();
  check(refreshed < const Duration(seconds: 1), 'A: lastSendTime refreshed');

  // B: recent send -> no ping
  conn.lastSendTime = DateTime.now();
  conn.heartbeat();
  dg = await receive(server, const Duration(milliseconds: 300));
  check(dg == null, 'B: recent traffic -> no PING');

  // C: fresh connection (no timestamps) -> no ping
  var fresh = BridgeLink(client, (host: server.address, port: server.port), enigma: Enigma());
  fresh.heartbeat();
  dg = await receive(server, const Duration(milliseconds: 300));
  check(dg == null, 'C: no traffic yet -> no PING');

  // D: server replies PONG -> lastReceivedTime refreshed; heartbeat suppressed
  conn.lastSendTime = DateTime.now().subtract(const Duration(seconds: 11));
  var pong = BridgePacketFactory().pong(Uint8List.fromList([1, 2, 3]), packet).sign(conn.secret!);
  server.send(pong.pack(), client.address, client.port);
  var fromServer = await receive(client, const Duration(seconds: 1));
  check(fromServer != null, 'D: PONG delivered');
  conn.received(fromServer!.data);
  check(conn.lastReceivedTime != null, 'D: lastReceivedTime refreshed');
  conn.heartbeat();
  dg = await receive(server, const Duration(milliseconds: 300));
  check(dg == null, 'D: PONG suppresses heartbeat');

  // E: malformed datagram does not refresh
  conn.lastReceivedTime = null;
  conn.received(Uint8List.fromList([1, 2, 3]));
  check(conn.lastReceivedTime == null, 'E: malformed -> no refresh');

  server.close();
  client.close();
  print(failed == 0 ? '\nAll tests passed' : '\n$failed test(s) FAILED');
}
