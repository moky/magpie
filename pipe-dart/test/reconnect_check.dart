import 'dart:io';

import 'package:magpie_bridge/factory.dart';
import 'package:magpie_bridge/protocol.dart';

import 'package:magpipe/src/direct.dart';
import 'package:magpipe/src/utils/enigma.dart';

int failed = 0;
void check(bool ok, String name) {
  print('${ok ? "PASS" : "FAIL"}: $name');
  if (!ok) failed++;
}

/// count the datagrams queued on [s], tallying "SYN?" and "PING"
void drain(RawDatagramSocket s, List<int> counters) {
  Datagram? dg;
  while ((dg = s.receive()) != null) {
    final packet = DirectPacketFactory().parse(dg!.data);
    if (packet == null) {
      continue;  // silently drop malformed datagrams
    } else if (packet.command == Command.SYN) {
      counters[0]++;
    } else if (packet.command == Command.PING) {
      counters[1]++;
    }
  }
}

void main() async {
  // fake peer + client on loopback
  final peer = await RawDatagramSocket.bind('127.0.0.1', 0);
  final client = await RawDatagramSocket.bind('127.0.0.1', 0);
  final link = DirectLink(
    client, (host: peer.address, port: peer.port),
    enigma: Enigma(),
  );
  // counters[0] = "SYN?" sent, counters[1] = "PING" sent
  final counters = [0, 0];

  // the run loop pattern (hub.keepAlive): reconnect while the handshake
  // is unfinished, heartbeat when idle after it completes
  void keepAlive(DateTime now) {
    if (link.needsReconnect(now)) {
      link.reconnect(now);
    } else if (link.needsHeartbeat(now)) {
      link.heartbeat(now);
    }
  }

  // A: rapid ticks are rate-limited to the first "SYN?" only
  final now = DateTime.now();
  for (var i = 0; i < 5; i++) {
    keepAlive(now);
    drain(peer, counters);
  }
  check(counters[0] == 1, 'A: 5 rapid ticks -> 1 SYN? (got ${counters[0]})');

  // B: ticks spaced >= handshakeInterval go through until the retry
  // limit is exhausted (the synthetic future timestamps skip the wait)
  for (var k = 1; k <= 10; k++) {
    keepAlive(now.add(Duration(seconds: 4 * k)));
    drain(peer, counters);
  }
  check(counters[0] == 5, 'B: spaced ticks -> 5 SYN? total (got ${counters[0]})');

  // C: after the limit, the link stays quiet
  keepAlive(now.add(const Duration(seconds: 400)));
  drain(peer, counters);
  check(counters[0] == 5, 'C: over the limit -> no more SYN? (got ${counters[0]})');

  // D: the peer's "SYN!" completes the handshake (retry counter resets)
  final synAck = DirectPacketFactory().synAck(link.encodePayload({
    'time': 0.0,
    'UDP': '127.0.0.1:${peer.port}',
  }));
  link.received(synAck.pack());
  drain(peer, counters);  // the "ACK!" the link just sent
  check(link.ready, 'D: handshake complete');

  // E: keepAlive switches to heartbeat - fresh "ACK!" means no PING
  // yet, and never a "SYN?" again
  keepAlive(DateTime.now());
  drain(peer, counters);
  check(counters[1] == 0, 'E: fresh ACK! -> no PING yet');
  check(counters[0] == 5, 'E: ready -> no extra SYN? (got ${counters[0]})');

  // F: idle ready link -> PING (docs/client.md §6)
  link.lastReceivedTime = null;
  link.lastSendTime = DateTime.now().subtract(const Duration(seconds: 11));
  keepAlive(DateTime.now());
  drain(peer, counters);
  check(counters[1] == 1, 'F: idle -> PING sent (got ${counters[1]})');

  // G: link-level disconnect keeps the run loop quiet afterwards
  link.disconnect();
  drain(peer, counters);
  link.lastSendTime = DateTime.now().subtract(const Duration(seconds: 30));
  keepAlive(DateTime.now());
  drain(peer, counters);
  check(counters[0] == 5, 'G: closed link -> no re-dial (got ${counters[0]})');
  check(counters[1] == 1, 'G: closed link -> no PING (got ${counters[1]})');

  peer.close();
  client.close();
  print(failed == 0 ? '\nAll tests passed' : '\n$failed test(s) FAILED');
}
