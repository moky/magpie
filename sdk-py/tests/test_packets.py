#! /usr/bin/env python3
# -*- coding: utf-8 -*-
#
#   Copyright (c) 2026, Albert Moky. All rights reserved.
#   Use of this source code is governed by a MIT-style license
#   that can be found in the LICENSE file.
#
#   unit tests for the protocol layer

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from magpie_bridge import (BridgePacketFactory, DirectPacketFactory,
                           DirectPacket, ReliablePacket, Command)


class TestPackets(unittest.TestCase):

    def setUp(self):
        self.factory = BridgePacketFactory()
        self.direct_factory = DirectPacketFactory()
        self.secret = b'0' * 32

    def test_handshake_roundtrip(self):
        syn = self.factory.syn(request=b'{"time":1.0}', source=0)
        p = self.factory.parse(syn.pack())
        self.assertIsNotNone(p)
        self.assertEqual(p.command, Command.SYN)
        self.assertEqual(p.source, 0)
        # self.assertEqual(p.version, '1.0')

    def test_data_c0(self):
        data = self.factory.data(b'hi', target=100, source=200, sn=7)
        p = self.factory.parse(data.pack())
        self.assertEqual(p.command, 0)
        self.assertEqual(p.cmd, 0)
        self.assertEqual(p.sn, 7)
        self.assertEqual(p.target, 100)
        self.assertEqual(p.source, 200)

    def test_sign_verify(self):
        data = self.factory.data(b'hi', target=100, source=200, sn=7)
        signed = data.sign(self.secret)
        p = self.factory.parse(signed.pack())
        self.assertIsInstance(p, ReliablePacket)
        self.assertTrue(p.verify(self.secret))
        self.assertFalse(p.verify(b'1' * 32))

    def test_response_factories(self):
        ping = self.factory.ping(request=b'{}', source=200)
        pong = self.factory.pong(ping, response=b'{}')
        self.assertEqual(pong.target, 200)
        self.assertEqual(pong.command, Command.PONG)
        cp = self.factory.copy(
            self.factory.data(b'', target=1, source=2, sn=9))
        self.assertEqual(cp.target, 2)
        self.assertEqual(cp.sn, 9)

    def test_payload_too_large(self):
        with self.assertRaises(AssertionError):
            self.factory.data(b'x' * 1025, target=1, source=2, sn=1)

    def test_direct_payload_too_large(self):
        with self.assertRaises(AssertionError):
            self.direct_factory.data(b'x' * 1025, sn=1)

    def test_payload_at_limit(self):
        # 1024 bytes is the sender-side ceiling and must be accepted
        self.factory.data(b'x' * 1024, target=1, source=2, sn=1)
        self.direct_factory.data(b'x' * 1024, sn=1)

    def test_oversized_payload_assert(self):
        # payload > 1024 (<= MSS) passes the wire checks but trips the
        # constructor assert: a reminder not to build such packets; the
        # server catches it and drops the datagram (see bridge/thr_pre.py).
        wire = bytearray(self.factory.data(b'x' * 1024, target=1, source=2, sn=1).pack())
        wire += b'\x00' * 76                 # total = 8 + 1100 <= MSS
        wire[6:8] = (1100).to_bytes(2, 'big')
        with self.assertRaises(AssertionError):
            self.factory.parse(bytes(wire))

    def test_direct(self):
        d = self.direct_factory.data(b'hi', sn=3)
        p = self.direct_factory.parse(d.pack())
        self.assertEqual(p.bid, 0)
        # direct packets must not be accepted by the bridge factory
        self.assertIsNone(self.factory.parse(d.pack()))
        # bridge packets must not be accepted by the direct factory
        bridge = self.factory.data(b'hi', target=1, source=2, sn=3)
        self.assertIsNone(self.direct_factory.parse(bridge.pack()))

    def test_direct_copy_roundtrip(self):
        d = self.direct_factory.data(b'hello', sn=5)
        c = self.direct_factory.copy(d)
        self.assertIsInstance(c, DirectPacket)
        self.assertEqual(c.sn, 5)
        self.assertEqual(c.command, Command.COPY)
        parsed = self.direct_factory.parse(c.pack())
        self.assertEqual(parsed.sn, 5)
        self.assertEqual(parsed.command, Command.COPY)

    def test_direct_factory_command_set(self):
        for name in ('syn', 'syn_ack', 'ack', 'ping', 'pong', 'fin',
                     'fin_ack', 'noop', 'data', 'copy'):
            self.assertTrue(hasattr(self.direct_factory, name))
        for name in ('acpt', 'deny', 'fail', 'done'):
            self.assertFalse(hasattr(self.direct_factory, name))

    def test_error_list(self):
        self.assertIsNone(self.factory.parse(b'short'))
        syn = self.factory.syn(request=b'{}', source=0)
        bad = bytearray(syn.pack())
        bad[0:4] = b'XXXX'
        self.assertIsNone(self.factory.parse(bytes(bad)))
        bad = bytearray(syn.pack())
        bad[4] = (bad[4] & 0xF8) | 7
        self.assertIsNone(self.factory.parse(bytes(bad)))
        # garbage tail: neither 0 nor 32 bytes
        bad = bytearray(syn.pack()) + b'\x00\x01\x02'
        self.assertIsNone(self.factory.parse(bytes(bad)))


if __name__ == '__main__':
    unittest.main()
