# -*- coding: utf-8 -*-
#
#   Magpie Bridge
#
#                               Written in 2026 by Moky <albert.moky@gmail.com>
#
# ==============================================================================
# MIT License
#
# Copyright (c) 2026 Albert Moky
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ==============================================================================

import queue
import socket
import time
from typing import Optional, Any, List

from ..protocol import Command, Magpie
from ..reliable import ReliablePacket

from .utils import log
from .utils import utf8_encode, base64_encode, json_encode
from .utils import parse_json
from .utils import SocketAddress, SharedCounters
from .utils import ServerConfig

from .keeper import SecretKeeper
from .record import Record, PermitView
from .bid_manager import BidManager

from .thr_worker import Worker


class Manager(Worker):
    """Manager thread: handshake, system commands, record lifecycle and
    app-secret reload (docs/server.md 4)."""

    def __init__(self, manager_queue: queue.Queue,
                 config: ServerConfig, bids: BidManager,
                 sock: socket.socket, counters: SharedCounters):
        """Initialize the manager thread with its dependencies.

        Args:
            manager_queue: the queue fed by the preprocessor.
            config: server configuration (timeouts and limits).
            bids: the shared bid/record index for handshake and lifecycle.
            sock: the UDP socket used for replies.
            counters: the shared rate limiter for unconfirmed FAIL replies.
        """
        super().__init__(sock=sock, counters=counters, blocking=True)
        self.__manager_queue = manager_queue
        self.__config = config
        self.__bids = bids
        self.__secrets = SecretKeeper(config=config)

    @property
    def encrypted_mode(self) -> bool:
        """Whether an app-secret (enigma) table is loaded."""
        return not self.__secrets.enigma_empty

    @property
    def enigma_count(self) -> int:
        return self.__secrets.enigma_count

    def load_enigma_secrets(self):
        now = time.time()
        self.__secrets.load_enigma_secrets(now=now)

    # Override
    def process(self):
        """Run periodic maintenance and process one manager task."""
        now = time.time()
        #
        #  periodic maintenance
        #
        self.__bids.purge(now=now)
        self.__secrets.rotate_token_keys(now=now)
        self.__secrets.load_enigma_secrets(now=now)
        #
        #  process next task
        #
        try:
            address, packet = self.__manager_queue.get(timeout=0.05)
        except queue.Empty:
            return
        try:
            self._dispatch(address=address, packet=packet)
        except Exception as error:
            log.error('failed to process packet from %s, error: %s', address, error)

    #
    #   dispatch
    #

    def _dispatch(self, address: SocketAddress, packet: Magpie):
        """Handle one manager-queue task by command.

        Args:
            address: the source socket address.
            packet: the parsed packet.
        """
        cmd = packet.command
        now = time.time()

        if cmd == Command.SYN:
            self._handle_syn(address=address, packet=packet)
            return
        if cmd == Command.ACK:
            self._handle_ack(address=address, packet=packet)
            return

        # source check
        record = self.__bids.record_by_key(key=address.key())
        if record is None:
            self.maybe_reply_unconfirmed_fail(address=address, packet=packet)
            return
        if record.bid != packet.source:
            log.warning('forged source bid %d from %s', packet.source, address)
            return
        # attachment check (system commands after handshake)
        ok = isinstance(packet, ReliablePacket) and packet.verify(secret=record.secret)
        if not ok:
            log.warning('HMAC verification failed from bid %d', record.bid)
            return
        # offline gate
        if record.offline and cmd not in (Command.FIN, Command.NOOP):
            return
        record.touch(now)

        if cmd == Command.PING:
            self._reply_pong(address=address, record=record, packet=packet)
        elif cmd == Command.FIN:
            self._handle_fin(address=address, record=record, packet=packet, now=now)
        elif cmd == Command.NOOP:
            record.clear_offline()
            record.update_noop_time(now=now)
        elif cmd == Command.ACPT:
            self._handle_acpt(address=address, record=record, packet=packet)
        elif cmd == Command.DENY:
            self._handle_deny(address=address, record=record, packet=packet)
        else:
            log.warning('unknown command 0x%x from bid %d', cmd, record.bid)

    #
    #   handshake
    #

    def _handle_syn(self, address: SocketAddress, packet: Magpie):
        """Handle the first handshake (SYN?): allocate or reuse a bid.

        Args:
            address: the source socket address.
            packet: the SYN packet.
        """
        payload = packet.payload
        log.info('SYN   from %s, source=%d, payload=%d bytes',
                 address, packet.source, len(payload))
        if len(payload) < self.__config.handshake_min_payload:
            log.warning('SYN dropped: payload %d < min %d',
                        len(payload), self.__config.handshake_min_payload)
            return
        info = parse_json(payload)
        if not isinstance(info, dict):
            log.warning('SYN dropped: payload is not JSON')
            return

        # record reuse
        record = self.__bids.record_by_key(key=address.key())
        if record is not None:
            bid = record.bid
            secret = record.secret
        else:
            # capacity pre-check: only the internal loopback reservation
            # (loopback source bid = 0) is exempt; reserved/random bids count
            # against max_records (docs/server.md 5.4, architecture.md 6.3).
            source = packet.source
            internal = address.is_loopback() and source == 0
            if not internal and self.__bids.is_full():
                self._reply_fail(address=address, target=0)
                return
            bid = self.__bids.allocate(address=address, source=source)
            if bid is None:
                self._reply_fail(address=address, target=0)
                return
            secret = self.__secrets.new_message_key()

        keeper = self.__secrets
        # pick enigma / encrypt
        if self.encrypted_mode:
            requested = info.get('enigmas')
            if not isinstance(requested, list) or not requested:
                return
            enc = keeper.enigma_encrypt(secret=secret, candidates=requested, bid=bid)
            enigma_bundle = enc.to_dict()
            secret_b64 = base64_encode(enc.ciphertext)
        else:
            enigma_bundle = None
            secret_b64 = keeper.encode_message_key(secret=secret)

        # token: "bid={bid}&secret={secret}&socket={socket}"
        token = keeper.create_token(bid=bid, secret_b64=secret_b64,
                                    socket_key=address.key())

        body = {
            'secret': secret_b64,
            'token': token,
            'time': time.time(),
            'UDP': address.key(),
        }
        if enigma_bundle is not None:
            body['enigma'] = enigma_bundle
        response = utf8_encode(json_encode(body))
        # anti-amplification: the "SYN!" reply must stay below
        # handshake_min_payload regardless of the actual request size
        assert len(response) < self.__config.handshake_min_payload, \
            'SYN! amplification: response %d bytes' % len(response)
        log.info('SYN_ACK to %s, target=%d, payload=%d bytes',
                 address, bid, len(response))
        syn_ack = self.packet_factory.syn_ack(response, target=bid)
        self.send(address=address, data=syn_ack.pack())

    def _handle_ack(self, address: SocketAddress, packet: Magpie):
        """Handle the second handshake (ACK!): validate the token and
        create a record.

        Args:
            address: the source socket address.
            packet: the ACK packet.
        """
        payload = packet.payload
        log.info('ACK   from %s, source=%d, payload=%d bytes',
                 address, packet.source, len(payload))
        if len(payload) < self.__config.handshake_min_payload:
            return
        info = parse_json(payload)
        if not isinstance(info, dict):
            return
        bid = packet.source
        # an ACK! must carry a positive assigned bid (docs/server.md 4)
        if bid <= 0:
            return
        secret_b64 = info.get('secret')
        token = info.get('token')
        if not isinstance(secret_b64, str) or not isinstance(token, str):
            return
        keeper = self.__secrets
        # encrypted mode: enigma required
        if self.encrypted_mode:
            bundle = info.get('enigma')
            if not isinstance(bundle, dict):
                return
            key = bundle.get('key')
            ikm = keeper.get_enigma_secret(key=key)
            if ikm is None:
                return
            # token check uses the ciphertext as secret
            if not keeper.check_token(token=token, bid=bid, secret_b64=secret_b64,
                                      socket_key=address.key()):
                return
            # decrypt secret
            try:
                secret = keeper.enigma_decrypt(bundle=bundle, secret_b64=secret_b64,
                                               bid=bid)
            except Exception as error:
                log.warning('failed to decrypt secret: %s, remote: %s, error: %s',
                            secret_b64, address, error)
                return
            # attachment check with the decrypted plaintext secret
            ok = isinstance(packet, ReliablePacket) and packet.verify(secret=secret)
            if not ok:
                return
        else:
            # plain mode: no attachment expected
            if isinstance(packet, ReliablePacket):
                return
            if not keeper.check_token(token=token, bid=bid, secret_b64=secret_b64,
                                      socket_key=address.key()):
                return
            # decode secret
            try:
                secret = keeper.decode_message_key(secret_b64)
            except Exception as error:
                log.warning('failed to decode secret: %s, remote: %s, error: %s',
                            secret_b64, address, error)
                return

        # create / reuse record
        now = time.time()
        record = self.__bids.record_by_bid(bid=bid)
        if record is not None:
            if record.key != address.key():
                return
            record.clear_offline()
            record.touch(now=now)
            log.info('reuse bid %d, socket %s', bid, address)
            return
        record = self.__bids.record_by_key(key=address.key())
        if record is not None:
            record.clear_offline()
            record.touch(now=now)
            log.info('reuse bid %d for socket %s', bid, address)
            return
        # bind the new record; notify the client when the table is full
        # (docs/server.md 5.4, architecture.md 6.3: ACK! final capacity check;
        #  a full table is a handshake failure, so the FAIL carries only the
        #  server time and no attachment, see protocol.md 6.1)
        record = self.__bids.add(bid=bid, address=address, secret=secret, now=now)
        if record is None:
            self._reply_fail(address=address, target=bid)
            log.error('cannot assign bid %d for socket %s', bid, address)
            return
        log.warning('allocate new bid %d for socket %s', bid, address)

    #
    #   commands handled by the manager
    #

    def _reply_pong(self, address: SocketAddress, record: Record, packet: Magpie):
        """Reply PONG to a verified PING.

        Args:
            address: the source socket address.
            record: the sender's record.
            packet: the PING packet.
        """
        info = parse_json(packet.payload) or {}
        info['time'] = time.time()
        response = utf8_encode(json_encode(info))
        pong = self.packet_factory.pong(response, packet=packet)
        pong = pong.sign(secret=record.secret)
        self.send(address=address, data=pong.pack())

    def _handle_fin(self, address: SocketAddress, record: Record, packet: Magpie, now: float):
        """Handle FIN?: mark offline (unless immune) and reply FIN!.

        Args:
            address: the source socket address.
            record: the sender's record.
            packet: the FIN packet.
            now: current epoch seconds.
        """
        if now - record.last_noop_time >= self.__config.noop_immunity_window:
            record.set_offline()
            log.warning('offline record: bid=%d, socket=%s', record.bid, address)
        response = utf8_encode(json_encode({'time': now}))
        fin_ack = self.packet_factory.fin_ack(response, packet=packet)
        fin_ack = fin_ack.sign(secret=record.secret)
        self.send(address=address, data=fin_ack.pack())

    def _handle_acpt(self, address: SocketAddress, record: Record, packet: Magpie):
        """Handle ACPT?: update permit entries and reply DONE/FAIL.

        Args:
            address: the source socket address.
            record: the sender's record.
            packet: the ACPT packet.
        """
        sources = self._parse_sources(packet=packet)
        if sources is None:
            return
        if sources == [1, 2, 3]:
            cleared = record.allow_all()
            response = utf8_encode(json_encode({
                'src-command': '41435054',
                'sources': cleared,
                'time': time.time(),
            }))
            done = self.packet_factory.done(response, target=record.bid)
            done = done.sign(secret=record.secret)
            self.send(address=address, data=done.pack())
            log.info('ACPT * for record: bid=%d, socket=%s', record.bid, address)
            return
        # format errors (negative / 0 / self): reject the whole request
        format_bad = [y for y in sources
                      if not isinstance(y, int) or y <= 0 or y == record.bid]
        if format_bad:
            response = utf8_encode(json_encode({
                'src-command': '41435054',
                'sources': format_bad,
                'time': time.time()
            }))
            fail = self.packet_factory.fail(response, target=record.bid)
            fail = fail.sign(secret=record.secret)
            self.send(address=address, data=fail.pack())
            log.warning('failed to ACPT %s for record: bid=%d, socket=%s',
                        format_bad, record.bid, address)
            return
        failed = []
        ok = []
        for y in sources:
            if self._acpt_one(record, y):
                ok.append(y)
            else:
                failed.append(y)
        cmd = '41435054'
        if failed:
            response = utf8_encode(json_encode({
                'src-command': cmd,
                'sources': failed,
                'time': time.time()
            }))
            fail = self.packet_factory.fail(response, target=record.bid)
            fail = fail.sign(secret=record.secret)
            self.send(address=address, data=fail.pack())
        else:
            response = utf8_encode(json_encode({
                'src-command': cmd,
                'sources': ok,
                'time': time.time()
            }))
            done = self.packet_factory.done(response, target=record.bid)
            done = done.sign(secret=record.secret)
            self.send(address=address, data=done.pack())
        # finished
        log.info('ACPT %s, failed: %s for record: bid=%d, socket=%s',
                 sources, failed, record.bid, address)

    def _acpt_one(self, x_record: Record, y_bid: int) -> bool:
        """Add a permit for y_bid from x_record's perspective.

        Args:
            x_record: the requester's record.
            y_bid: the peer bid to permit.

        Returns:
            whether the permit was inserted.
        """
        # state errors (record missing / allowlist full) are reported
        # per-entry; format errors were rejected as a whole by the caller
        y_record = self.__bids.record_by_bid(bid=y_bid)
        if y_record is None:
            return False
        # wildcard on x: idempotent success, no write
        if x_record.is_allow_all():
            return True
        # wildcard on y: treated as already accepted
        y_wild = y_record.is_allow_all()

        # 1. search x -> y
        view = x_record.search_permit(record=y_record)
        if view is not None and view.match(record=y_record):
            return True
        if view is not None:
            x_record.remove_permit(bid=y_bid)

        # 2. search y -> x
        view = y_record.search_permit(record=x_record)
        if view is None:
            permit = PermitView(owner=y_record, bid=y_record.bid, hash31=y_record.hash31, valid=False)
        elif view.match(record=x_record) or y_wild:
            view.accept(record=y_record)
            permit = PermitView(owner=y_record, bid=y_record.bid, hash31=y_record.hash31, valid=True)
        else:
            y_record.remove_permit(bid=x_record.bid)
            permit = PermitView(owner=y_record, bid=y_record.bid, hash31=y_record.hash31, valid=False)
        return x_record.insert_permit(record=y_record, view=permit)

    def _handle_deny(self, address: SocketAddress, record: Record, packet: Magpie):
        """Handle DENY?: remove permit entries and reply DONE/FAIL.

        Args:
            address: the source socket address.
            record: the sender's record.
            packet: the DENY packet.
        """
        sources = self._parse_sources(packet=packet)
        if sources is None:
            return
        if sources == [1, 2, 3]:
            cleared = record.clear_permits()
            response = utf8_encode(json_encode({
                'src-command': '44454E59',
                'sources': cleared,
                'time': time.time(),
            }))
            done = self.packet_factory.done(response, target=record.bid)
            done = done.sign(secret=record.secret)
            self.send(address=address, data=done.pack())
            log.info('DENY * for record: bid=%d, socket=%s', record.bid, address)
            return
        # wildcard mode: directional DENY always fails
        if record.is_allow_all():
            response = utf8_encode(json_encode({
                'src-command': '44454E59',
                'sources': list(sources),
                'time': time.time(),
            }))
            fail = self.packet_factory.fail(response, target=record.bid)
            fail = fail.sign(secret=record.secret)
            self.send(address=address, data=fail.pack())
            log.warning('failed to DENY %s when "allow all" for record: bid=%d, socket=%s',
                        sources, record.bid, address)
            return
        # format errors (negative / 0 / self): reject the whole request
        format_bad = [y for y in sources
                      if not isinstance(y, int) or y <= 0 or y == record.bid]
        if format_bad:
            response = utf8_encode(json_encode({
                'src-command': '44454E59',
                'sources': format_bad,
                'time': time.time()
            }))
            fail = self.packet_factory.fail(response, target=record.bid)
            fail = fail.sign(secret=record.secret)
            self.send(address=address, data=fail.pack())
            log.warning('failed to DENY %s for record: bid=%d, socket=%s',
                        format_bad, record.bid, address)
            return
        removed = []
        for y in sources:
            record.remove_permit(bid=y)
            removed.append(y)
        response = utf8_encode(json_encode({
            'src-command': '44454E59',
            'sources': removed,
            'time': time.time()
        }))
        done = self.packet_factory.done(response, target=record.bid)
        done = done.sign(secret=record.secret)
        self.send(address=address, data=done.pack())
        # finished
        log.info('DENY %s success for record: bid=%d, socket=%s',
                 sources, record.bid, address)

    @staticmethod
    def _parse_sources(packet: Magpie) -> Optional[List[Any]]:
        """Parse the 'sources' list from a packet payload.

        Args:
            packet: the ACPT/DENY packet.

        Returns:
            the list, or None when missing or invalid.
        """
        info = parse_json(packet.payload)
        if not isinstance(info, dict):
            return None
        sources = info.get('sources')
        if not isinstance(sources, list):
            return None
        return sources

    #
    #   replies
    #

    def _reply_fail(self, address: SocketAddress, target: int):
        """Send a plain FAIL reply.

        Args:
            address: the source socket address.
            target: the bid to put in the reply target.
        """
        response = utf8_encode(json_encode({'time': time.time()}))
        fail = self.packet_factory.fail(response, target=target)
        self.send(address=address, data=fail.pack())
