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
import 'dart:convert';
import 'dart:typed_data';

class JSONMap {
  JSONMap._();

  /// Encodes a map to a JSON string.
  ///
  /// [map] is the map to serialize.
  ///
  /// Returns the JSON-encoded string, or null if the map (or any value
  /// within it) is not JSON-encodable.
  static String? encode(Map map) {
    try {
      return json.encode(map);
    } on JsonUnsupportedObjectError {
      return null;
    }
  }

  /// Decodes a JSON string back to a map.
  ///
  /// [string] is the JSON string to deserialize.
  ///
  /// Returns the decoded map, or null if [string] is not a valid JSON
  /// object (arrays, numbers and other top-level values are rejected).
  static Map? decode(String string) {
    try {
      final value = json.decode(string);
      return value is Map<Object?, Object?> ? value : null;
    } on FormatException {
      return null;
    }
  }
}

class UTF8 {
  UTF8._();

  /// Encodes a string to UTF-8 binary data.
  ///
  /// [string] is the string to encode.
  ///
  /// Returns the UTF-8 encoded bytes; unpaired surrogates in [string]
  /// are replaced with U+FFFD.
  static Uint8List encode(String string) {
    // Older supported SDKs declare utf8.encode to return List<int>
    // instead of Uint8List, hence the defensive copy.
    return Uint8List.fromList(utf8.encode(string));
  }

  /// Decodes UTF-8 binary data back to a string.
  ///
  /// [data] is the UTF-8 encoded binary data to decode.
  ///
  /// Returns the decoded string, or null if [data] is not valid UTF-8.
  static String? decode(List<int> data) {
    try {
      return utf8.decode(data);
    } on FormatException {
      return null;
    }
  }
}

class Base64 {
  Base64._();

  /// Encodes binary data to a Base64 string (RFC 4648, with padding).
  ///
  /// [data] is the raw binary data to encode.
  ///
  /// Returns the Base64-encoded string.
  static String encode(Uint8List data) {
    return base64Encode(data);
  }

  /// Decodes a Base64 string back to binary data (standard alphabet,
  /// as produced by [encode]).
  ///
  /// [string] is the Base64-encoded string to decode.
  ///
  /// Returns the decoded binary data, or null if [string] is not valid
  /// Base64 (bad alphabet or broken padding).
  static Uint8List? decode(String string) {
    try {
      return base64Decode(string);
    } on FormatException {
      return null;
    }
  }

}
