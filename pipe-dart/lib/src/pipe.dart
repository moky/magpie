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

import 'package:magpie_bridge/magpie.dart';
import 'package:magpie_bridge/factory.dart';

import 'bridge.dart';
import 'direct.dart';

/// Pipe base class: processes data packets forwarded by the MagLink.
///
/// Single packets are delivered directly via [onMessage]; fragmented
/// packets wait for all fragments to arrive and reassemble before the
/// callback fires (the reassembly flow is documented in [process] and is
/// meant to be overridden by the application).
abstract interface class MagPipe {

  /// Handle one data packet forwarded by the connection.
  ///
  /// Single packets are delivered directly; fragmented packets wait for
  /// all fragments to arrive and reassemble before the callback fires
  /// (the reassembly flow is documented here and is meant to be
  /// overridden by the application):
  ///
  ///  1. buffer the fragment indexed by `packet.index`;
  ///  2. when every fragment `0..count-1` has arrived, concatenate them
  ///     in ascending index order into the original buffer;
  ///  3. fire [onMessage] with the reassembled payload and clear the
  ///     buffer for the next `sn`.
  void processPacket(Magpie packet);

  bool sendPacket(Magpie packet);

  bool sendData(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  });

}

abstract class DirectPipe implements MagPipe {
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

}

abstract class BridgePipe implements MagPipe {
  BridgePipe(this.connection, {required this.remote, required this.local});

  /// The connection this pipe is attached to.
  final BridgeLink connection;

  final int remote;
  final int local;

  final packetFactory = BridgePacketFactory();

  // TODO: processPacket() - dedup by mid = (sn << 32) | index
  // (received_sn_set), reassemble fragments (receiving_table) with the
  // T2 cleanup, and dequeue the sending queue on COPY
  // (docs/client.md §2, §4.2)

  @override
  bool sendPacket(Magpie packet) => connection.sendPacket(packet);

  @override
  bool sendData(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  }) {
    // TODO: sending queue - retransmission (T/R), send window (K),
    // queue capacity (C) and fragmentation of oversized payloads
    // (docs/client.md §3)
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
