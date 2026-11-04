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

import 'protocol/magpie.dart';
import 'protocol/protocol.dart';

/// The concrete, pack-only implementation of [Packet].
///
/// [MessagePacket] holds a fully validated header (flags, lengths and
/// optional fields) plus the payload, and serialises them to the wire
/// format in [pack]. It is an implementation detail: end users normally
/// receive [BridgePacket] / [DirectPacket] / [ReliablePacket] wrappers
/// from the factories, which delegate back to an inner [MessagePacket].
///
/// The header length obeys the formula N = 8 + 8·B + 4·D + 2·E + 4·C.
class MessagePacket implements Packet {
  /// Create a packet from already computed header fields.
  ///
  /// [buffer] is the cached wire bytes when the packet came from parsing,
  /// or `null` for a freshly built packet (serialised lazily by [pack]).
  /// [ack] is the reply flag (A): 1 = answers the peer's request.
  /// [bid] is the bridge flag (B): 1 = carries target/source bids.
  /// [cmd] is the command presence flag (C): 1 = the header carries [command].
  /// [dsn] is the data serial number flag (D): 1 = the header carries [sn].
  /// [ext] is the fragment parameter width (E): byte width of [index]/[count],
  ///       0/2/4 on the wire (1/3 accepted when parsing).
  /// [headerLength] is the computed header length.
  /// [payloadLength] is the payload length.
  /// [target] is the receiver's bid.
  /// [source] is the sender's bid.
  /// [sn] is the data serial number.
  /// [index] is the fragment offset within the transfer.
  /// [count] is the total number of fragments.
  /// [command] is the reserved command value (0 for plain DATA).
  /// [payload] is the payload bytes.
  ///
  /// The constructor asserts the length formula, the payload cap and the
  /// fragment range; wire-validated packets from [MessagePacketFactory]
  /// always satisfy them.
  MessagePacket(this._buffer, {
    required this.ack,
    required this.bid,
    required this.cmd,
    required this.dsn,
    required this.ext,
    required this.headerLength,
    required this.payloadLength,
    required this.target,
    required this.source,
    required this.sn,
    required this.index,
    required this.count,
    required this.command,
    required this.payload,
  }) {
    assert(headerLength == calcHeaderLength(bid: bid, cmd: cmd, dsn: dsn, ext: ext)
        && payload.length == payloadLength && payloadLength <= MAX_PAYLOAD_LENGTH
        && headerLength + payloadLength <= MSS, 'packet lengths error:'
        ' bid=$bid, cmd=$cmd, dsn=$dsn, ext=$ext,'
        ' header=$headerLength, payload=$payloadLength byte(s).'
    );
    assert(0 <= index && index < count, 'range error: index=$index, count=$count.');
  }

  /// Cached wire bytes (header + payload, no attachment).
  ///
  /// `null` until [pack] is first called on a freshly built packet;
  /// packets created by the parser carry the exact received bytes.
  Uint8List? _buffer;

  //
  //  Flags
  //

  /// A (0x80): 1 = reply to the peer's request.
  @override final int ack;

  /// B (0x40): 1 = bridge packet (client <-> server, has target/source).
  @override final int bid;

  /// C (0x20): 1 = carries a [command]; 0 = plain DATA.
  @override final int cmd;

  /// D (0x10): 1 = carries an [sn]; 0 = system command.
  @override final int dsn;

  /// E (0x07): byte width of the [index]/[count] fields (0/2/4 on the
  /// wire; 1/3 accepted when parsing).
  @override final int ext;

  //
  //  Lengths
  //

  /// Full header length in bytes (8 ~ 32), always matches [calcHeaderLength].
  @override final int headerLength;

  /// Payload length in bytes (0 ~ 1024 recommended for senders).
  @override final int payloadLength;

  //
  //  Fields
  //

  /// Target bridge id (0 = addressed to the server).
  @override final int target;

  /// Source bridge id (0 = handshake / server-down).
  @override final int source;

  /// Data serial number (0 for system commands).
  @override final int sn;

  /// Fragment index (0 for mini packets).
  @override final int index;

  /// Fragment count (1 for mini packets; >1 when fragmented).
  @override final int count;

  /// Reserved command value (0 = empty command, plain DATA).
  @override final int command;

  /// Payload bytes (empty for none).
  @override final Uint8List payload;

  //
  //  Serialization
  //

  /// Serialise to the wire bytes (header + payload, no attachment).
  ///
  /// The result is cached, so repeated calls are O(1) after the first.
  @override
  Uint8List pack() {
    var data = _buffer;
    if (data == null) {
      data = _pack();
      _buffer = data;
    }
    return data;
  }

  /// Build the wire bytes from scratch, in the fixed field order:
  ///
  /// ```
  /// magic(4) | type(1) | headerLen(1) | payloadLen(2)
  /// | [target(4) source(4)]     if B=1
  /// | [sn(4)]                   if D=1
  /// | [index(E) count(E)]       if E>0
  /// | [command(4)]              if C=1
  /// | payload(payloadLen)
  /// ```
  Uint8List _pack() {
    final type = calcType(ack: ack, bid: bid, cmd: cmd, dsn: dsn, ext: ext);
    final hLen = headerLength;
    final pLen = payloadLength;
    final b = BytesBuilder(copy: false);
    // MAGIC_CODE (4 bytes, big-endian)
    b.addUint32(MAGIC_CODE);
    // type (1)
    b.addUint8(type);
    // header length (1)
    b.addUint8(hLen);
    // payload length (2, big-endian)
    b.addUint16(pLen);
    // optional fields in fixed order
    if (bid != 0) {
      b.addUint32(target);
      b.addUint32(source);
    }
    if (dsn != 0) {
      b.addUint32(sn);
    }
    if (ext > 0) {
      _writeExt(b, index, ext);
      _writeExt(b, count, ext);
    }
    if (cmd != 0) {
      b.addUint32(command);
    }
    // payload
    if (pLen > 0) {
      b.add(payload);
    }
    return b.toBytes();
  }

  //
  //  byte helpers
  //

  /// Append [v] to [b] as a big-endian integer of [width] bytes.
  ///
  /// [v] is the integer value to append.
  /// [b] is the byte buffer being appended to.
  /// [width] is the field width (1, 2, 3 or 4; anything else fails the
  /// assert and falls back to 4).
  static void _writeExt(BytesBuilder b, int v, int width) {
    if (width == 1) {
      b.addUint8(v);
    } else if (width == 2) {
      b.addUint16(v);
    } else if (width == 3) {
      b.addUint24(v);
    } else {
      assert(width == 4, 'unsupported ext width: $width');
      b.addUint32(v);
    }
  }

}


extension _BigEndianIntegerWritter on BytesBuilder {

  /// big-endian uint32
  void addUint32(int v) {
    addByte((v >> 24) & 0xFF);
    addByte((v >> 16) & 0xFF);
    addByte((v >> 8) & 0xFF);
    addByte(v & 0xFF);
  }

  /// big-endian uint24
  void addUint24(int v) {
    addByte((v >> 16) & 0xFF);
    addByte((v >> 8) & 0xFF);
    addByte(v & 0xFF);
  }

  /// big-endian uint16
  void addUint16(int v) {
    addByte((v >> 8) & 0xFF);
    addByte(v & 0xFF);
  }

  /// Append [v] as a single big-endian byte (truncated to 8 bits).
  void addUint8(int v) {
    addByte(v & 0xFF);
  }

}
