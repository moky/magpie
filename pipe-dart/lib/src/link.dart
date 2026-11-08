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
import 'dart:io';
import 'dart:typed_data';

import 'package:magpie_bridge/magpie.dart';
import 'package:magpie_bridge/protocol.dart';

import 'utils/coding.dart';
import 'utils/config.dart';
import 'utils/enigma.dart';

import 'pipe.dart';

abstract interface class MagLink {

  bool get ready;

  void connect([DateTime? now]);

  void disconnect([DateTime? now]);

  void heartbeat([DateTime? now]);

  /// Called when received raw bytes from the peer.
  void received(Uint8List data);

  //
  //   Pipes
  //

  MagPipe? getPipe(int remote);

}

abstract class BaseLink implements MagLink {
  BaseLink(this.socket, this.remote, {required this.enigma});

  /// The bound local UDP socket.
  final RawDatagramSocket socket;

  /// The remote endpoint (peer's IP address + UDP port).
  final SocketAddress remote;

  /// The peer's IP address.
  InternetAddress get host => remote.host;

  /// The peer's UDP port.
  int get port => remote.port;

  /// The configuration (handshake parameters, etc.); the app loads
  /// values via `config.update({...})`.
  final Config config = Config();

  /// The enigma for the encrypted handshake: `decrypt` derives the AES
  /// key from the ikm stored under the key name carried by the "SYN!"
  /// reply.
  final Enigma enigma;

  /// The session secret bound after the "SYN!" (null = not yet);
  /// packets bound for the server are signed with it.
  Uint8List? secret;

  /// Time of the last outgoing datagram (refreshed by [send]: data,
  /// handshake waves and heartbeats all count).
  DateTime? lastSendTime;

  /// Time of the last incoming datagram (refreshed by [process]: PONG,
  /// COPY, data and system commands all count).
  DateTime? lastReceivedTime;

  DateTime? get lastActiveTime {
    final sent = lastSendTime;
    final received = lastReceivedTime;
    if (received == null) {
      return sent;
    } else if (sent == null) {
      return received;
    }
    return sent.isAfter(received) ? sent : received;
  }

  /// Outbound packets deferred while re-handshaking; signed and sent
  /// once the handshake completes.
  final List<Magpie> _pendingPackets = [];

  void drain() {
    final deferred = List.of(_pendingPackets);
    _pendingPackets.clear();
    for (var packet in deferred) {
      _send(packet);
    }
  }

  bool _send(Magpie packet) {
    final data = packet.pack();
    int size = socket.send(data, remote.host, remote.port);
    if (size != data.length) {
      return false;
    }
    lastSendTime = DateTime.now();
    return true;
  }

  bool sendPacket(Magpie packet, {
    bool encryptedMode = true,
  }) {
    if (encryptedMode) {
      final msgKey = secret;
      if (msgKey != null && packet is! ReliablePacket) {
        packet = (packet as BasePacket).sign(msgKey);
      }
    }
    final command = packet.command;
    // system command
    switch (command) {
      // handshake
      case Command.SYN:
      case Command.SYN_ACK:
      case Command.ACK:
      // results
      case Command.FAIL:
      case Command.DONE:
      // shutdown
      case Command.FIN:
      case Command.FIN_ACK:
      case Command.NOOP:
        return _send(packet);
    }
    // ACPT, DENY
    // DATA, COPY
    // PING, PONG
    // ...
    if (ready) {
      return _send(packet);
    } else if (command != Command.PING && command != Command.PONG) {
      // waiting for handshake
      _pendingPackets.add(packet);
    }
    return false;
  }

  @override
  void received(Uint8List data) {
    final packet = parse(data);
    if (packet == null) {
      return;  // silently drop malformed datagrams
    }
    // any valid datagram proves the path is alive
    lastReceivedTime = DateTime.now();
    processPacket(packet);
  }

  Packet? parse(Uint8List data);

  void processPacket(Packet packet);

  //
  //   Payload
  //

  // protected
  Map decodePayload(Uint8List payload) {
    final text = UTF8.decode(payload) ?? '{}';
    return JSONMap.decode(text) ?? {};
  }

  // protected
  Uint8List encodePayload(Map info) {
    final text = JSONMap.encode(info) ?? '';
    return UTF8.encode(text);
  }

  /// Pad the JSON body to at least [ServerConfig.handshakeMinPayload]
  /// bytes with a 'blah' field (docs/client.md 5.1): the value repeats
  /// 'blah' separated by spaces, so the padded body may exceed the
  /// minimum by up to 4 bytes.
  // protected
  Uint8List padPayload(Map<Object?, Object?> body) {
    var json = JSONMap.encode(body) ?? '';
    var padLen = config.handshakeMinPayload - (json.length + 10);  // + ',"blah":""'
    if (padLen > 0) {
      // k words joined by spaces take 5k-1 bytes; round up so the
      // body never falls below the minimum
      var words = (padLen + 5) ~/ 5;
      body['blah'] = List.filled(words, 'blah').join(' ');
      json = JSONMap.encode(body) ?? json;
    }
    return UTF8.encode(json);
  }

}
