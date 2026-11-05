#! /usr/bin/env python3
# -*- coding: utf-8 -*-
#
#   Copyright (c) 2026, Albert Moky. All rights reserved.
#   Use of this source code is governed by a MIT-style license
#   that can be found in the LICENSE file.
#
#   end-to-end smoke test: real UDP loopback against a live Server thread

import base64
import json
import os
import socket
import sys
import threading
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from magpie_bridge.bridge import Server, ServerConfig
from magpie_bridge import BridgePacketFactory, Command

PORT = 19527


def run():
    cfg = ServerConfig({'host': '127.0.0.1', 'port': str(PORT)})
    server = Server(cfg)
    threading.Thread(target=server.run, daemon=True).start()
    time.sleep(0.5)
    factory = BridgePacketFactory()

    c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    c.settimeout(3)
    req = json.dumps({'time': time.time(), 'pad': 'x' * 480}).encode()
    c.sendto(factory.syn(request=req, source=0).pack(),
             ('127.0.0.1', PORT))
    data, _ = c.recvfrom(4096)
    resp = factory.parse(data)
    assert resp.command == Command.SYN_ACK
    info = json.loads(resp.payload)
    bid = resp.target
    secret = base64.b64decode(info['secret'])

    ack_payload = json.dumps({
        'time': time.time(), 'secret': info['secret'],
        'token': info['token'],
        'pad': 'x' * 480,   # ACK! must be padded to >= handshake_min_payload
    }).encode()
    # plain (non-encrypted) mode: ACK! must NOT carry an attachment
    c.sendto(factory.ack(response=ack_payload, source=bid).pack(),
             ('127.0.0.1', PORT))
    time.sleep(0.3)

    ping = factory.ping(
        request=json.dumps({'time': time.time()}).encode(),
        source=bid).sign(secret)
    c.sendto(ping.pack(), ('127.0.0.1', PORT))
    data, _ = c.recvfrom(4096)
    pong = factory.parse(data)
    assert pong.command == Command.PONG and pong.target == bid
    assert pong.verify(secret)

    body = json.dumps({'sources': [1, 2, 3]}).encode()
    c.sendto(factory.acpt(request=body, source=bid)
             .sign(secret).pack(), ('127.0.0.1', PORT))
    data, _ = c.recvfrom(4096)
    done = factory.parse(data)
    assert done.command == Command.DONE

    fin = factory.fin(
        request=json.dumps({'time': time.time()}).encode(),
        source=bid).sign(secret)
    c.sendto(fin.pack(), ('127.0.0.1', PORT))
    data, _ = c.recvfrom(4096)
    fa = factory.parse(data)
    assert fa.command == Command.FIN_ACK
    # black-box check: after "FIN!" the record is offline — a properly
    # signed PING must be silently dropped (no PONG reply)
    ping = factory.ping(request=json.dumps({'time': time.time()}).encode(),
                        source=bid).sign(secret)
    c.settimeout(0.5)
    c.sendto(ping.pack(), ('127.0.0.1', PORT))
    try:
        c.recvfrom(4096)
        assert False, 'PONG received after FIN: record should be offline'
    except socket.timeout:
        pass
    c.close()
    server.stop()
    print('E2E OK')


if __name__ == '__main__':
    run()
