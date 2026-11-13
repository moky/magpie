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
import 'package:magpie_bridge/protocol.dart';

import 'bridge.dart';
import 'direct.dart';
import 'link.dart';
import 'pipe.dart';

/// Factory: builds pipes and wires the app's observer.
///
/// The default implementations build plain pipes; applications with
/// special needs extend this class and override `createXxx`.
class PipeFactory {

  DirectPipe createDirectPipe(DirectLink conn) => DirectPipe(conn);

  BridgePipe createBridgePipe(BridgeLink conn, {
    required int target,
    required int source,
  }) => BridgePipe(conn, target: target, source: source);

}

/// The app layer's observer: receives every packet received through
/// the link (docs/client.md §4.2).
///
/// [pipe] is the pipe the packet is routed to - null for packets
/// arriving before the pipe exists (e.g. handshake waves); [link] is
/// always the link the packet arrived on.
abstract interface class MagpieDelegate {

  /// Handle one packet received through the link.
  void onPacketReceived(Packet packet, MagPipe? pipe, MagLink link);

  /// Called for every packet that reaches the wire: handshake waves,
  /// PONG/COPY replies and app data alike.
  void onPacketSent(Magpie packet, MagPipe? pipe, MagLink link);

  /// Called when a packet could not be sent: dropped (queue full), or
  /// a socket error occurred.
  void onPacketFailed(Magpie packet, MagPipe? pipe, MagLink link);

}

/// The extension points of the pipe layer: the app plugs its
/// [PipeFactory] and [MagpieDelegate] here before creating the hub.
class MagpieExtensions {
  factory MagpieExtensions() => _instance;
  static final MagpieExtensions _instance = MagpieExtensions._internal();
  MagpieExtensions._internal();

  /// Builds the pipes for the links (null = pipes are disabled).
  PipeFactory? pipeFactory;

  /// Observes every packet received through the links.
  MagpieDelegate? delegate;

}

/// The shared singleton of [MagpieExtensions].
final sharedMagpieExtensions = MagpieExtensions();
