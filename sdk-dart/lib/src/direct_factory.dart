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

import 'reliable.dart';
import 'packet_factory.dart';

import 'direct.dart';

/// Creates and parses direct packets (B=0, client <-> client).
///
/// Only carries the ten instructions that make sense off-relay: handshake,
/// heartbeat, shutdown, noop and data. It never includes acpt/deny/fail/done,
/// which only exist on the server side.
class DirectPacketFactory extends MessagePacketFactory {
  const DirectPacketFactory();

  //
  //  Handshake
  //

  /// 1st handshake (SYN?): propose a peer-to-peer session.
  ///
  /// [request] carries the handshake body.
  ///
  /// Returns a SYN? packet to the peer.
  DirectPacket syn(Uint8List request) => DirectPacket.create(
    ack: 0,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.SYN,
    payload: request,
  );

  /// 2nd handshake (SYN!, A=1): accept the peer's proposal.
  ///
  /// [response] echoes the handshake body.
  ///
  /// Returns the SYN! reply to the peer's SYN?.
  DirectPacket synAck(Uint8List response) => DirectPacket.create(
    ack: 1,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.SYN_ACK,
    payload: response,
  );

  /// 3rd handshake (ACK!, A=1): final acknowledgment of the session.
  ///
  /// [response] echoes back the token material from the SYN!.
  ///
  /// Returns the closing handshake packet.
  DirectPacket ack(Uint8List response) => DirectPacket.create(
    ack: 1,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.ACK,
    payload: response,
  );

  //
  //  Heartbeat / shutdown / noop
  //

  /// Heartbeat (PING): keep-alive between peers.
  ///
  /// [request] is the application data.
  ///
  /// Returns a PING packet to the peer.
  DirectPacket ping(Uint8List request) => DirectPacket.create(
    ack: 0,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.PING,
    payload: request,
  );

  /// Shutdown (FIN?): close the peer-to-peer session.
  ///
  /// [request] is the farewell data.
  ///
  /// Returns a FIN? packet to the peer.
  DirectPacket fin(Uint8List request) => DirectPacket.create(
    ack: 0,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.FIN,
    payload: request,
  );

  /// No-op (NOOP): keep the channel warm.
  ///
  /// [request] is ignored by the protocol.
  ///
  /// Returns a NOOP packet to the peer.
  DirectPacket noop(Uint8List request) => DirectPacket.create(
    ack: 0,
    sn: 0,
    index: 0,
    count: 1,
    command: Command.NOOP,
    payload: request,
  );

  //
  //  Reply factories (fields copied from the request).
  //

  /// Reply (PONG, A=1): answer a peer's [PING].
  ///
  /// [packet] is the PING being answered.
  /// [response] is the application data.
  ///
  /// Returns a PONG packet carrying the same [sn]/[index]/[count] as the
  /// request.
  DirectPacket pong(Uint8List response, Magpie packet) => DirectPacket.create(
    ack: 1,
    sn: packet.sn,          // 0
    index: packet.index,    // 0
    count: packet.count,    // 1
    command: Command.PONG,
    payload: response,
  );

  /// Reply (FIN!, A=1): confirm a peer's [FIN] shutdown request.
  ///
  /// [packet] is the FIN? being answered.
  /// [response] is the application data.
  ///
  /// Returns a FIN! packet carrying the same [sn]/[index]/[count] as the
  /// request.
  DirectPacket finAck(Uint8List response, Magpie packet) => DirectPacket.create(
    ack: 1,
    sn: packet.sn,          // 0
    index: packet.index,    // 0
    count: packet.count,    // 1
    command: Command.FIN_ACK,
    payload: response,
  );

  //
  //  Data
  //

  /// Ordinary data packet (peer -> peer).
  ///
  /// [payload] is the message body.
  /// [sn] is the data serial number.
  /// [index] is the fragment offset within the transfer.
  /// [count] is the total number of fragments.
  ///
  /// [command] stays 0 (C=0) to keep the header small.
  ///
  /// Returns a DATA packet.
  DirectPacket data(Uint8List payload, {
    required int sn,
    int index = 0,
    int count = 1,
  }) => DirectPacket.create(
    ack: 0,
    sn: sn,
    index: index,
    count: count,
    command: Command.EMPTY,  // 0
    payload: payload,
  );

  /// Reply (COPY, A=1): acknowledge a received DATA packet.
  ///
  /// [packet] is the data packet being acknowledged: its [sn], [index] and
  /// [count] are copied so the sender can match the acknowledgement.
  /// [response] is the app-defined acknowledgement content.
  ///
  /// Returns a COPY reply to the sender.
  DirectPacket copy(Uint8List response, Magpie packet) => DirectPacket.create(
    ack: 1,
    sn: packet.sn,
    index: packet.index,
    count: packet.count,
    command: Command.COPY,
    payload: response,
  );

  //
  //  Parser
  //

  /// Validate and parse a received direct datagram.
  ///
  /// [buffer] is the raw UDP datagram to parse.
  ///
  /// Direct packets never carry an attachment: the whole buffer must equal
  /// header + payload, and B must be 0.
  @override
  Packet? parse(Uint8List buffer) {
    final packet = super.parse(buffer);
    if (packet == null || packet.bid != 0) {
      // bridge packet not for this factory.
      return null;
    }
    final hLen = packet.headerLength;
    final pLen = packet.payloadLength;
    final tail = buffer.length - (hLen + pLen);
    if (tail == 0) {
      // direct packet without attachment
      return DirectPacket(packet);
    } else if (tail != ATTACHMENT_LENGTH) {
      // tail is neither 0 nor 32: bad packet.
      return null;
    }
    // reliable packet with verify code
    final attachment = Uint8List.fromList(buffer.sublist(hLen + pLen));
    return ReliablePacket(packet, attachment);
  }

}
