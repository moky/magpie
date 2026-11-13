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

  /// Handle one data packet forwarded by the link: the default
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
  DirectPipe(this._link);

  /// The link this pipe is attached to.
  final DirectLink _link;

  final _factory = DirectPacketFactory();

  /// Class name shown by [toString]: the actual runtime type when asserts
  /// are enabled (debug builds), or the fixed `'DirectPipe'` otherwise.
  // protected
  String get className {
    String name = 'DirectPipe';
    assert(() {
      name = runtimeType.toString();
      return true;
    }());
    return name;
  }

  @override
  String toString() => '$className{'
      'remote=${_link.remoteAddress}, observed=${_link.observedAddress}}';

  @override
  bool sendPacket(Magpie packet) => _link.sendPacket(packet);

  @override
  bool sendData(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  }) {
    final packet = _factory.data(payload,
      sn: sn,
      index: index,
      count: count,
    );
    return sendPacket(packet);
  }

  /// Answer "PONG" to the peer's "PING": echo the payload except
  /// 'time', which is updated to the local clock (docs/client.md §6).
  /// Data packets (A=0, D=1) are answered "COPY" with sn/index paired
  /// (docs/client.md §4.2, §9).
  ///
  /// Every packet also goes to the delegate: the application observes
  /// the full conversation and handles the payload itself (fragment
  /// reassembly is up to the app).
  @override
  void processPacket(Packet packet) {
    if (packet.cmd == 1 && packet.command == Command.PING) {
      // heartbeat from the peer: answer "PONG" (docs/client.md §6)
      _replyPong(packet);
    } else if (packet.ack == 0 && packet.dsn == 1) {
      // data packet from the peer (A=0, D=1): answer "COPY" with sn/index
      // paired (docs/client.md §4.2, §9)
      _replyCopy(packet);
    }
  }

  void _replyPong(Magpie packet) {
    final now = DateTime.now();
    final info = decodePayload(packet.payload);
    info['time'] = now.millisecondsSinceEpoch / 1000.0;
    sendPacket(_factory.pong(
      encodePayload(info),
      packet,
    ));
  }

  void _replyCopy(Magpie packet) {
    final now = DateTime.now();
    final request = {
      'time': now.millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(_factory.copy(
      encodePayload(request),
      packet,
    ));
  }

}

class BridgePipe with PayloadMixIn implements MagPipe {
  BridgePipe(this._link, {required this.target, required this.source});

  /// The link this pipe is attached to.
  final BridgeLink _link;

  final int target;  // contact's bid
  final int source;  // my bid

  final _factory = BridgePacketFactory();

  /// Class name shown by [toString]: the actual runtime type when asserts
  /// are enabled (debug builds), or the fixed `'BridgePipe'` otherwise.
  // protected
  String get className {
    String name = 'BridgePipe';
    assert(() {
      name = runtimeType.toString();
      return true;
    }());
    return name;
  }

  @override
  String toString() => '$className{target=$target, source=$source, '
      'bridge=${_link.remoteAddress}, observed=${_link.observedAddress}}';

  @override
  bool sendPacket(Magpie packet) => _link.sendPacket(packet);

  @override
  bool sendData(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  }) {
    if (target == 0 || source == 0) {
      assert(false, 'bids error: target=$target, source=$source.');
      return false;
    }
    final packet = _factory.data(payload,
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
  /// Data packets forwarded from a peer (A=0, D=1) are answered "COPY"
  /// with sn/index paired (docs/client.md §4.2, §9).
  ///
  /// Every packet also goes to the delegate: the application observes
  /// the full conversation and handles the payload itself (fragment
  /// reassembly is up to the app).
  @override
  void processPacket(Packet packet) {
    if (packet.cmd == 1 && packet.command == Command.PING) {
      // heartbeat from the peer: answer "PONG" (docs/client.md §6)
      _replyPong(packet);
    } else if (packet.ack == 0 && packet.dsn == 1) {
      // data packet forwarded from a peer (A=0, D=1): answer "COPY" with
      // sn/index paired (docs/client.md §4.2, §9)
      _replyCopy(packet);
    }
  }

  void _replyPong(Magpie packet) {
    final now = DateTime.now();
    final info = decodePayload(packet.payload);
    info['time'] = now.millisecondsSinceEpoch / 1000.0;
    sendPacket(_factory.pong(
      encodePayload(info),
      packet,
    ));
  }

  void _replyCopy(Magpie packet) {
    final now = DateTime.now();
    final request = {
      'time': now.millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(_factory.copy(
      encodePayload(request),
      packet,
    ));
  }

}
