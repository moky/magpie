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

import 'package:magpie_bridge/magpie.dart';
import 'package:magpie_bridge/protocol.dart';

import 'utils/config.dart';
import 'utils/enigma.dart';

import 'pipe.dart';

abstract interface class MagLink {

  bool get ready;

  void connect([DateTime? now]);

  void disconnect([DateTime? now]);

  void heartbeat([DateTime? now]);

  /// Called when received raw bytes from the peer.
  void received(Uint8List data);

  //
  //   Pipes
  //

  MagPipe? getPipe(int remote);

}

abstract class BaseLink implements MagLink {
  BaseLink(this.socket, this.remoteAddress, {required this.enigma});

  /// The bound local UDP socket.
  final RawDatagramSocket socket;

  /// The remote endpoint of this connection (IP address + UDP port):
  /// the relay server for a bridge link, the peer for a direct link.
  final SocketAddress remoteAddress;

  /// The local address as observed by the peer, carried in the "UDP"
  /// field of the "SYN!" payload (bridge: docs/client.md §5.1,
  /// direct: docs/workflow.md §2.3); null until the handshake
  /// delivers it.
  String? observedAddress;

  /// The peer's IP address.
  InternetAddress get host => remoteAddress.host;

  /// The peer's UDP port.
  int get port => remoteAddress.port;

  @override
  bool ready = false;

  /// The configuration (handshake parameters, etc.); the app loads
  /// values via `config.update({...})`.
  final Config config = Config();

  /// The enigma for the encrypted handshake: `decrypt` derives the AES
  /// key from the ikm stored under the key name carried by the "SYN!"
  /// reply.
  final Enigma enigma;

  /// The session secret bound after the "SYN!" (null = not yet);
  /// packets bound for the server are signed with it.
  Uint8List? secret;

  /// Time of the last outgoing datagram (refreshed by [send]: data,
  /// handshake waves and heartbeats all count).
  DateTime? lastSendTime;

  /// Time of the last incoming datagram (refreshed by [process]: PONG,
  /// COPY, data and system commands all count).
  DateTime? lastReceivedTime;

  // protected
  bool needsHeartbeat(DateTime now) {
    // idle check: now - max(lastSendTime, lastReceivedTime) > H
    // (a link that has never received anything still heartbeats on its
    // last send)
    final lastSent = lastSendTime;
    final lastReceived = lastReceivedTime;
    final lastActive = lastSent == null ? lastReceived
        : (lastReceived == null || lastSent.isAfter(lastReceived) ? lastSent : lastReceived);
    if (lastActive == null) {
      // no traffic yet
      return false;
    }
    return now.difference(lastActive).inMilliseconds > config.heartbeatInterval * 1000;
  }

  /// Outbound packets deferred while re-handshaking; signed and sent
  /// once the handshake completes.
  final List<Magpie> _pendingPackets = [];

  /// Upper bound for [_pendingPackets]: further packets are dropped
  /// (sendPacket returns false) while the queue is full.
  static int maxPendingPackets = 256;

  /// Send the packets deferred while re-handshaking.
  void drain() {
    final deferred = List.of(_pendingPackets);
    _pendingPackets.clear();
    for (var packet in deferred) {
      _send(packet);
    }
  }

  bool _send(Magpie packet) {
    final data = packet.pack();
    final size = socket.send(data, host, port);
    if (size != data.length) {
      return false;
    }
    lastSendTime = DateTime.now();
    return true;
  }

  /// Pack and send the datagram to the remote endpoint, refreshing
  /// the last-send time for the heartbeat idle check. Data commands
  /// sent while the handshake is still in progress are deferred to
  /// [_pendingPackets] (bounded by [maxPendingPackets]).
  bool sendPacket(Magpie packet, {
    bool encryptedMode = true,
  }) {
    if (encryptedMode) {
      final msgKey = secret;
      if (msgKey != null && packet is! ReliablePacket) {
        packet = (packet as BasePacket).sign(msgKey);
      }
    }
    final command = packet.command;
    // system command
    switch (command) {
      // handshake
      case Command.SYN:
      case Command.SYN_ACK:
      case Command.ACK:
      // results
      case Command.FAIL:
      case Command.DONE:
      // shutdown
      case Command.FIN:
      case Command.FIN_ACK:
      case Command.NOOP:
        return _send(packet);
    }
    // ACPT, DENY
    // DATA, COPY
    // PING, PONG
    // ...
    if (ready) {
      return _send(packet);
    } else if (command != Command.PING && command != Command.PONG) {
      // waiting for handshake (bounded: keep the newest packets)
      if (_pendingPackets.length >= maxPendingPackets) {
        _pendingPackets.removeAt(0);
      }
      _pendingPackets.add(packet);
    }
    return false;
  }

  @override
  void received(Uint8List data) {
    final packet = parse(data);
    if (packet == null) {
      return;  // silently drop malformed datagrams
    }
    // any valid datagram proves the path is alive
    lastReceivedTime = DateTime.now();
    processPacket(packet);
  }

  Packet? parse(Uint8List data);

  void processPacket(Packet packet);

}
