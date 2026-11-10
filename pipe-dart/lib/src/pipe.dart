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

import 'package:magpie_bridge/factory.dart';
import 'package:magpie_bridge/protocol.dart';

import 'utils/payload.dart';

import 'bridge.dart';
import 'direct.dart';

/// Pipe: processes data packets forwarded by the MagLink.
///
/// The application inherits this class and overrides [MagPipe.processPacket]
/// to implement its own receiving logic (dedup by sn, fragment reassembly
/// and delivery of the payload, docs/client.md §4.2).
abstract interface class MagPipe {

  /// Handle one data packet forwarded by the connection: the default
  /// implementation answers "COPY" to data packets (A=0, D=1) and
  /// "PONG" to heartbeats.
  void processPacket(Packet packet);

  bool sendPacket(Magpie packet);

  bool sendData(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  });

}

class DirectPipe with PayloadMixIn implements MagPipe {
  DirectPipe(this.connection);

  /// The connection this pipe is attached to.
  final DirectLink connection;

  final packetFactory = DirectPacketFactory();

  @override
  bool sendPacket(Magpie packet) => connection.sendPacket(packet);

  @override
  bool sendData(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  }) {
    final packet = packetFactory.data(payload,
      sn: sn,
      index: index,
      count: count,
    );
    return sendPacket(packet);
  }

  /// Answer "PONG" to the peer's "PING": echo the payload except
  /// 'time', which is updated to the local clock (docs/client.md §6).
  @override
  void processPacket(Packet packet) {
    if (packet.cmd == 1 && packet.command == Command.PING) {
      // heartbeat from the peer: answer "PONG" (docs/client.md §6)
      _replyPong(packet);
    } else if (packet.ack == 0 && packet.dsn == 1) {
      // data packet from the peer (A=0, D=1): answer "COPY" with sn/index
      // paired (docs/client.md §4.2, §9); the receiving logic (dedup,
      // fragment reassembly and delivery) is up to the application - it
      // can override this method and plug its own buffers in
      _replyCopy(packet);
    }
  }

  void _replyPong(Magpie packet) {
    final info = decodePayload(packet.payload);
    info['time'] = DateTime.now().millisecondsSinceEpoch / 1000.0;
    sendPacket(packetFactory.pong(
      encodePayload(info),
      packet,
    ));
  }

  void _replyCopy(Magpie packet) {
    final request = {
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.copy(
      encodePayload(request),
      packet,
    ));
  }

}

class BridgePipe with PayloadMixIn implements MagPipe {
  BridgePipe(this.connection, {required this.remote, required this.local});

  /// The connection this pipe is attached to.
  final BridgeLink connection;

  final int remote;  // contact's bid
  final int local;   // my bid

  final packetFactory = BridgePacketFactory();

  @override
  bool sendPacket(Magpie packet) => connection.sendPacket(packet);

  @override
  bool sendData(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  }) {
    final target = remote;
    final source = local;
    if (target == 0 || source == 0) {
      assert(false, 'bids error: target=$target, source=$source.');
      return false;
    }
    final packet = packetFactory.data(payload,
      target: target,
      source: source,
      sn: sn,
      index: index,
      count: count,
    );
    return sendPacket(packet);
  }

  /// Answer "PONG" to the peer's "PING": echo the payload except
  /// 'time', which is updated to the local clock (docs/client.md §6).
  @override
  void processPacket(Packet packet) {
    if (packet.cmd == 1 && packet.command == Command.PING) {
      // heartbeat from the peer: answer "PONG" (docs/client.md §6)
      _replyPong(packet);
    } else if (packet.ack == 0 && packet.dsn == 1) {
      // data packet forwarded from a peer (A=0, D=1): answer "COPY" with
      // sn/index paired (docs/client.md §4.2, §9); the receiving logic
      // (dedup, fragment reassembly and delivery) is up to the
      // application - it can override this method and plug its own
      // buffers in
      _replyCopy(packet);
    }
  }

  void _replyPong(Magpie packet) {
    final info = decodePayload(packet.payload);
    info['time'] = DateTime.now().millisecondsSinceEpoch / 1000.0;
    sendPacket(packetFactory.pong(
      encodePayload(info),
      packet,
    ));
  }

  void _replyCopy(Magpie packet) {
    final request = {
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.copy(
      encodePayload(request),
      packet,
    ));
  }

}

//
//  Factory
//

abstract interface class PipeFactory {

  DirectPipe createDirectPipe(DirectLink conn);

  BridgePipe createBridgePipe(BridgeLink conn, {
    required int remote,
    required int local,
  });

}

class PipeExtensions {
  factory PipeExtensions() => _instance;
  static final PipeExtensions _instance = PipeExtensions._internal();
  PipeExtensions._internal();

  PipeFactory? pipeFactory;

}

final sharedPipeExtensions = PipeExtensions();
