import 'dart:async';
import 'dart:io';
import 'dart:typed_data';


import 'package:magpipe/src/base.dart';
import 'package:magpipe/src/bridge.dart';
import 'package:magpipe/src/utils/config.dart';
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
  registerHmacSha256();

  // fake server + client on loopback
  final server = await RawDatagramSocket.bind('127.0.0.1', 0);
  final client = await RawDatagramSocket.bind('127.0.0.1', 0);
  var factory = BridgeFactory(Enigma(), Config(), _NoopDelegate());
  final conn = factory.createLink(client, (host: server.address, port: server.port));
  Datagram? dg;

  // 0a: connect() -> SYN? sent
  conn.connect();
  dg = await receive(server, const Duration(seconds: 1));
  check(dg != null, '0a: connect -> SYN? sent');
  var synPacket = dg == null ? null : BridgePacketFactory().parse(dg.data);
  check(synPacket != null && synPacket.command == Command.SYN, '0a: is SYN');

  // 0b: the server replies "SYN!" with a plain secret -> the handshake
  // completes (bid bound, secret saved, ready)
  var secret = Uint8List.fromList(List.generate(32, (i) => i));
  var synAck = BridgePacketFactory().synAck(
    UTF8.encode('{"secret":"${Base64.encode(secret)}","token":"t","time":1}'),
    target: 7,
  );
  server.send(synAck.pack(), client.address, client.port);
  var fromServer = await receive(client, const Duration(seconds: 1));
  check(fromServer != null, '0b: SYN! delivered');
  conn.received(fromServer!.data);
  check(conn.ready && conn.bid == 7, '0b: handshake completed');
  dg = await receive(server, const Duration(seconds: 1));
  check(dg != null, '0b: ACK! sent');

  // A: idle for 11s -> PING sent, signed
  final now = DateTime.now();
  conn.lastSendTime = now.subtract(const Duration(seconds: 11));
  conn.lastReceivedTime = null;
  if (conn.needsHeartbeat(now)) conn.heartbeat(now);
  dg = await receive(server, const Duration(seconds: 1));
  check(dg != null, 'A: idle -> PING sent');
  final packet = BridgePacketFactory().parse(dg!.data);
  check(packet != null && packet.command == Command.PING, 'A: is PING');
  final reliable = packet is ReliablePacket ? packet : null;
  check(reliable != null && reliable.verify(secret), 'A: signed with secret');
  check(packet!.source == 7, 'A: source = bid');
  check(UTF8.decode(packet.payload)!.contains('time'), 'A: payload {"time":...}');
  var refreshed = conn.lastSendTime!.difference(DateTime.now()).abs();
  check(refreshed < const Duration(seconds: 1), 'A: lastSendTime refreshed');

  // B: recent send -> no ping
  conn.lastSendTime = DateTime.now();
  if (conn.needsHeartbeat()) conn.heartbeat();
  dg = await receive(server, const Duration(milliseconds: 300));
  check(dg == null, 'B: recent traffic -> no PING');

  // C: fresh connection (no timestamps) -> no ping
  var fresh = factory.createLink(client, (host: server.address, port: server.port));
  if (fresh.needsHeartbeat()) fresh.heartbeat();
  dg = await receive(server, const Duration(milliseconds: 300));
  check(dg == null, 'C: no traffic yet -> no PING');

  // D: server replies PONG -> lastReceivedTime refreshed; heartbeat suppressed
  conn.lastSendTime = DateTime.now().subtract(const Duration(seconds: 11));
  var pong = BridgePacketFactory().pong(Uint8List.fromList([1, 2, 3]), packet).sign(secret);
  server.send(pong.pack(), client.address, client.port);
  var pongDg = await receive(client, const Duration(seconds: 1));
  check(pongDg != null, 'D: PONG delivered');
  conn.received(pongDg!.data);
  check(conn.lastReceivedTime != null, 'D: lastReceivedTime refreshed');
  if (conn.needsHeartbeat()) conn.heartbeat();
  dg = await receive(server, const Duration(milliseconds: 300));
  check(dg == null, 'D: PONG suppresses heartbeat');

  // E: malformed datagram does not refresh
  conn.lastReceivedTime = null;
  conn.received(Uint8List.fromList([1, 2, 3]));
  check(conn.lastReceivedTime == null, 'E: malformed -> no refresh');

  // F: disconnect() -> FIN? with the bound bid
  conn.disconnect();
  dg = await receive(server, const Duration(milliseconds: 500));
  var finPacket = dg == null ? null : BridgePacketFactory().parse(dg.data);
  check(finPacket != null && finPacket.command == Command.FIN, 'F: disconnect -> FIN? sent');
  check(finPacket!.source == 7, 'F: FIN? source = bid');

  server.close();
  client.close();
  print(failed == 0 ? '\nAll tests passed' : '\n$failed test(s) FAILED');
}
