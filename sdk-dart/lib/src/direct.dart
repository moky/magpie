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

/// DirectPacket (B=0): peer-to-peer packets without relay. No target/source
/// bids and no attachment (data integrity is the app's responsibility).
///
/// Instruction factories live on [DirectPacketFactory]; this class only
/// exposes the parse-facing constructor and the `create` constructor.
class DirectPacket extends BasePacket {
  /// Wrap a parsed or freshly built inner packet as a direct packet,
  /// asserting that no bridge ids are carried (B=0, target=source=0).
  ///
  /// End users normally obtain direct packets from [DirectPacketFactory]
  /// (instructions) or from its [DirectPacketFactory.parse] (received
  /// datagrams), so this constructor is rarely called directly.
  DirectPacket(super._packet) {
    assert(bid == 0 && target == 0 && source == 0, 'packet bid error:'
        ' bid=$bid, target=$target, source=$source.');
  }

  //
  //  Factory
  //

  /// Build a fresh DirectPacket from scratch (wire bytes not yet packed).
  ///
  /// [ack] is the reply flag (A).
  /// [sn] is the data serial number.
  /// [index] is the fragment offset within the transfer.
  /// [count] is the total number of fragments.
  /// [command] is the reserved command value (0 for plain DATA).
  /// [payload] is the payload bytes (`null` means empty).
  factory DirectPacket.create({
    required int ack,
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
    return DirectPacket(MessagePacket(null,
      ack: ack,
      bid: 0,
      cmd: cmd,
      dsn: dsn,
      ext: ext,
      headerLength: calcHeaderLength(bid: 0, cmd: cmd, dsn: dsn, ext: ext),
      payloadLength: payload.length,
      target: 0,
      source: 0,
      sn: sn,
      index: index,
      count: count,
      command: command,
      payload: payload,
    ));
  }

}
