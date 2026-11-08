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
import 'x.dart';

/// Delegation base shared by all public packet classes.
///
/// [BasePacket] wraps an inner [Packet] (usually a [MessagePacket]) and
/// forwards every field and [pack] to it, so [BridgePacket],
/// [DirectPacket] and [ReliablePacket] stay thin wrappers around the same
/// validated payload. It also carries the [sign] capability: signing is
/// computed over the bare header + payload of the inner packet, so calling
/// [sign] on an already-signed [ReliablePacket] simply re-signs it.
class BasePacket implements Packet {
  /// Wrap [packet] as the delegation target.
  BasePacket(this._packet);

  /// The inner packet whose fields and wire bytes are exposed.
  final Packet _packet;

  //
  //  Flags
  //

  @override int get ack => _packet.ack;
  @override int get bid => _packet.bid;
  @override int get cmd => _packet.cmd;
  @override int get dsn => _packet.dsn;
  @override int get ext => _packet.ext;

  //
  //  Lengths
  //

  @override int get headerLength => _packet.headerLength;
  @override int get payloadLength => _packet.payloadLength;

  //
  //  Fields
  //

  @override int get target  => _packet.target;
  @override int get source  => _packet.source;
  @override int get sn      => _packet.sn;
  @override int get index   => _packet.index;
  @override int get count   => _packet.count;
  @override int get command => _packet.command;

  @override Uint8List get payload => _packet.payload;

  //
  //  Serialization
  //

  @override
  Uint8List pack() => _packet.pack();

  //
  //  Attachment (HMAC-SHA256)
  //

  /// Compute HMAC-SHA256 over (header + payload) and return a signed packet.
  ///
  /// [secret] is the HMAC key.
  ///
  /// Note: DirectPacket inherits this as well; signing a direct packet is a
  /// reserved capability (the app decides whether it needs one).
  ///
  /// Returns a [ReliablePacket] carrying the computed attachment.
  ReliablePacket sign(Uint8List secret) {
    // pack() yields header + payload only; the attachment stays separate.
    final base = _packet.pack();
    final tag = HmacSha256.generate(secret: secret, message: base);
    return ReliablePacket(_packet, tag);
  }

}


/// A packet that carries a 32-byte HMAC-SHA256 attachment (verify code).
///
/// [ReliablePacket] wraps the same inner packet and appends the digest when
/// serialising, so the wire bytes are `header + payload + attachment(32)`.
/// Its inherited [sign] re-computes the digest over the bare header +
/// payload of the inner packet, which makes re-signing (secret rotation)
/// a plain `packet.sign(newSecret)` call that replaces the attachment.
class ReliablePacket extends BasePacket {
  /// Wrap [packet] with an already computed [attachment] (32 bytes).
  ///
  /// [packet] is the inner packet to wrap.
  /// [attachment] is the 32-byte HMAC-SHA256 digest.
  ReliablePacket(super._packet, this.attachment);

  /// The 32-byte HMAC-SHA256 digest.
  final Uint8List attachment;

  //
  //  Serialization
  //

  @override
  Uint8List pack() {
    final base = _packet.pack();
    final digest = attachment;
    final merged = Uint8List(base.length + digest.length);
    merged.setRange(0, base.length, base);
    merged.setRange(base.length, merged.length, digest);
    return merged;
  }

  //
  //  Attachment (HMAC-SHA256)
  //

  /// Verify the attachment with [secret].
  ///
  /// [secret] is the HMAC key.
  ///
  /// Uses a constant-time comparison.
  ///
  /// Returns whether the attachment matches.
  bool verify(Uint8List secret) {
    final tag = attachment;
    if (tag.length != ATTACHMENT_LENGTH) {
      return false;
    } else if (secret.isEmpty) {
      return false;
    }
    // Re-pack header+payload (without attachment) the same way sign() did.
    final base = _packet.pack();
    return HmacSha256.verify(tag, secret: secret, message: base);
  }

}
