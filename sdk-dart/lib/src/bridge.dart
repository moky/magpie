/* license: https://mit-license.org
 *
 *  Magpie Bridge Messaging Protocol
 *
 *                               Written in 2026 by Moky <albert.moky@gmail.com>
 *
 * =============================================================================
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
 * =============================================================================
 */
import 'dart:typed_data';

import 'protocol/protocol.dart';

import 'packet.dart';
import 'reliable.dart';

/// BridgePacket (B=1): packets exchanged with the relay server, or forwarded
/// by the server between two clients. These packets carry target/source bids
/// and MAY be signed (HMAC-SHA256) once a secret has been established.
///
/// Instruction factories live on [BridgePacketFactory]; this class only
/// exposes the parse-facing constructor, the `create` constructor and the
/// [sign] method inherited from [BasePacket].
class BridgePacket extends BasePacket {
  /// Wrap a parsed or freshly built inner packet as a bridge packet,
  /// asserting that the bridge flag is set (B=1).
  ///
  /// End users normally obtain bridge packets from [BridgePacketFactory]
  /// (instructions) or from its [BridgePacketFactory.parse] (received
  /// datagrams), so this constructor is rarely called directly.
  BridgePacket(super._packet) {
    assert(bid == 1, 'packet bid error:'
        ' bid=$bid, target=$target, source=$source.');
  }

  //
  //  Factory
  //

  /// Build a fresh BridgePacket from scratch (wire bytes not yet packed).
  ///
  /// [ack] is the reply flag (A).
  /// [target] is the receiver's bid.
  /// [source] is the sender's bid.
  /// [sn] is the data serial number.
  /// [index] is the fragment offset within the transfer.
  /// [count] is the total number of fragments.
  /// [command] is the reserved command value (0 for plain DATA).
  /// [payload] is the payload bytes (`null` means empty).
  factory BridgePacket.create({
    required int ack,
    required int target,
    required int source,
    required int sn,
    required int index,
    required int count,
    required int command,
    required Uint8List? payload,
  }) {
    final cmd = calcCmd(command);
    final dsn = calcDsn(sn);
    final ext = calcExt(count);
    payload ??= Uint8List(0);
    return BridgePacket(MessagePacket(null,
      ack: ack,
      bid: 1,
      cmd: cmd,
      dsn: dsn,
      ext: ext,
      headerLength: calcHeaderLength(bid: 1, cmd: cmd, dsn: dsn, ext: ext),
      payloadLength: payload.length,
      target: target,
      source: source,
      sn: sn,
      index: index,
      count: count,
      command: command,
      payload: payload,
    ));
  }

}
