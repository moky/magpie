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

import 'base.dart';

/// The base class for links: the shared state (socket, enigma, config,
/// delegate), the scheduling predicates and the send path (signing,
/// deferral) - the concrete links add the handshake state machines.
abstract class BaseLink implements MagLink {
  /// Creates the link on the pre-bound [socket] for [remoteAddress]:
  /// the enigma/config/delegate are shared by every link of the hub.
  BaseLink(this.socket, this.remoteAddress, {
    required this.enigma,
    required this.config,
    required this.delegate
  });

  /// The app layer's observer: sees every packet received through,
  /// sent over or dropped by this link.
  // protected
  final MagpieDelegate delegate;

  /// The timing knobs shared by every link of this hub: heartbeat and
  /// handshake intervals, limits.
  // protected
  final Config config;

  /// Feeds the encrypted handshake: decrypts the session secret from
  /// the server's "SYN!" reply.
  // protected
  final Enigma enigma;

  /// The bound local UDP socket.
  // protected
  final RawDatagramSocket socket;

  @override
  final SocketAddress remoteAddress;

  @override
  String? observedAddress;

  /// The peer's IP address.
  InternetAddress get host => remoteAddress.host;

  /// The peer's UDP port.
  int get port => remoteAddress.port;

  /// Whether [disconnect] was called (intentional close): the run loop
  /// never re-dials a closed link. Cleared by [connect] on re-open.
  bool get closed;

  /// The session secret bound after the "SYN!" (null = not yet);
  /// packets bound for the server are signed with it.
  Uint8List? get secret;

  /// Time of the last outgoing datagram (refreshed by [packAndSend]:
  /// data, handshake waves and heartbeats all count).
  DateTime? lastSendTime;

  /// Time of the last incoming datagram (refreshed by [processPacket]:
  /// PONG, COPY, data and system commands all count).
  DateTime? lastReceivedTime;

  /// Whether the link has been idle long enough for a heartbeat (H =
  /// [Config.heartbeatInterval], docs/client.md §6): neither direction
  /// has seen traffic for longer than H.
  ///
  /// Returns false when the handshake is unfinished (the run loop
  /// reconnects instead), or when nothing has ever been sent on this
  /// link (nothing to keep alive yet).
  // protected
  bool needsHeartbeat([DateTime? now]) {
    if (!ready) {
      // handshake unfinished, or disconnected
      return false;
    }
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
    now ??= DateTime.now();
    return now.difference(lastActive).inMilliseconds > config.heartbeatInterval * 1000;
  }

  /// Whether the manager should re-connect this link on this tick
  /// (docs/client.md §6, §8):
  ///
  ///   * ready link - only when the session has gone silent
  ///     ([isSessionStale], overridden by each link type);
  ///   * not-ready link - the handshake is stuck: the last "SYN?" went
  ///     out at least [Config.handshakeInterval] ago (the rate limit),
  ///     so re-send one - the first datagram may have been lost; true
  ///     at once when nothing has been sent yet.
  // protected
  bool needsReconnect([DateTime? now]) {
    if (ready) {
      return isSessionStale(now);
    }
    return isHandshakeStuck(now);
  }

  /// Whether the handshake needs a fresh "SYN?" (docs/workflow.md §2.3):
  /// true when nothing has been sent yet (dial now), or when the last
  /// "SYN?" went out at least [Config.handshakeInterval] ago - at most
  /// one "SYN?" per handshake interval.
  // protected
  bool isHandshakeStuck([DateTime? now]) {
    if (closed) {
      // intentionally closed: the run loop never re-dials
      return false;
    }
    final lastSent = lastSendTime;
    if (lastSent == null) {
      // nothing sent yet: dial now
      return true;
    }
    now ??= DateTime.now();
    // rate limit: at most one "SYN?" per handshake interval
    return now.difference(lastSent).inMilliseconds >=
        config.handshakeInterval * 1000;
  }

  /// Whether an established session has gone silent: the run loop
  /// re-connects when this is true. Each link type answers in its own
  /// terms - see the implementations in the subclasses.
  // protected
  bool isSessionStale([DateTime? now]);

  /// Outbound packets deferred while re-handshaking; signed and sent
  /// once the handshake completes.
  final List<Magpie> _pendingPackets = [];

  /// Send the packets deferred while re-handshaking.
  ///
  /// A packet queued while the secret is cleared (bridge re-handshake
  /// window; only reachable through a held pipe reference) goes out
  /// unsigned and is dropped by the server - an acceptable, rare loss
  /// healed by the app-level retransmission (docs/client.md §3), so
  /// no re-signing here on purpose.
  void drain() {
    final deferred = List.of(_pendingPackets);
    _pendingPackets.clear();
    for (var packet in deferred) {
      packAndSend(packet);
    }
  }

  /// Pack and send the datagram as-is: no signing, no deferral - the
  /// exact bytes a previous sendPacket would have put on the wire.
  // protected
  bool packAndSend(Magpie packet) {
    final pipe = getPipe(packet.target);
    final data = packet.pack();
    final size = socket.send(data, host, port);
    if (size != data.length) {
      delegate.onPacketFailed(packet, pipe, this);
      return false;
    }
    lastSendTime = DateTime.now();
    delegate.onPacketSent(packet, pipe, this);
    return true;
  }

  @override
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
        return packAndSend(packet);
    }
    // ACPT, DENY
    // DATA, COPY
    // PING, PONG
    // ...
    if (ready) {
      return packAndSend(packet);
    } else if (command != Command.PING && command != Command.PONG) {
      // waiting for handshake (bounded: keep the newest packets)
      if (_pendingPackets.length >= config.maxPendingPackets) {
        // queue full: drop the oldest and notify the app
        final dropped = _pendingPackets.removeAt(0);
        final pipe = getPipe(dropped.target);
        delegate.onPacketFailed(dropped, pipe, this);
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

  /// Parse the raw bytes into a packet: null for malformed datagrams
  /// (the link then stays silent - no delegate notification).
  Packet? parse(Uint8List data);

  /// Dispatch a received packet: the pipe answers PONG/COPY first, then
  /// the app delegate observes the packet.
  ///
  /// [pipe] may be null when the packet arrives before its pipe exists
  /// (e.g. handshake waves) - the app distinguishes via this link.
  void processPacket(Packet packet) {
    // 1. call pipe to reply PONG/COPY
    final pipe = getPipe(packet.source);
    pipe?.processPacket(packet);
    // 2. call app to process the payload
    delegate.onPacketReceived(packet, pipe, this);
  }

}
