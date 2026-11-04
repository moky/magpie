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

// Magpie Bridge protocol constants and header calculations.
// See docs/protocol.md for the wire format.
// ignore_for_file: constant_identifier_names

/// Magic Code: 'M', 'P', '\0', '\1' (Messaging Protocol v1).
const int MAGIC_CODE = 0x4D500001;

//
//  Size limits.
//

/// Fixed header size: magic(4) + type(1) + headerLen(1) + payloadLen(2).
const int MIN_HEADER_LENGTH = 8;

/// Maximum header size (all optional fields present, E=4).
const int MAX_HEADER_LENGTH = 32;

/// Suggested payload cap on the sender side (bytes).
const int MAX_PAYLOAD_LENGTH = 1024;

/// Attachment length: HMAC-SHA256, 32 bytes.
const int ATTACHMENT_LENGTH = 32;

/// Max datagram size (IPv6 minimum MTU 1280 - 40 ipv6 header - 8 udp header)
/// MSS hard cap: header + payload (+ attachment) <= 1232.
const int MSS = 1232;

//
//  Calculations
//

/// Compose the type byte: A(7) B(6) C(5) D(4) E(low 3 bits).
///
/// [ack] is the reply flag.
/// [bid] is the bridge flag.
/// [cmd] is the command presence flag.
/// [dsn] is the data serial number flag (D).
/// [ext] is the fragment parameter width (E, 0 ~ 4).
int calcType({
  required int ack,
  required int bid,
  required int cmd,
  required int dsn,
  required int ext,
}) =>
    ((ack & 1) << 7) | ((bid & 1) << 6) | ((cmd & 1) << 5) |
    ((dsn & 1) << 4) | (ext & 0x07);

/// Header length: N = 8 + 8·B + 4·D + 2·E + 4·C.
///
/// [bid] is the bridge flag.
/// [cmd] is the command presence flag.
/// [dsn] is the data serial number flag (D).
/// [ext] is the fragment parameter width (E).
int calcHeaderLength({
  required int bid,
  required int cmd,
  required int dsn,
  required int ext,
}) => MIN_HEADER_LENGTH + 8 * (bid & 1) + 4 * (dsn & 1) + 2 * ext + 4 * (cmd & 1);

/// C flag: command == 0 => C=0 (plain DATA).
int calcCmd(int command) => command == 0 ? 0 : 1;

/// D flag: sn == 0 => D=0 (system command).
int calcDsn(int sn) => sn == 0 ? 0 : 1;

/// E width: count >= 65536 => 4; count >= 2 => 2; else 0.
int calcExt(int count) {
  if (count >= 65536) {
    return 4;
  } else if (count >= 2) {
    return 2;
  }
  assert(count == 1, 'packet count error: $count');
  return 0;
}
