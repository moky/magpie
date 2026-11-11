/*
 * Copyright (c) 2026, Albert Moky. All rights reserved.
 * Use of this source code is governed by a MIT-style license
 * that can be found in the LICENSE file.
 */
import 'package:magpie_bridge/protocol.dart';

/// Human-readable name for a command value, or hex for unknown.
String commandName(int command) {
  switch (command) {
    case Command.SYN:
      return 'SYN?';
    case Command.SYN_ACK:
      return 'SYN!';
    case Command.ACK:
      return 'ACK!';
    case Command.FAIL:
      return 'FAIL';
    case Command.DONE:
      return 'DONE';
    case Command.ACPT:
      return 'ACPT';
    case Command.DENY:
      return 'DENY';
    case Command.PING:
      return 'PING';
    case Command.PONG:
      return 'PONG';
    case Command.FIN:
      return 'FIN?';
    case Command.FIN_ACK:
      return 'FIN!';
    case Command.NOOP:
      return 'NOOP';
    case Command.DATA:
      return 'DATA';
    case Command.COPY:
      return 'COPY';
    case Command.EMPTY:
      return '""';
  }
  return '0x${command.toRadixString(16)}';
}

/// Pretty-print any packet (flags, ids, ranges, command, payload size).
extension HumanReadable on Packet {

  /// One-line human-readable dump, e.g.
  /// `Magpie{BID,target=100, source=200, sn=42, payload=5B}`.
  String toHumanReadableString() {
    final sb = StringBuffer('Magpie{');
    if (ack == 1) sb.write('ACK,');
    if (bid == 1) sb.write('BID,');
    if (cmd == 1) sb.write('CMD,');
    if (dsn == 1) sb.write('DSN,');
    sb.write('E=$ext');
    if (bid == 1) sb.write(', target=$target, source=$source');
    if (dsn == 1) sb.write(', sn=$sn');
    if (ext  > 0) sb.write(', index=$index/$count');
    if (cmd == 1) sb.write(', command=${commandName(command)}');
    sb.write(', payload=${payloadLength}B}');
    return sb.toString();
  }
}
