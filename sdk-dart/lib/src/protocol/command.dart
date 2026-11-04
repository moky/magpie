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

// System command constants for Magpie Bridge.
//
// Each command is the ASCII bytes of its readable name packed big-endian
// (network byte order) into a 32-bit unsigned integer, e.g. "SYN?" = 0x53594E3F.
// Value 0 is reserved for the empty command (C=0, plain DATA).
// ignore_for_file: constant_identifier_names

/// Reserved system command values.
class Command {
  Command._();

  /// Handshake
  static const SYN     = 0x53594E3F; // "SYN?"
  static const SYN_ACK = 0x53594E21; // "SYN!"
  static const ACK     = 0x41434B21; // "ACK!"

  /// Result
  static const FAIL    = 0x4641494C; // "FAIL"
  static const DONE    = 0x444F4E45; // "DONE"

  /// Permit
  static const ACPT    = 0x41435054; // "ACPT"
  static const DENY    = 0x44454E59; // "DENY"

  /// Heartbeat
  static const PING    = 0x50494E47; // "PING"
  static const PONG    = 0x504F4E47; // "PONG"

  /// Shutdown
  static const FIN     = 0x46494E3F; // "FIN?"
  static const FIN_ACK = 0x46494E21; // "FIN!"

  static const NOOP    = 0x4E4F4F50; // "NOOP"

  /// Data
  static const DATA    = 0x44415441; // "DATA"
  static const COPY    = 0x434F5059; // "COPY"

  static const EMPTY   = 0x00000000; // empty command: C=0, same meaning as "DATA"
}
