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

import 'package:magpie_bridge/magpie.dart';
import 'package:magpie_bridge/protocol.dart';
import 'package:magpie_bridge/factory.dart';

import 'utils/coding.dart';
import 'utils/enigma.dart';
import 'utils/payload.dart';

import 'link.dart';
import 'pipe.dart';

/// Link to the relay server (B=1): handshake waves and system
/// command handling are implemented; data packets are answered with
/// "COPY" and handed to the pipe of the source peer.
class BridgeLink extends BaseLink with PayloadMixIn {
  BridgeLink(super.socket, super.remote, {required super.enigma});

  /// The bid assigned by the server after the handshake (0 = not yet).
  int bid = 0;

  /// The client's public address as observed by the server (the "UDP"
  /// field of the "SYN!" payload, for direct-connection probing,
  /// docs/client.md §5.1); null until the handshake delivers it.
  String? localAddress;

  final packetFactory = BridgePacketFactory();

  /// The bridge pipes for data exchange, keyed by the peer's bid.
  final Map<int, BridgePipe> _bridgePipes = {};

  /// The pipe to the server itself (bid 0): (re)created on every
  /// handshake completion, so PONG/FAIL/DONE have a pipe right away.
  BridgePipe? _serverPipe;

  /// "Allow all" flag enabled by `accept([1, 2, 3])`: data from any bid
  /// is accepted (docs/protocol.md §6.2).
  bool _allowAll = false;

  /// The last "ACK!" packet, kept for the idempotent resend when the
  /// server reports the connection unconfirmed (docs/client.md §4.3).
  Magpie? _lastAck;

  /// The time of the last "ACK!" resend: rate-limits the idempotent
  /// resends against FAIL floods (docs/client.md §4.3).
  DateTime? _lastAckResend;

  @override
  bool ready = false;

  /// Send a "SYN?" handshake to the server: ask for a bridge id.
  ///
  /// The payload is `{"time": ..., "enigmas": [...], "blah": ...}`,
  /// padded to at least `handshake_min_payload` bytes; the key names are
  /// announced so the server can pick one for the encrypted handshake
  /// (docs/client.md §5.2).
  @override
  void connect([DateTime? now]) {
    now ??= DateTime.now();
    final request = {
      'enigmas': enigma.keyNames,
      'time': now.millisecondsSinceEpoch / 1000.0,
    };
    // "SYN?" carries no attachment, even when re-handshaking with a
    // stale secret bound (docs/protocol.md §5.1)
    sendPacket(packetFactory.syn(
      padPayload(request, config: config),
      source: 0,
    ), encryptedMode: false);
  }

  /// Send a "FIN?" wave to the server: close the bridge connection.
  @override
  void disconnect([DateTime? now]) {
    ready = false;
    final source = bid;
    if (source == 0) {
      return;
    }
    now ??= DateTime.now();
    final request = {
      'time': now.millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.fin(
      encodePayload(request),
      source: source,
    ));
  }

  /// Clean up the stale session and restart the handshake: the run loop
  /// calls this when the link is disconnected (no packet received for
  /// D = `Config.recordActiveTimeout`, docs/client.md §8) - the server
  /// record is likely gone, so the client applies for a bid again.
  void reconnect([DateTime? now]) {
    // clean up the stale session: pipes and permits died with the
    // server record
    ready = false;
    bid = 0;
    secret = null;
    _bridgePipes.clear();
    _serverPipe = null;
    _allowAll = false;
    _lastAck = null;
    _lastAckResend = null;
    // restart the handshake
    connect(now);
  }

  /// Idle-triggered heartbeat (docs/client.md §6): when no datagram has
  /// been sent or received for [Config.heartbeatInterval], send a "PING"
  /// with the payload `{"time": ...}`.
  ///
  /// The ping is signed with the session [secret] when bound (the server
  /// answers "PONG" to verified pings only, echoing the payload back with
  /// a fresh "time"). PONGs are neither awaited nor retransmitted: the
  /// outgoing ping itself already resets the NAT mapping.
  @override
  void heartbeat([DateTime? now]) {
    final source = bid;
    if (source == 0) {
      // not handshake yet
      return;
    } else if (!ready) {
      // closed
      return;
    }
    now ??= DateTime.now();
    if (!needsHeartbeat(now)) {
      return;
    }
    final request = {
      'time': now.millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.ping(
      encodePayload(request),
      source: source,
    ));
  }

  /// Handle the "SYN!" reply (docs/client.md 5.1/5.2): save the assigned
  /// bid, decrypt the session secret and answer "ACK!".
  ///
  /// The "SYN!" payload is `{"secret": ..., "token": ..., "time": ...,
  /// "UDP": ...}` plus an 'enigma' bundle in encrypted mode; both
  /// 'secret' and 'token' are required. The "ACK!" echoes the handshake
  /// parameters back, padded to the handshake minimum. After it, the
  /// link is [ready] (bid bound, session secret saved).
  void _handleSynAck(Magpie packet) {
    final target = packet.target;
    if (target == 0) {
      assert(false, 'SYN_ACK packet error: $packet');
      return;
    }
    final info = decodePayload(packet.payload);
    final secretB64 = info['secret'];
    final token = info['token'];
    if (secretB64 is! String || token is! String) {
      return;  // malformed: both 'secret' and 'token' are required
    }
    // the assigned bid travels in the packet header
    bid = target;
    // the server-observed address of this socket, for direct probing
    final udp = info['UDP'];
    if (udp is String) {
      localAddress = udp;
    }
    // session key: plain mode carries it base64-encoded; encrypted mode
    // wraps it in an 'enigma' bundle
    Uint8List? messageKey;
    final bundle = info['enigma'];
    if (bundle is Map) {
      final enc = HkdfEnc.parse(bundle, bid: bid);
      messageKey = enc == null ? null : enigma.decryptSecret(secretB64, enc);
    } else {
      assert(bundle == null, 'enigma bundle error: $bundle');
      messageKey = Base64.decode(secretB64);
    }
    if (messageKey == null) {
      // key mismatch or tampered handshake
      assert(false, 'decryption failed: $packet');
      return;
    }
    secret = messageKey;

    // answer "ACK!": the handshake parameters echo back as-is
    final request = {
      'enigma': bundle,
      'secret': secretB64,
      'token': token,
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    final ack = packetFactory.ack(
      padPayload(request, config: config),
      source: target,
    );
    _lastAck = ack;
    sendPacket(ack, encryptedMode: bundle is Map);
    ready = true;
    // the pipe to the server itself (bid 0): (re)created on every
    // handshake completion, so PONG/FAIL/DONE have a pipe right away
    _serverPipe = _newPipe(0);

    // flush the packets deferred while re-handshaking
    drain();
  }

  /// Answer "NOOP" to an unexpected "FIN!": refresh the server's
  /// NOOP-immunity window and resume the online state without a new
  /// handshake (docs/workflow.md §3.1); this is not a heartbeat.
  void _handleFinAck(Magpie packet) {
    final source = bid;
    if (source == 0 || !ready) {
      // not handshake yet
      return;
    }
    // unexpected "FIN!" (kicked by a forged "FIN?" attack): answer
    // "NOOP" at once to refresh the immunity window and stay online
    // (docs/workflow.md §3.1)
    final request = {
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    sendPacket(packetFactory.noop(
      encodePayload(request),
      source: source,
    ));
  }

  /// Handle the "FAIL" reply (docs/client.md §4.3), identified by the
  /// payload fields: only "time" - bid allocation failed (the upper
  /// layer decides to re-request); "src-command" only - the connection
  /// is unconfirmed, resend the last "ACK!" (idempotent, the token is
  /// still valid for a while); "src-target"/"sources" - forwarded to
  /// the pipe for the upper layer to handle.
  void _handleFail(Magpie packet) {
    final info = decodePayload(packet.payload);
    if (info['src-command'] == null) {
      return;  // bid allocation failed: upper layer decides
    }
    if (info['src-target'] != null || info['sources'] != null) {
      return;  // peer offline / permit failure: upper layer decides
    }
    // connection unconfirmed: resend "ACK!" (idempotent), at most once
    // per second against FAIL floods
    final now = DateTime.now();
    final lastResend = _lastAckResend;
    if (lastResend != null &&
        now.difference(lastResend) < const Duration(seconds: 1)) {
      return;
    }
    _lastAckResend = now;
    final ack = _lastAck;
    if (ack != null) {
      sendPacket(ack);
    }
  }

  /// Accept data from the bids in [sources]: add bridge permits
  /// (docs/protocol.md §6.2). The strictly ordered [1, 2, 3] clears all
  /// permits and enables the wildcard. While re-handshaking, the packet
  /// is deferred and sent once [ready].
  void accept(List<int> sources) {
    bool ok = _permit(Command.ACPT, sources);
    if (!ok) {
      return;
    } else if (_isStar(sources)) {
      // star marker: atomic clear (+ wildcard for "ACPT *")
      _bridgePipes.clear();
      _allowAll = true;
      return;
    }
    for (var remote in sources) {
      final pipe = _newPipe(remote);
      if (pipe == null) {
        // no pipe factory registered
        assert(false, 'PipeFactory is not registered');
        return;
      }
      _bridgePipes[remote] = pipe;
    }
  }

  /// Deny data from the bids in [sources]: remove bridge permits
  /// (docs/protocol.md §6.2). The strictly ordered [1, 2, 3] exits the
  /// wildcard. While re-handshaking, the packet is deferred and sent
  /// once [ready].
  void deny(List<int> sources) {
    bool ok = _permit(Command.DENY, sources);
    if (!ok) {
      return;
    } else if (_isStar(sources)) {
      // star marker: atomic clear (+ wildcard for "DENY *")
      _bridgePipes.clear();
      _allowAll = false;
      return;
    }
    for (var remote in sources) {
      _bridgePipes.remove(remote);
    }
  }

  /// Send an "ACPT"/"DENY" permit command with the [sources] list: the
  /// pipes are updated at once (the bid is known), while the packet is
  /// deferred when a re-handshake is still in progress (it is signed and
  /// sent once [ready]).
  bool _permit(int command, List<int> sources) {
    final local = bid;
    if (local == 0) {
      // first handshake not done yet: no bid to permit with
      return false;
    }
    final request = {
      'sources': sources,
      'time': DateTime.now().millisecondsSinceEpoch / 1000.0,
    };
    final packet = command == Command.ACPT
        ? packetFactory.acpt(encodePayload(request), source: local)
        : packetFactory.deny(encodePayload(request), source: local);
    sendPacket(packet);
    return true;
  }

  /// The strictly ordered star marker `[1, 2, 3]`: "ACPT *" / "DENY *"
  /// (docs/protocol.md §6.2).
  bool _isStar(List<int> sources) => sources.length == PERMIT_ALL.length
      && sources[0] == PERMIT_ALL[0]
      && sources[1] == PERMIT_ALL[1]
      && sources[2] == PERMIT_ALL[2];

  /// wildcard
  // ignore: non_constant_identifier_names
  static final List<int> PERMIT_ALL = [1, 2, 3];

  /// Build a pipe for the peer [remote] bound to this connection: the
  /// application must plug a custom [PipeFactory] via [PipeExtensions].
  BridgePipe? _newPipe(int remote) {
    final pipeFactory = sharedPipeExtensions.pipeFactory;
    return pipeFactory?.createBridgePipe(this, remote: remote, local: bid);
  }

  @override
  Packet? parse(Uint8List data) {
    final packet = packetFactory.parse(data);
    if (packet == null) {
      return null;  // silently drop malformed datagrams
    } else if (packet.bid != 1) {
      return null;  // forged source: not for this connection
    }
    final command = packet.command;
    if (command == Command.SYN_ACK) {
      // ignore attachment for "SYN!" handshake packet
      return packet;
    }
    // verification: downlink packets must carry a valid attachment once
    // the session secret is bound, forged ones are silently dropped
    // (docs/protocol.md §5.1); an unsigned "FAIL" is still allowed when
    // the server lost the record (restart / record purge)
    final msgKey = secret;
    if (msgKey == null) {
      // not handshook yet: nothing to verify with
      return packet;
    } else if (packet is ReliablePacket) {
      // signed packet: accept only when the HMAC checks out
      if (packet.verify(msgKey)) {
        return packet;
      }
    } else if (command == Command.FAIL) {
      // unsigned "FAIL": sent without attachment when the server holds
      // no record for this socket (restart / record purge)
      return packet;
    }
    // forged: HMAC mismatch, or a required attachment is missing
    assert(false, 'verify failed: $packet');
    return null;
  }

  @override
  void processPacket(Packet packet) {
    switch (packet.command) {
      case Command.SYN_ACK:
        _handleSynAck(packet);
        return;
      case Command.FIN_ACK:
        _handleFinAck(packet);
        return;
      case Command.FAIL:
        // "connection unconfirmed": resend the last "ACK!" (idempotent);
        // everything else is routed to the pipe for the upper layer
        _handleFail(packet);
        break;
    }
    // hand FAIL/DONE/DATA/COPY/PONG to the pipe: dequeue the sending
    // queue on COPY, fail it on FAIL, merge fragments on DATA, measure
    // RTT on PONG, etc.
    final pipe = getPipe(packet.source);
    pipe?.processPacket(packet);
  }

  @override
  MagPipe? getPipe(int remote) {
    // remote == 0: the server itself (PONG/FAIL/DONE come from it)
    if (remote == 0) {
      return _serverPipe;
    }
    var pipe = _bridgePipes[remote];
    if (pipe == null && _allowAll) {
      pipe = _newPipe(remote);
      if (pipe != null) {
        _bridgePipes[remote] = pipe;
      }
    }
    return pipe;
  }

  /// Whether no packet has been received for D = `record_active_timeout`
  /// (docs/client.md §6): the server record is likely gone, the manager
  /// should clean up the pipes and re-handshake, or switch to another
  /// server.
  bool get disconnected {
    if (!ready) {
      return false;
    }
    final lastReceived = lastReceivedTime;
    if (lastReceived == null) {
      return false;
    }
    return DateTime.now().difference(lastReceived) >=
        Duration(seconds: config.recordActiveTimeout.round());
  }

}
