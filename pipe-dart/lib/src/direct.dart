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
import 'dart:typed_data';

import 'package:magpie_bridge/protocol.dart';
import 'package:magpie_bridge/factory.dart';

import 'link.dart';
import 'pipe.dart';

/// Link to a peer directly (B=0): the three-way handshake (SYN?/SYN!/
/// ACK!) establishes the connection without secret/token; data packets
/// are answered with "COPY" and handed to the pipe to process.
class DirectLink extends BaseLink {
  DirectLink(super.socket, super.remote, {required super.enigma});

  final packetFactory = DirectPacketFactory();

  DirectPipe? _directPipe;

  @override
  bool ready = false;

  /// Initiator side: send a "SYN?" to start the three-way handshake
  /// (docs/workflow.md §2.3). Both sides may call [connect] - the
  /// simultaneous open converges.
  @override
  void connect([DateTime? now]) {
    now ??= DateTime.now();
    final request = {
      'time': now.millisecondsSinceEpoch / 1000.0,
    };
    _directPipe ??= _newPipe();
    sendPacket(packetFactory.syn(
      encodePayload(request),
    ));
  }

  /// Send a "FIN?" wave to the peer: close the direct connection
  /// (docs/workflow.md §2.4).
  @override
  void disconnect([DateTime? now]) {
    now ??= DateTime.now();
    final request = {
      'time': now.millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.fin(
      encodePayload(request),
    ));
  }

  /// Idle-triggered heartbeat (docs/client.md §6): when no datagram has
  /// been sent or received for [Config.heartbeatInterval], send a "PING"
  /// with the payload `{"time": ...}`. Direct packets carry no
  /// attachment (no shared secret).
  @override
  void heartbeat([DateTime? now]) {
    if (!ready) {
      // not handshook yet
      return;
    }
    now ??= DateTime.now();
    // idle check: now - max(lastSendTime, lastReceivedTime) > H
    final last = lastActiveTime;
    final idle = last == null ? null : now.difference(last);
    if (idle == null || idle.inMilliseconds < config.heartbeatInterval * 1000) {
      return;  // no traffic yet, or traffic is recent: no ping needed
    }
    final request = {
      'time': now.millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.ping(
      encodePayload(request),
    ));
    // lastSendTime is refreshed by sendPacket()
  }

  /// Respond to the peer's "SYN?": reply "SYN!" (responder side of the
  /// three-way handshake, docs/workflow.md §2.3).
  void _handleSyn(Magpie packet) {
    final response = {
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.synAck(
      encodePayload(response),
    ));
  }

  /// The peer's "SYN!" received (initiator side): confirm with "ACK!".
  void _handleSynAck(Magpie packet) {
    final response = {
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.ack(
      encodePayload(response),
    ));
    ready = true;
  }

  /// The peer's "ACK!" received (responder side): handshake complete.
  void _handleAck(Magpie packet) {
    ready = true;
  }

  /// Answer "COPY" to a data packet from the peer: sn/index are paired
  /// automatically so the sender's queue can dequeue (docs/client.md
  /// §4.2, §9).
  void _replyCopy(Magpie packet) {
    final request = {
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.copy(
      encodePayload(request),
      packet,
    ));
    // lastSendTime is refreshed by sendPacket()
  }

  /// Reply "FIN!" to the peer's "FIN?" (minimal wave - the reverse
  /// close is up to the upper layer).
  void _replyFin(Magpie packet) {
    final request = {
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.finAck(
      encodePayload(request),
      packet,
    ));
  }

  /// Build a pipe bound to this connection: the application must plug
  /// a custom [PipeFactory] via [PipeExtensions].
  DirectPipe? _newPipe() {
    return sharedPipeExtensions.pipeFactory?.createDirectPipe(this);
  }

  @override
  Packet? parse(Uint8List data) {
    final packet = packetFactory.parse(data);
    if (packet == null) {
      return null;  // silently drop malformed datagrams
    } else if (packet.bid != 0) {
      return null;  // forged source: not for this connection
    }
    // direct packets carry no attachment (docs/protocol.md §4)
    return packet;
  }

  @override
  void processPacket(Packet packet) {
    switch (packet.command) {
      case Command.SYN:
        _handleSyn(packet);
        return;
      case Command.SYN_ACK:
        _handleSynAck(packet);
        return;
      case Command.ACK:
        _handleAck(packet);
        return;
      case Command.FIN:
        // the peer is closing: reply "FIN!" (minimal wave - the reverse
        // close is up to the upper layer)
        _replyFin(packet);
        return;
      case Command.PONG:
      case Command.COPY:
        // consumed by the app via the packet factory
        return;
    }
    // data packet from the peer (A=0, D=1): answer "COPY" with sn/index
    // paired (docs/client.md §4.2, §9)
    if (packet.ack == 0 && packet.sn != 0) {
      _replyCopy(packet);
    }
    // hand DATA/PONG to the pipe: merge fragments on DATA, measure RTT
    // on PONG, etc.
    final pipe = getPipe(0);
    pipe?.processPacket(packet);
  }

  @override
  MagPipe? getPipe(int remote) {
    assert(remote == 0, 'direct connection has no bid: $remote');
    return _directPipe;
  }

}
