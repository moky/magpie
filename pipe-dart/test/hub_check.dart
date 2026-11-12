import 'dart:io';
import 'dart:typed_data';


import 'package:magpipe/src/hub.dart';
import 'package:magpipe/src/pipe.dart';
import 'package:magpipe/src/bridge.dart';
import 'package:magpipe/src/direct.dart';
import 'package:magpipe/src/utils/hmac.dart';
import 'package:magpipe/src/utils/coding.dart';
import 'package:magpie_bridge/factory.dart';
import 'package:magpie_bridge/magpie.dart';

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

/// concrete pipe for the test (MagPipe.process is abstract)
class TestPipe extends DirectPipe {
  TestPipe(super.connection);

  @override
  void processPacket(Packet packet) {
    // forward to the base: answer COPY/PONG and observe via the
    // registered pipe delegate
    super.processPacket(packet);
  }
}

/// records packets observed through the pipe delegate
class PipeRecorder implements MagPipeDelegate {
  int calls = 0;
  @override
  void onPacketReceived(Packet packet, MagPipe pipe) => calls++;
}

/// concrete bridge pipe for the test
class TestBridgePipe extends BridgePipe {
  TestBridgePipe(super.connection, {required super.remote, required super.local});

  @override
  void processPacket(Packet packet) {}
}

/// test-only factory: creates the concrete pipes for the hub check
class TestPipeFactory extends PipeFactory {
  @override
  DirectPipe createDirectPipe(DirectLink conn) => TestPipe(conn);

  @override
  BridgePipe createBridgePipe(BridgeLink conn, {
    required int remote,
    required int local,
  }) => TestBridgePipe(conn, remote: remote, local: local);
}

Future<void> main() async {
  registerHmacSha256();
  var factory = TestPipeFactory();
  sharedPipeExtensions.pipeFactory = factory;

  // fake remote peers
  final server = await RawDatagramSocket.bind('127.0.0.1', 0);
  final peer = await RawDatagramSocket.bind('127.0.0.1', 0);

  // 1. hub creates and binds its own shared socket
  var hub = await MagHub.create(host: InternetAddress.loopbackIPv4, port: 0);
  check(hub.socket.address.address == '127.0.0.1', '1: hub bound to loopback');
  check(hub.socket.port != 0, '1: ephemeral port');
  check(hub.directLinks.isEmpty && hub.bridgeLinks.isEmpty, '1: starts empty');

  // 2. connectBridge() -> BridgeLink, handshake via shared socket
  var bridge = hub.connectBridge((host: server.address, port: server.port));
  check(hub.bridgeLinks.length == 1, '2: registered in list');
  var dg = await receive(server, const Duration(seconds: 1));
  check(dg != null, '2: SYN? sent via shared socket');

  // 3. duplicate connect returns the same instance
  var again = hub.connectBridge((host: server.address, port: server.port));
  check(identical(again, bridge), '3: idempotent connect');
  check(hub.bridgeLinks.length == 1, '3: no duplicate');

  // 4. dispatch: server sends PONG -> routed to the right connection
  bridge.bid = 7;
  bridge.secret = Uint8List.fromList(List.generate(32, (i) => i));
  var ping = BridgePacketFactory().ping(Uint8List.fromList([0]), source: 7);
  var pong = BridgePacketFactory().pong(Uint8List.fromList([1]), ping).sign(bridge.secret!);
  server.send(pong.pack(), hub.socket.address, hub.socket.port);
  await Future.delayed(const Duration(milliseconds: 200));
  check(bridge.lastReceivedTime != null, '4: datagram routed to bridge connection');

  // 5. connect() -> DirectLink
  var direct = hub.connect((host: peer.address, port: peer.port));
  check(hub.directLinks.length == 1 && hub.bridgeLinks.length == 1, '5: registered in list');
  // the "SYN?" of the direct handshake is expected traffic: drain it
  await receive(peer, const Duration(milliseconds: 500));

  // 5a. sendData on a pre-ready bridge link: the bridge pipe cannot
  // exist yet (no bid), so the call trips the assert in debug builds
  var asserted = false;
  try {
    hub.sendData(Uint8List.fromList([1]), remote: (host: InternetAddress.loopbackIPv4, port: 1), target: 1, sn: 1);
  } on AssertionError {
    asserted = true;
  }
  check(asserted, '5a: pre-ready bridge send trips the assert');

  // 5b. sendData on a pre-ready direct link: queued while re-handshaking
  check(!hub.sendData(Uint8List.fromList([1]), remote: (host: peer.address, port: peer.port), target: 0, sn: 1),
      '5b: not ready -> false');

  // 5c. the fake peer completes the handshake: sends its own "SYN?" —
  // the hub replies "SYN!" and, on the peer's "ACK!", turns ready and
  // flushes the deferred packet
  peer.send(DirectPacketFactory().syn(Uint8List.fromList([1, 2, 3])).pack(), hub.socket.address, hub.socket.port);
  dg = await receive(peer, const Duration(seconds: 1));
  check(dg != null, '5c: SYN! replied');
  peer.send(DirectPacketFactory().ack(Uint8List.fromList([4, 5, 6])).pack(), hub.socket.address, hub.socket.port);
  await Future.delayed(const Duration(milliseconds: 200));
  check(direct.ready, '5c: handshake completed');

  // 5d. the deferred packet flushed at ready; post-ready send delivers
  var ddg = await receive(peer, const Duration(seconds: 1));
  var dataPacket = ddg == null ? null : DirectPacketFactory().parse(ddg.data);
  check(dataPacket != null && dataPacket.sn == 1, '5d: deferred packet flushed');
  check(hub.sendData(UTF8.encode("abc"), remote: (host: peer.address, port: peer.port), target: 0, sn: 42),
      '5d: sendData ok');
  ddg = await receive(peer, const Duration(seconds: 1));
  dataPacket = ddg == null ? null : DirectPacketFactory().parse(ddg.data);
  check(dataPacket != null && dataPacket.sn == 42, '5d: DATA received with sn=42');
  check(UTF8.decode(dataPacket!.payload) == 'abc', '5d: payload intact');

  // 6. disconnect() removes and sends FIN? (bridge)
  var removed = hub.disconnect((host: server.address, port: server.port));
  check(identical(removed, bridge), '6: removed the right one');
  check(hub.directLinks.length == 1, '6: removed from list');
  dg = await receive(server, const Duration(milliseconds: 500));
  check(dg != null, '6: FIN? sent');

  // 7. disconnect unknown endpoint -> null
  check(hub.disconnect((host: server.address, port: server.port)) == null, '7: unknown -> null');

  // 8. datagram from unknown endpoint -> dropped silently
  var stranger = await RawDatagramSocket.bind('127.0.0.1', 0);
  stranger.send(Uint8List.fromList([9, 9, 9]), hub.socket.address, hub.socket.port);
  await Future.delayed(const Duration(milliseconds: 200));
  check(hub.directLinks.length == 1, '8: unknown endpoint ignored');
  stranger.close();

  // 9. pipe delegate observes the forwarded DATA packet
  var recorder = PipeRecorder();
  factory.pipeDelegate = recorder;
  var probe = DirectPacketFactory().data(Uint8List.fromList([7, 8, 9]), sn: 9);
  peer.send(probe.pack(), hub.socket.address, hub.socket.port);
  await Future.delayed(const Duration(milliseconds: 200));
  check(recorder.calls == 1, '9: pipe delegate observed the packet');
  factory.pipeDelegate = null;

  server.close();
  peer.close();
  hub.socket.close();
  print(failed == 0 ? '\nAll tests passed' : '\n$failed test(s) FAILED');
}
