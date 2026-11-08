import 'dart:math';
import 'dart:typed_data';

import 'package:magpipe/src/utils/coding.dart';

int failed = 0;
void check(bool ok, String name) {
  print('${ok ? "PASS" : "FAIL"}: $name');
  if (!ok) failed++;
}

void main() {
  // 1. known vectors
  check(Base64.encode(Uint8List.fromList([1, 2, 3])) == 'AQID', '1: encode known vector');
  check(Base64.decode('AQID').toString() == '[1, 2, 3]', '1: decode known vector');
  check(Base64.encode(Uint8List(0)) == '', '1: encode empty -> empty');

  // 2. roundtrip at various lengths (padding edges: 0..3 mod 4)
  var rng = Random(2026);
  for (var len in [0, 1, 2, 3, 4, 5, 16, 255, 256, 1024]) {
    var data = Uint8List.fromList(List.generate(len, (_) => rng.nextInt(256)));
    check(Base64.decode(Base64.encode(data)).toString() == data.toString(),
        '2: roundtrip len=$len');
  }

  // 3. invalid input -> null
  check(Base64.decode('A') == null, '3: too short -> null');
  check(Base64.decode('!!!!') == null, '3: bad alphabet -> null');
  check(Base64.decode('AQID@') == null, '3: trailing bad char -> null');

  // 4. interop: python base64.b64encode('foobar') == 'Zm9vYmFy'
  var foobar = Base64.decode('Zm9vYmFy');
  check(foobar != null && UTF8.decode(foobar) == 'foobar', '4: python-encoded input decodes');

  // 5. UTF8 regression
  check(UTF8.decode(UTF8.encode('中文abc')) == '中文abc', '5: utf8 roundtrip');
  check(UTF8.decode([0xFF]) == null, '5: utf8 invalid -> null');

  // 6. JSONMap regression
  check(JSONMap.decode(JSONMap.encode({'a': 1})!)!['a'] == 1, '6: json roundtrip');
  check(JSONMap.decode('[1]') == null, '6: non-object -> null');

  print(failed == 0 ? '\nAll tests passed' : '\n$failed test(s) FAILED');
}
