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

import 'package:magpie_bridge/protocol.dart';

import 'utils/config.dart';

/// Pipe: processes data packets forwarded by the MagLink.
///
/// The application inherits this class and overrides [MagPipe.processPacket]
/// to implement its own receiving logic (dedup by sn, fragment reassembly
/// and delivery of the payload, docs/client.md §4.2).
abstract interface class MagPipe {

  /// Handle one data packet forwarded by the link: the default
  /// implementation answers "COPY" to data packets (A=0, D=1) and
  /// "PONG" to heartbeats.
  void processPacket(Packet packet);

  /// Pack and send the datagram through the link: it is signed with
  /// the session secret when bound, and deferred while the handshake
  /// is still in progress.
  bool sendPacket(Magpie packet);

  /// Build a data packet (A=0, D=1, sn/index/count for the reliability
  /// layer) and send it through the link.
  bool sendData(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  });

}

/// Link: one connection over the shared UDP socket - to the relay
/// server (B=1) or directly to a peer (B=0).
///
/// The application drives the link through the lifecycle calls
/// ([connect], [heartbeat], [disconnect]) on its own schedule, and
/// observes every packet through [MagpieDelegate].
abstract interface class MagLink {

  /// The remote endpoint of this connection (IP address + UDP port):
  /// the relay server for a bridge link, the peer for a direct link.
  SocketAddress get remoteAddress;

  /// The local address as observed by the peer, carried in the "UDP"
  /// field of the "SYN!" payload (bridge: docs/client.md §5.1,
  /// direct: docs/workflow.md §2.3); null until the handshake
  /// delivers it.
  String? get observedAddress;

  /// Whether the three-way handshake has completed: only then are data
  /// packets sent and received (pre-ready sends are deferred).
  bool get ready;

  /// Dial the remote endpoint: send the "SYN?" (bridge) or "SYN?"
  /// wave (direct) to start the three-way handshake.
  void connect([DateTime? now]);

  /// Close the connection: send the "FIN?" wave to the relay server
  /// (bridge: no-op without a bound bid) or peer (direct: stateless,
  /// always sent).
  void disconnect([DateTime? now]);

  /// Idle-triggered heartbeat: send a "PING" when neither direction
  /// has seen traffic for longer than the heartbeat interval.
  void heartbeat([DateTime? now]);

  /// Called when received raw bytes from the peer.
  void received(Uint8List data);

  /// Pack and send the datagram to the remote endpoint, refreshing
  /// the last-send time for the heartbeat idle check. Data commands
  /// sent while the handshake is still in progress are deferred to
  /// [_pendingPackets] (bounded by [Config.maxPendingPackets]).
  bool sendPacket(Magpie packet, {
    bool encryptedMode = true,
  });

  //
  //   Pipes
  //

  /// The pipe bound to the remote bid: for a bridge link, [remote] is
  /// the peer's bid (0 = the server itself); for a direct link, the
  /// single pipe to the peer.
  MagPipe? getPipe(int remote);

}

/// The app layer's observer: receives every packet received through
/// the link (docs/client.md §4.2).
///
/// [pipe] is the pipe the packet is routed to - null for packets
/// arriving before the pipe exists (e.g. handshake waves); [link] is
/// always the link the packet arrived on.
abstract interface class MagpieDelegate {

  /// Handle one packet received through the link.
  ///
  /// Note for "FAIL" handling (docs/protocol.md §5.1): once the session
  /// secret is bound, [parse] already verifies every signed packet
  /// before it reaches this callback, so `packet is ReliablePacket` is
  /// a valid authenticity check; an unsigned "FAIL" may as well be
  /// forged - keep the handling idempotent and discern by the payload:
  ///
  /// ```dart
  /// if (packet.command == Command.FAIL) {
  ///     final info = JSONMap.decode(UTF8.decode(packet.payload)!) ?? {};
  ///     final signed = packet is ReliablePacket; // verified by the link
  ///     if (info['src-target'] != null) {
  ///         // peer offline: trust the hint only when signed
  ///     } else if (info['sources'] != null) {
  ///         // permit failed: trust the hint only when signed
  ///     } else if (info['src-command'] != null) {
  ///         // connection unconfirmed: the link resends "ACK!" itself
  ///     } else {
  ///         // bid allocation failed: re-request or give up
  ///     }
  /// }
  /// ```
  void onPacketReceived(Packet packet, MagPipe? pipe, MagLink link);

  /// Called for every packet that reaches the wire: handshake waves,
  /// PONG/COPY replies and app data alike.
  void onPacketSent(Magpie packet, MagPipe? pipe, MagLink link);

  /// Called when a packet could not be sent: dropped (queue full), or
  /// a socket error occurred.
  void onPacketFailed(Magpie packet, MagPipe? pipe, MagLink link);

}
