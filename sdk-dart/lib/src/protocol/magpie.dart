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

/*
     0                   1                   2                   3
     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |      'M'      |      'P'      |     '\0'      |     '\1'      |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |      type     | header length |        payload length         |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                        target bridge id                       |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                        source bridge id                       |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                       data serial number                      |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |           data index          |           data count          |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                            command                            |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 */

/// Core message interface. Every packet on the wire is a [Magpie].
/// All properties are read-only.
abstract interface class Magpie {

  /// Target bridge id (0 = addressed to the server).
  int get target;

  /// Source bridge id (0 = first handshake / server-down).
  int get source;

  /// Data serial number (0 for system commands).
  int get sn;

  /// Fragment index (0 for mini packets).
  int get index;

  /// Fragment count (1 for mini packets).
  int get count;

  /// Command value (0 = empty command, plain DATA).
  int get command;

  /// Payload bytes (empty for none).
  Uint8List get payload;

  /// Pack this packet into the wire bytes (header + payload, + attachment
  /// for a ReliablePacket).
  Uint8List pack();
}

/*
      0   1   2   3   4   5   6   7
    +---+---+---+---+---+---+---+---+
    | A | B | C | D |   |           |
    | C | I | M | S |   |  EXT LEN  |
    | K | D | D | N |   |           |
    +---+---+---+---+---+---+---+---+
 */

/// A [Magpie] whose header-level flags (A/B/C/D/E) and the two lengths
/// are visible; this is the shape [MessagePacket] implements.
abstract interface class Packet implements Magpie {

  /// A (0x80): 1 = reply to the peer's request.
  int get ack;

  /// B (0x40): 1 = bridge packet (carries target/source bids).
  int get bid;

  /// C (0x20): 1 = carries a [command]; 0 = plain DATA.
  int get cmd;

  /// D (0x10): 1 = carries an [sn]; 0 = system command.
  int get dsn;

  /// E (0x07): byte width of the index/count fields (0/2/4).
  int get ext;

  /// Full header length in bytes, `buffer[5]` (8 ~ 32).
  int get headerLength;

  /// Payload length in bytes, `buffer[6] << 8 | buffer[7]`.
  int get payloadLength;

}

/// Human-readable one-line dump shared by all packet classes.
///
/// [HumanReadablePacket] is mixed into `MessagePacket` and `BasePacket`,
/// so every concrete packet (`BridgePacket`, `DirectPacket` and
/// `ReliablePacket` included) renders itself as a single line via
/// [toString]: the class name, the set flags (A/B/C/D and the E width),
/// then the optional header fields that actually exist on the wire,
/// ending with the byte sizes.
mixin HumanReadablePacket implements Packet {

  /// Class name shown by [toString]: the actual runtime type when asserts
  /// are enabled (debug builds), or the fixed `'MagpiePacket'` otherwise.
  String get className {
    String name = 'MagpiePacket';
    assert(() {
      name = runtimeType.toString();
      return true;
    }());
    return name;
  }

  /// Total size of the bare packet in bytes: header plus payload.
  ///
  /// Subclasses may refine it — e.g. `ReliablePacket` counts the
  /// 32-byte attachment as well.
  int get length => headerLength + payloadLength;

  /// One-line dump, e.g.
  /// `ReliablePacket{BID,CMD,EXT=0; target=0, source=123, command=0x50494e47, header=20B, payload=1B, packet=53B}`.
  ///
  /// The flags block stays compact and is closed by a semicolon; each
  /// optional field is separated by a comma and a space.
  @override
  String toString() {
    final sb = StringBuffer('$className{');
    if (ack == 1) sb.write('ACK,');
    if (bid == 1) sb.write('BID,');
    if (cmd == 1) sb.write('CMD,');
    if (dsn == 1) sb.write('DSN,');
    sb.write('EXT=$ext;');
    if (bid == 1) sb.write(' target=$target, source=$source,');
    if (dsn == 1) sb.write(' sn=$sn,');
    if (ext != 0) sb.write(' index=$index/$count,');
    if (cmd == 1) sb.write(' command=0x${command.toRadixString(16)},');
    sb.write(' header=${headerLength}B,');
    sb.write(' payload=${payloadLength}B,');
    sb.write(' packet=${length}B}');
    return sb.toString();
  }
}
