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

/// Configuration for the Magpie Bridge pipe transport.
///
/// The values are keyed by the server's terminology (snake_case), e.g.
/// `{"heartbeat_interval": 10.0}`; the typed getters fall back to the
/// defaults documented in docs/client.md when a value is missing.
class Config {
  /// Internal config values, keyed by server terminology.
  final Map<String, dynamic> _values = {};

  /// Update the config: entries in [config] are added, replacing
  /// existing entries with the same name; other entries are kept.
  void update(Map<String, dynamic> config) => _values.addAll(config);

  // protected
  /// Get an integer value by [key], falling back to [defaultValue]
  /// when the value is missing or not a number.
  int getInt(String key, int defaultValue) {
    final value = _values[key];
    return value is num ? value.toInt() : defaultValue;
  }

  // protected
  /// Get a double value by [key], falling back to [defaultValue]
  /// when the value is missing or not a number.
  double getDouble(String key, double defaultValue) {
    final value = _values[key];
    return value is num ? value.toDouble() : defaultValue;
  }

  /// The minimum "SYN?" / "ACK!" payload size (docs/client.md 5.1):
  /// shorter handshake payloads are dropped by the server.
  int get handshakeMinPayload => getInt('handshake_min_payload', 512);

  /// The idle threshold H in seconds (docs/client.md §6): send a
  /// heartbeat only when neither direction has seen traffic for longer
  /// than this; LANs without NAT may raise it to 60 seconds.
  double get heartbeatInterval => getDouble('heartbeat_interval', 10.0);

  /// The handshake retry interval in seconds (docs/workflow.md §2.3):
  /// while the handshake is unfinished, re-send the "SYN?" at most once
  /// per this; must be shorter than [heartbeatInterval].
  double get handshakeInterval => getDouble('handshake_interval', 3.0);

  /// Max "SYN?" retries before giving up (docs/workflow.md §2.3): the
  /// link goes quiet afterwards and stays not-ready; the app decides
  /// whether to drop it.
  int get handshakeRetryLimit => getInt('handshake_retry_limit', 5);

  /// The upper bound for a link's deferred-packet queue: while the
  /// handshake is still in progress, further packets are dropped
  /// (sendPacket returns false) when the queue is full.
  int get maxPendingPackets => getInt('max_pending_packets', 256);

  /// The record active timeout D in seconds (docs/client.md §6, §8):
  /// when no packet has been received for longer than this, the server
  /// record is likely gone - clean up the pipes and re-handshake;
  /// synchronized with the server's active timeout (60 seconds).
  double get recordActiveTimeout => getDouble('record_active_timeout', 60.0);
}

typedef SocketAddress = ({
  InternetAddress host,
  int port,
});
