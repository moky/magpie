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

import 'protocol/command.dart';
import 'protocol/magpie.dart';
import 'protocol/protocol.dart';

import 'packet.dart';
import 'reliable.dart';
import 'packet_factory.dart';

import 'bridge.dart';

/// Creates and parses bridge packets (B=1, client <-> server).
///
/// The server only ever uses this factory; the client keeps one per bridge
/// pipe. Instruction methods build fresh packets; [parse] validates received
/// datagrams and rejects direct (B=0) packets.
class BridgePacketFactory extends MessagePacketFactory {
  const BridgePacketFactory();

  //
  //  Handshake
  //

  /// 1st handshake (SYN?): ask the server for a bridge id.
  ///
  /// [request] carries the handshake body (e.g. the session token).
  /// [source] is the bid the client requests (0 = let the server assign).
  ///
  /// Returns a SYN? packet from the client to the server.
  BridgePacket syn(Uint8List request, {
    int source = 0
  }) => BridgePacket.create(
    ack: 0,
    target: 0,
    source: source,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.SYN,
    payload: request,
  );

  /// 2nd handshake (SYN!, A=1): server assigns [target] to the client.
  ///
  /// [response] echoes the handshake body.
  ///
  /// Returns the server's reply to the client's SYN?.
  BridgePacket synAck(Uint8List response, {
    required int target
  }) => BridgePacket.create(
    ack: 1,
    target: target,
    source: 0,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.SYN_ACK,
    payload: response,
  );

  /// 3rd handshake (ACK!, A=1): client confirms the established session.
  ///
  /// [response] echoes back secret/token from the SYN!.
  ///
  /// Returns the final handshake packet from the client.
  BridgePacket ack(Uint8List response, {
    required int source
  }) => BridgePacket.create(
    ack: 1,
    target: 0,
    source: source,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.ACK,
    payload: response,
  );

  //
  //  Result (server -> client)
  //

  /// Result (FAIL): the server rejects a previous request.
  ///
  /// [response] carries the failure detail.
  /// [target] is the bid of the client being answered.
  /// [sn] mirrors the request's data serial number when it was fragmented.
  /// [index] mirrors the request's fragment index.
  /// [count] mirrors the request's fragment count.
  ///
  /// Returns a FAIL packet (server -> client).
  BridgePacket fail(Uint8List response, {
    required int target,
    int sn = 0,
    int index = 0,
    int count = 1,
  }) => BridgePacket.create(
    ack: 1,
    target: target,
    source: 0,
    sn: sn,
    index: index,
    count: count,
    command: Command.FAIL,
    payload: response,
  );

  /// Result (DONE): the server reports a previous request completed.
  ///
  /// [response] carries the result body.
  /// [target] is the bid of the client being answered.
  /// [sn] mirrors the request's data serial number when it was fragmented.
  /// [index] mirrors the request's fragment index.
  /// [count] mirrors the request's fragment count.
  ///
  /// Returns a DONE packet (server -> client).
  BridgePacket done(Uint8List response, {
    required int target,
    int sn = 0,
    int index = 0,
    int count = 1,
  }) => BridgePacket.create(
    ack: 1,
    target: target,
    source: 0,
    sn: sn,
    index: index,
    count: count,
    command: Command.DONE,
    payload: response,
  );

  //
  //  Permit
  //

  /// Permit (ACPT): the server accepts a client's handshake.
  ///
  /// [request] is the handshake body to pass back.
  /// [source] is the bid granted to the client.
  ///
  /// Returns the server's ACPT packet.
  BridgePacket acpt(Uint8List request, {
    required int source
  }) => BridgePacket.create(
    ack: 0,
    target: 0,
    source: source,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.ACPT,
    payload: request,
  );

  /// Permit (DENY): the server refuses a client's handshake.
  ///
  /// [request] is the handshake body to pass back.
  /// [source] is the bid being refused.
  ///
  /// Returns the server's DENY packet.
  BridgePacket deny(Uint8List request, {
    required int source
  }) => BridgePacket.create(
    ack: 0,
    target: 0,
    source: source,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.DENY,
    payload: request,
  );

  //
  //  Heartbeat / shutdown / noop
  //

  /// Heartbeat (PING): client keep-alive while the pipe is idle.
  ///
  /// [request] is the application data.
  /// [source] is the client's bid.
  ///
  /// Returns a PING packet to the server.
  BridgePacket ping(Uint8List request, {
    required int source
  }) => BridgePacket.create(
    ack: 0,
    target: 0,
    source: source,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.PING,
    payload: request,
  );

  /// Shutdown (FIN?): client asks to close the bridge connection.
  ///
  /// [request] is the farewell data.
  /// [source] is the client's bid.
  ///
  /// Returns a FIN? packet to the server.
  BridgePacket fin(Uint8List request, {
    required int source
  }) => BridgePacket.create(
    ack: 0,
    target: 0,
    source: source,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.FIN,
    payload: request,
  );

  /// No-op (NOOP): keep the pipe warm without any payload semantics.
  ///
  /// [request] is ignored by the protocol.
  /// [source] is the client's bid.
  ///
  /// Returns a NOOP packet to the server.
  BridgePacket noop(Uint8List request, {
    required int source
  }) => BridgePacket.create(
    ack: 0,
    target: 0,
    source: source,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.NOOP,
    payload: request,
  );

  //
  //  Reply factories (bid swapped, other fields copied from the request).
  //

  /// Reply (PONG, A=1): answer a client's [PING].
  ///
  /// [packet] is the PING being answered.
  /// [response] is the application data.
  ///
  /// Returns a PONG packet with target/source swapped (server -> the ping
  /// source).
  BridgePacket pong(Uint8List response, Magpie packet) => BridgePacket.create(
    ack: 1,
    target: packet.source,
    source: packet.target,  // 0
    sn: packet.sn,          // 0
    index: packet.index,    // 0
    count: packet.count,    // 1
    command: Command.PONG,
    payload: response,
  );

  /// Reply (FIN!, A=1): confirm a client's [FIN] shutdown request.
  ///
  /// [packet] is the FIN? being answered.
  /// [response] is the application data.
  ///
  /// Returns a FIN! packet with target/source swapped.
  BridgePacket finAck(Uint8List response, Magpie packet) => BridgePacket.create(
    ack: 1,
    target: packet.source,
    source: packet.target,  // 0
    sn: packet.sn,          // 0
    index: packet.index,    // 0
    count: packet.count,    // 1
    command: Command.FIN_ACK,
    payload: response,
  );

  //
  //  Data
  //

  /// Ordinary data packet (client -> server / forwarded between clients).
  ///
  /// [payload] is the message body.
  /// [target] is the receiver's bid (0 = server).
  /// [source] is the sender's bid.
  /// [sn] is the data serial number.
  /// [index] is the fragment offset within the transfer.
  /// [count] is the total number of fragments.
  ///
  /// [command] stays 0 (C=0) to keep the header small.
  ///
  /// Returns a DATA packet.
  BridgePacket data(Uint8List payload, {
    required int target,
    required int source,
    required int sn,
    int index = 0,
    int count = 1,
  }) => BridgePacket.create(
    ack: 0,
    target: target,
    source: source,
    sn: sn,
    index: index,
    count: count,
    command: Command.EMPTY,  // 0
    payload: payload,
  );

  /// Reply: acknowledge a received DATA packet with COPY (A=1).
  ///
  /// [packet] is the data packet being acknowledged: its [sn], [index] and
  /// [count] are copied so the sender can match the acknowledgement, and
  /// [target]/[source] are swapped.
  /// [response] is the app-defined acknowledgement content.
  ///
  /// Returns a COPY reply addressed to [packet.source].
  BridgePacket copy(Uint8List response, Magpie packet) => BridgePacket.create(
    ack: 1,
    target: packet.source,
    source: packet.target,
    sn: packet.sn,
    index: packet.index,
    count: packet.count,
    command: Command.COPY,
    payload: response,
  );

  //
  //  Parser
  //

  /// Validate and parse a received bridge datagram.
  ///
  /// [buffer] is the raw UDP datagram to parse.
  ///
  /// Basic header validation is shared with [MessagePacket.decode]; here we
  /// then enforce B=1 and the tail rule: tail < 0 is rejected, tail == 0
  /// yields a plain [BridgePacket], tail == 32 yields a [ReliablePacket]
  /// whose attachment is the trailing 32 bytes. The attachment is NOT
  /// verified here; the caller does that once the secret is known.
  @override
  Packet? parse(Uint8List buffer) {
    final packet = super.parse(buffer);
    if (packet == null || packet.bid != 1) {
      // direct packet not for this factory.
      return null;
    }
    final hLen = packet.headerLength;
    final pLen = packet.payloadLength;
    final tail = buffer.length - (hLen + pLen);
    if (tail == 0) {
      // bridge packet without attachment
      return BridgePacket(packet);
    } else if (tail != ATTACHMENT_LENGTH) {
      // tail is neither 0 nor 32: bad packet.
      return null;
    }
    // reliable packet with verify code
    final attachment = Uint8List.fromList(buffer.sublist(hLen + pLen));
    return ReliablePacket(packet, attachment);
  }

}
