// Magpie Bridge pipe transport - minimal usage example.
//
// Start the relay server (see the server project) on 127.0.0.1:4004,
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

/// the app's bridge pipe: receives the data flow from the peer
class ChatPipe extends BridgePipe {
  ChatPipe(super.connection, {required super.remote, required super.local});

  @override
  void processPacket(Magpie packet) {
    // a message from the peer (A=0, D=1): print the payload (the "COPY"
    // reply is answered by the connection itself, see docs/client.md §4.2)
    final p = packet as Packet;
    if (p.ack == 0 && p.sn != 0) {
      print('<< ${utf8.decode(p.payload, allowMalformed: true)}');
    }
  }
}

/// the app's pipe factory: plugged into the shared PipeExtensions hook
class ChatPipeFactory implements PipeFactory {
  @override
  BridgePipe createBridgePipe(BridgeLink conn, {
    required int remote,
    required int local,
  }) => ChatPipe(conn, remote: remote, local: local);

  @override
  DirectPipe createDirectPipe(DirectLink conn) => throw UnimplementedError();
}

Future<void> main() async {
  registerHmacSha256();
  final server = (host: InternetAddress.loopbackIPv4, port: 4004);
  const peer = 42;  // the peer's bid, announced out-of-band

  // 1. the hub binds one shared UDP socket for every connection
  final hub = await MagHub.create();
  sharedPipeExtensions.pipeFactory = ChatPipeFactory();

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
    hub.socket.close();
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
  await Future.delayed(const Duration(seconds: 5));
  hub.disconnect(server);
  hub.socket.close();
}
