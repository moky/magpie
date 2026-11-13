// Magpie Bridge pipe transport - minimal usage example.
//
// Start the relay server (see the server project) on 127.0.0.1:9527,
// then run:
//
//   dart run example/magpipe_example.dart
//
// The flow follows docs/client.md: hub -> bridge handshake -> permits
// -> data exchange. The peer's bid is announced out-of-band here.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:magpipe/magpipe.dart';

/// the app's delegate: observes every packet received through the links
class PacketPrinter implements MagpieDelegate {
  @override
  void onPacketReceived(Packet packet, MagPipe? pipe, MagLink link) {
    // a message from the peer (A=0, D=1): print the payload
    if (packet.ack == 0 && packet.dsn == 1 && packet.payload.isNotEmpty) {
      print('<< ${utf8.decode(packet.payload, allowMalformed: true)}');
    } else {
      print('<< ${packet.runtimeType} (${packet.payloadLength}B)');
    }
  }
  @override
  void onPacketSent(Magpie packet, MagPipe? pipe, MagLink link) {}
  @override
  void onPacketFailed(Magpie packet, MagPipe? pipe, MagLink link) {}
}

Future<void> main() async {
  registerHmacSha256();
  final server = (host: InternetAddress.loopbackIPv4, port: 9527);
  const peer = 42;  // the peer's bid, announced out-of-band

  // 1. the hub binds one shared UDP socket for every connection; the
  //    delegate observes every packet received through the links
  final hub = await MagHub.create(
      enigma: Enigma(), config: Config(), delegate: PacketPrinter());

  // 2. connect to the relay server (B=1): the three-way handshake runs
  //    in the background until the link is [ready]
  final bridge = hub.connectBridge(server);
  var waited = 0;
  while (!bridge.ready && waited < 50) {  // 50 x 100ms = 5s deadline
    await Future.delayed(const Duration(milliseconds: 100));
    waited++;
  }
  if (!bridge.ready) {
    print('no relay server on ${server.host}:${server.port} - start one first');
    hub.close();
    return;
  }
  print('bridge ready, bid = ${bridge.bid}');

  // 3. accept the peer's bid: data from bid 42 will be forwarded to us
  bridge.accept([peer]);

  // 4. send a message to the peer (sn increments per message)
  var sn = 0;
  var payload = Uint8List.fromList(utf8.encode('hello magpie'));
  var ok = hub.sendData(payload, remote: server, target: peer, sn: ++sn);
  print(ok ? '>> hello magpie' : '>> send failed');

  // ... keep the process alive to receive the peer's replies
  for (var i = 0; i < 5; i++) {
    hub.keepAlive(DateTime.now());  // drive heartbeats / re-connects
    await Future.delayed(const Duration(seconds: 1));
  }
  hub.disconnect(server);
  hub.close();
}
