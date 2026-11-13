/* license: https://mit-license.org
 *
 *  Magpie Bridge
 *
 *                               Written in 2026 by Moky <albert.moky@gmail.com>
 *
 * ==============================================================================
 * The MIT License (MIT)
 *
 * Copyright (c) 2026 Albert Moky
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 * ==============================================================================
 */
import 'dart:io';
import 'dart:typed_data';

import 'package:magpie_bridge/protocol.dart';

import 'utils/config.dart';
import 'utils/enigma.dart';

import 'bridge.dart';
import 'link.dart';
import 'direct.dart';
import 'pipe.dart';

/// UDP hub: wraps one shared socket and multiplexes every [MagLink]
/// registered on it.
///
/// The hub runs no timers: call [MagHub.keepAlive] periodically from
/// your own timer/scheduler (e.g. once a second) - it heartbeats idle
/// links and re-connects the dead ones.
///
/// Usage:
/// ```
/// var enigma = Enigma();
/// enigma.updateSecrets(secrets);
/// var config = Config();
/// var hub = MagHub(socket, enigma: enigma, config: config);  // or MagHub.create(...)
/// sharedMagpieExtensions.pipeFactory = PipeFactory();
/// var bridge = hub.connectBridge(server);  // bridge connection (B=1)
/// var direct = hub.connect(peer);          // direct connection (B=0)
/// ...
/// hub.disconnect(remote);
/// hub.close();
/// ```
///
/// Incoming datagrams are dispatched to the connection matching the
/// sender's endpoint; datagrams from unregistered endpoints are dropped.
class MagHub {
  /// Create the hub on a pre-bound [socket]: the app controls the
  /// binding (e.g. a fixed port).
  ///
  /// [enigma] feeds the encrypted handshake and is shared by every
  /// bridge link of this hub (docs/client.md §5.2) - build and load it
  /// before creating the hub.
  MagHub(this._socket, {
    required Enigma enigma,
    required Config config,
  }) : _enigma = enigma, _config = config {
    // pump the shared socket: route each datagram to its connection
    _socket.listen(_onEvent);
  }

  final Config _config;

  /// The enigma shared by this hub's bridge links: its key table feeds
  /// the encrypted handshake.
  final Enigma _enigma;

  /// The shared local UDP socket (bound once, used by all links).
  final RawDatagramSocket _socket;

  /// All live bridge links (B=1), keyed by the relay server's endpoint.
  final Map<SocketAddress, BridgeLink> _bridgeLinks = {};

  /// All live direct links (B=0), keyed by the peer's endpoint.
  final Map<SocketAddress, DirectLink> _directLinks = {};

  /// Create the hub: bind the shared UDP socket on [host]:[port]
  /// (defaults: all IPv4 interfaces, ephemeral port). See the
  /// [MagHub] constructor for [enigma].
  static Future<MagHub> create({
    InternetAddress? host,
    int port = 0,
    required Enigma enigma,
    required Config config,
  }) async => MagHub(
    await RawDatagramSocket.bind(host ?? InternetAddress.anyIPv4, port),
    enigma: enigma,
    config: config,
  );

  /// Register a direct link to the peer endpoint [remote] (B=0).
  /// Returns the existing link when that endpoint is already
  /// registered (idempotent).
  DirectLink connect(SocketAddress remote) {
    var link = _directLinks[remote];
    if (link == null) {
      link = DirectLink(_socket, remote, enigma: _enigma, config: _config);
      _directLinks[remote] = link;
      link.connect();  // send "SYN?" (stateless handshake)
    }
    return link;
  }

  /// Register a bridge link to the relay server [remote] (B=1); starts
  /// the handshake. Returns the existing link when that endpoint is
  /// already registered (idempotent).
  BridgeLink connectBridge(SocketAddress remote) {
    var link = _bridgeLinks[remote];
    if (link == null) {
      link = BridgeLink(_socket, remote, enigma: _enigma, config: _config);
      _bridgeLinks[remote] = link;
      link.connect();  // send "SYN?"
    }
    return link;
  }

  /// Remove the connection to the remote endpoint [remote] (sends
  /// "FIN?" for a bridge connection). Returns the removed connection,
  /// or null when that endpoint is not registered.
  MagLink? disconnect(SocketAddress remote) {
    MagLink? link = _directLinks.remove(remote);
    link ??= _bridgeLinks.remove(remote);
    if (link == null) {
      return null;
    }
    link.disconnect();  // bridge: send "FIN?"; direct: stateless no-op
    return link;
  }

  /// Close the hub: disconnect every registered link (bridge links send
  /// their "FIN?" waves) and then close the shared socket. The hub is
  /// empty afterwards; create a new one to continue.
  void close() {
    for (var link in _bridgeLinks.values) {
      link.disconnect();
    }
    for (var link in _directLinks.values) {
      link.disconnect();
    }
    _bridgeLinks.clear();
    _directLinks.clear();
    _socket.close();
  }

  /// Get the direct pipe to the peer [remote] (B=0): connect first,
  /// then return the pipe of the direct link.
  ///
  /// Returns null when no [PipeFactory] is plugged via [MagpieExtensions].
  MagPipe? getDirectPipe(SocketAddress remote) {
    final link = connect(remote);
    return link.getPipe(0);
  }

  /// Get the bridge pipe to the peer [target] through the relay server
  /// at [remote] (B=1): connect first, then return the pipe bound to
  /// [target] on the bridge link.
  ///
  /// When the peer pipe doesn't exist yet and the link is ready, an
  /// `accept([target])` is sent automatically to permit the target,
  /// then the pipe is looked up again.
  ///
  /// Returns null when no [PipeFactory] is plugged via [MagpieExtensions],
  /// or the link is not ready yet (no "ACK!" received).
  MagPipe? getBridgePipe(SocketAddress remote, int target) {
    final link = connectBridge(remote);
    var pipe = link.getPipe(target);
    if (pipe == null && target != 0 && link.bid != 0) {
      // no pipe for this bid yet: permit it, then look up again
      link.accept([target]);
      pipe = link.getPipe(target);
    }
    return pipe;
  }

  /// Send a pre-built packet through the connection registered for
  /// [remote]: a bridged packet (B=1) is delivered to the peer at
  /// `packet.target`; a direct packet (B=0) goes to the peer directly.
  /// The connection is established on demand.
  ///
  /// The bridge connection must be ready (`link.ready`): a pre-ready
  /// call trips the assert in debug builds and returns false in
  /// release (the packet is lost); the direct connection defers the
  /// packet until the handshake completes. Returns false also when
  /// the connection has no pipe for [packet.target], or the pipe
  /// fails to send.
  bool sendPacket(Packet packet, {required SocketAddress remote}) {
    MagPipe? pipe;
    if (packet.bid == 0) {
      pipe = getDirectPipe(remote);
    } else {
      assert(packet.source != 0 && packet.target != 0, 'bid error: $packet');
      pipe = getBridgePipe(remote, packet.target);
    }
    if (pipe == null) {
      assert(false, 'failed to get pipe: $remote');
      return false;
    }
    return pipe.sendPacket(packet);
  }

  /// Send a data payload through the connection registered for [remote].
  ///
  /// [target] selects the transport: non-zero sends it via the bridge
  /// link ([target] being the peer's bid, relayed by the server); zero
  /// sends it via the direct link (no bid on the wire). The connection
  /// is established on demand.
  ///
  /// Returns false when the pipe fails to send. The bridge connection
  /// must be ready (`link.ready`): a pre-ready call trips the assert
  /// in debug builds and returns false in release (the packet is
  /// lost); the direct connection defers the packet until the
  /// handshake completes.
  bool sendData(Uint8List payload, {
    required SocketAddress remote,
    required int target,
    required int sn,
    int index = 0,
    int count = 1,
  }) {
    MagPipe? pipe;
    if (target == 0) {
      pipe = getDirectPipe(remote);
    } else {
      pipe = getBridgePipe(remote, target);
    }
    if (pipe == null) {
      assert(false, 'failed to get pipe: $remote');
      return false;
    }
    return pipe.sendData(payload, sn: sn, index: index, count: count);
  }

  /// The run loop: scan all links on schedule, calling what each link
  /// needs (docs/client.md §6, §8):
  ///   * bridge link - [BridgeLink.needsReconnect] when the server record
  ///     is likely gone or the handshake is stuck (re-handshake), else
  ///     [BridgeLink.heartbeat] when idle;
  ///   * direct link - [DirectLink.reconnect] while the handshake is
  ///     unfinished (rate-limited "SYN?" retries), else
  ///     [DirectLink.heartbeat] when idle.
  void keepAlive([DateTime? now]) {
    for (var link in _bridgeLinks.values) {
      if (link.needsReconnect(now)) {
        link.reconnect(now);
      } else if (link.needsHeartbeat(now)) {
        link.heartbeat(now);
      }
    }
    for (var link in _directLinks.values) {
      if (link.needsReconnect(now)) {
        link.reconnect(now);
      } else if (link.needsHeartbeat(now)) {
        link.heartbeat(now);
      }
    }
  }

  /// Route each incoming datagram to the connection matching the sender's
  /// endpoint; datagrams from unregistered endpoints are dropped silently.
  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) {
      return;
    }
    Datagram? dg;
    while ((dg = _socket.receive()) != null) {
      final remote = (host: dg!.address, port: dg.port);
      (_bridgeLinks[remote] ?? _directLinks[remote])?.received(dg.data);
    }
  }
}
