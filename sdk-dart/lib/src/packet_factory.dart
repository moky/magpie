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

import 'packet.dart';

/// Validate a raw datagram and decode its header fields.
class MessagePacketFactory {
  const MessagePacketFactory();

  /// Validate a raw datagram and decode its header fields.
  ///
  /// [buffer] is the raw UDP datagram to validate.
  ///
  /// Shared by [BridgePacketFactory] and DirectPacketFactory: performs the
  /// magic-code check, E-width range, header-length formula and per-field
  /// bounds. Returns null on any violation. The caller then applies the
  /// B-bit filter and the tail (attachment) rule.
  Packet? parse(Uint8List buffer) {
    if (buffer.length < MIN_HEADER_LENGTH) {
      // UDP datagram must hold at least the fixed 8-byte prefix.
      return null;
    } else if (buffer.length > MSS) {
      // MSS hard cap: header + payload (+ attachment) <= 1232.
      return null;
    }

    // 1. Magic code.
    if (buffer.readUint32(0) != MAGIC_CODE) {
      return null;
    }

    // 2. Type byte.
    final type = buffer.readUint8(4);
    final hLen = buffer.readUint8(5);
    final pLen = buffer.readUint16(6);  // 2 bytes, big-endian

    // flags
    final ack = (type >> 7) & 0x01;
    final bid = (type >> 6) & 0x01;
    final cmd = (type >> 5) & 0x01;
    final dsn = (type >> 4) & 0x01;
    final ext = type & 0x07;

    // E must be 0..4 (5/6/7 are invalid); E>0 requires D=1.
    if (ext > 4) {
      return null;
    } else if (ext > 0 && dsn == 0) {
      return null;
    }

    // Header length must match the formula.
    if (hLen != calcHeaderLength(bid: bid, cmd: cmd, dsn: dsn, ext: ext)) {
      return null;
    }

    // tail < 0: the datagram cannot even hold the declared header + payload.
    // Check before reading the variable-length fields below, otherwise a
    // truncated packet with a long declared header throws RangeError instead
    // of being silently dropped (300:195-201).
    final size = hLen + pLen;
    final tail = buffer.length - size;
    if (tail == ATTACHMENT_LENGTH) {
      // cut the tail here
      buffer = Uint8List.fromList(buffer.sublist(0, size));
    } else if (tail != 0) {
      assert(false, 'UDP packet error: ${buffer.length} bytes,'
          ' header_length=$hLen, payload_length=$pLen, tail=$tail');
      return null;
    }

    // 3. Read header fields and validate them.
    var target = 0, source = 0;
    var sn = 0, index = 0, count = 1;
    var command = 0;

    var offset = MIN_HEADER_LENGTH;
    if (bid != 0) {
      target = buffer.readUint32(offset);
      offset += 4;
      source = buffer.readUint32(offset);
      offset += 4;
    }
    if (dsn != 0) {
      sn = buffer.readUint32(offset);
      offset += 4;
      if (sn == 0) {
        // D=1 implies sn != 0.
        return null;
      }
    }
    if (ext > 0) {
      index = _readExt(buffer, offset, ext);
      offset += ext;
      count = _readExt(buffer, offset, ext);
      offset += ext;
      if (index >= count || count < 2) {
        // 0 <= index < count; count must be > 1 when E>0.
        return null;
      }
    }
    if (cmd != 0) {
      command = buffer.readUint32(offset);
      offset += 4;
      if (command == 0) {
        // C=1 implies command != 0.
        return null;
      }
    }

    // Tail: attachment decision.
    final payload = pLen > 0
        ? Uint8List.fromList(buffer.sublist(hLen, size))
        : Uint8List(0);

    return MessagePacket(buffer,
      ack: ack,
      bid: bid,
      cmd: cmd,
      dsn: dsn,
      ext: ext,
      headerLength: hLen,
      payloadLength: pLen,
      target: target,
      source: source,
      sn: sn,
      index: index,
      count: count,
      command: command,
      payload: payload,
    );
  }

  //
  //  byte helpers
  //

  /// Read a big-endian unsigned integer of [width] bytes at [off].
  ///
  /// [d] is the datagram buffer.
  /// [off] is the field offset.
  /// [width] is the field width (1, 2, 3 or 4; anything else fails the
  /// assert and falls back to 4).
  static int _readExt(Uint8List d, int off, int width) {
    if (width == 1) {
      return d.readUint8(off);
    } else if (width == 2) {
      return d.readUint16(off);
    } else if (width == 3) {
      return d.readUint24(off);
    } else {
      assert(width == 4, 'unsupported ext width: $width');
      return d.readUint32(off);
    }
  }

}


extension _BigEndianIntegerReader on Uint8List {

  /// Read a big-endian uint32 at [p] (always returns a non-negative value).
  int readUint32(int p) {
    final value = (this[p] << 24) | (this[p + 1] << 16) | (this[p + 2] << 8) | this[p + 3];
    return value & 0xFFFFFFFF;
  }

  /// Read a big-endian uint24 at [p].
  int readUint24(int p) {
    final value = (this[p] << 16) | (this[p + 1] << 8) | this[p + 2];
    return value & 0xFFFFFF;
  }

  /// Read a big-endian uint16 at [p].
  int readUint16(int p) {
    final value = (this[p] << 8) | this[p + 1];
    return value & 0xFFFF;
  }

  /// Read a single unsigned byte at [p].
  int readUint8(int p) => this[p] & 0xFF;

}
