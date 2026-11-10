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

import 'coding.dart';
import 'config.dart';

mixin PayloadMixIn {

  // protected
  Map decodePayload(Uint8List payload) {
    final text = UTF8.decode(payload) ?? '{}';
    return JSONMap.decode(text) ?? {};
  }

  // protected
  Uint8List encodePayload(Map info) {
    final text = JSONMap.encode(info) ?? '';
    return UTF8.encode(text);
  }

  /// Pad the JSON body to at least [ServerConfig.handshakeMinPayload]
  /// bytes with a 'blah' field (docs/client.md 5.1): the value repeats
  /// 'blah' separated by spaces, so the padded body may exceed the
  /// minimum by up to 4 bytes.
  // protected
  Uint8List padPayload(Map<Object?, Object?> body, {required Config config}) {
    var json = JSONMap.encode(body) ?? '';
    var padLen = config.handshakeMinPayload - (json.length + 10);  // + ',"blah":""'
    if (padLen > 0) {
      // k words joined by spaces take 5k-1 bytes; round up so the
      // body never falls below the minimum
      var words = (padLen + 5) ~/ 5;
      body['blah'] = List.filled(words, 'blah').join(' ');
      json = JSONMap.encode(body) ?? json;
    }
    return UTF8.encode(json);
  }

}