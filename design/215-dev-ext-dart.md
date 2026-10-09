# Magpie Bridge SDK - 扩展协议 (Dart 示例)

这里是 Payload 扩展协议的具体实现。

由于 Dart 语言对函数变量、空安全等特性更丰富，所以这里以 Dart 语言举例。

## 载荷 Payload

> 数据载荷分 3 大类：原始字节类 RawPayload、请求类 Request 和 应答类 Response。

载荷接口定义：

```dart
abstract interface class Payload {
    
    int get length;
    
    Uint8List pack();
}
```

基类：

```dart
abstract class BasePayload implements Payload {
    
    /// 分包
    List<RawPayload> split([int maxPayloadLength = 1024]) {
        if (maxPayloadLength <= 0) {
            throw ArgumentError('maxPayloadLength error: $maxPayloadLength');
        }
        final results = <RawPayload>[];
        final content = pack();
        final total = content.length;
        int start = 0;
        int end;
        Uint8List chunk;
        while (start < total) {
            end = start + maxPayloadLength;
            if (end < total) {
                chunk = content.sublist(start, end);
            } else {
                chunk = content.sublist(start);
            }
            results.add(RawPayload(chunk));
            start = end;
        }
        return results;
    }
    
}
```

### 原始载荷 RawPayload

```dart
class RawPayload extends BasePayload {
    RawPayload(this.content);
    
    final Uint8List content;
    
    @override
    int get length => content.length;
    
    @override
    Uint8List pack() => content;
    
    /// 转为请求包
    Request? toRequest() => Request.parseRequest(pack());
    
    /// 转为应答包
    Response? toResponse() => Response.parseResponse(pack());
}
```

### 请求类 Request

```dart
class Request extends BasePayload {
    Request(this._buffer, {
        required this.method,
        required this.target,
        this.version = CURRENT_VERSION,
        required this.fields,
        required this.content,
    });
    
    static const CURRENT_VERSION  = 'MP/1.0';
    
    /// data buffer
    Uint8List? _buffer;
    
    final String method;
    final String target;  // Request-Target
    final String version;
    
    final Map<String, String> fields;
    
    final Uint8List content;  // 数据区
    
    @override
    int get length => pack().length;
    
    @override
    Uint8List pack() {
        var data = _buffer;
        if (data == null) {
            // 拼接更新 data
            final builder = BytesBuilder(copy: false);
            builder.add(utf8.encode('$method $target $version\r\n'));
            fields.forEach((String key, String value) {
                builder.add(utf8.encode('$key: $value\r\n'));
            });
            builder.add(utf8.encode('\r\n'));
            builder.add(content);
            data = builder.takeBytes();
            // 缓存到 buffer
            _buffer = data;
        }
        return data;
    }
    
    //  请求包数据格式：
    //
    //      {method} {target} {version}\r\n
    //      {field_key_1}: {field_value_1}\r\n
    //      {field_key_2}: {field_value_2}\r\n
    //      ..
    //      {field_key_n}: {field_value_n}\r\n
    //      \r\n
    //      {content}
    
    static Request? parseRequest(Uint8List data) {
        // 1. 分割头部与数据区
        final sep = indexOfHeaderEnd(data);
        if (sep < 0) {
            return null;
        }
        final body = data.sublist(sep + 4);
        final head = utf8.decode(data.sublist(0, sep));
        final lines = head.split('\r\n');
        if (lines.isEmpty || lines[0].isEmpty) {
            return null;
        }
        // 2. 解析请求行: {method} {target} {version}
        final parts = parseStartLine(lines[0]);
        if (parts.length != 3 ||
            parts[0].isEmpty || parts[1].isEmpty || parts[2].isEmpty) {
            return null;
        }
        // 3. 解析字段
        final fields = parseFields(lines.sublist(1));
        if (fields == null) {
            return null;
        }
        // 将原 data 放入 buffer，避免二次打包
        return Request(data,
            method: parts[0],
            target: parts[1],
            version: parts[2],
            fields: fields,
            content: body,
        );
    }
}
```

### 应答类 Response

```dart
class Response extends BasePayload {
    Response(this._buffer, {
        this.version = CURRENT_VERSION,
        required this.code,
        required this.reason,
        required this.fields,
        required this.content,
    });
    
    static const CURRENT_VERSION  = 'MP/1.0';
    
    /// data buffer
    Uint8List? _buffer;
    
    final String version;
    final int code;       // Status-Code
    final String reason;  // Reason-Phrase
    
    final Map<String, String> fields;
    
    final Uint8List content;  // 数据区
    
    @override
    int get length => pack().length;
    
    @override
    Uint8List pack() {
        var data = _buffer;
        if (data == null) {
            // 更新 data
            final builder = BytesBuilder(copy: false);
            builder.add(utf8.encode('$version $code $reason\r\n'));
            fields.forEach((String key, String value) {
                builder.add(utf8.encode('$key: $value\r\n'));
            });
            builder.add(utf8.encode('\r\n'));
            builder.add(content);
            data = builder.takeBytes();
            // 缓存到 buffer
            _buffer = data;
        }
        return data;
    }
    
    //  应答包数据格式：
    //
    //      {version} {code} {reason}\r\n
    //      {field_key_1}: {field_value_1}\r\n
    //      {field_key_2}: {field_value_2}\r\n
    //      ..
    //      {field_key_n}: {field_value_n}\r\n
    //      \r\n
    //      {content}
    
    static Response? parseResponse(Uint8List data) {
        // 1. 分割头部与数据区
        final sep = indexOfHeaderEnd(data);
        if (sep < 0) {
            return null;
        }
        final body = data.sublist(sep + 4);
        final head = utf8.decode(data.sublist(0, sep));
        final lines = head.split('\r\n');
        if (lines.isEmpty || lines[0].isEmpty) {
            return null;
        }
        // 2. 解析状态行: {version} {code} {reason}
        //    允许 Reason-Phrase 为空
        final parts = parseStartLine(lines[0]);
        if (parts.length != 3 ||
            parts[0].isEmpty || parts[1].isEmpty/* || parts[2].isEmpty*/) {
            return null;
        }
        final code = int.tryParse(parts[1]);
        if (code == null) {
            return null;
        }
        // 3. 解析字段
        final fields = parseFields(lines.sublist(1));
        if (fields == null) {
            return null;
        }
        // 将原 data 放入 buffer，避免二次打包
        return Response(data,
            version: parts[0],
            code: code,
            reason: parts[2],
            fields: fields,
            content: body,
        );
    }
}
```

工具函数

```dart
/// 在数据中查找头结束标记 "\r\n\r\n"，找不到返回 -1
int indexOfHeaderEnd(Uint8List data) {
    for (int i = 0; i + 3 < data.length; i++) {
        if (data[i] == 0x0D && data[i + 1] == 0x0A &&
            data[i + 2] == 0x0D && data[i + 3] == 0x0A) {
            return i;
        }
    }
    return -1;
}

/// 将协议头第一行拆分成三元组
List<String> parseStartLine(String line1) {
    final sp1 = line1.indexOf(' ');
    if (sp1 <= 0) {
        return [];
    }
    final sp2 = line1.indexOf(' ', sp1 + 1);
    if (sp2 < 0) {
        return [
            line1.substring(0, sp1),
            line1.substring(sp1 + 1),
            ''
        ];
    }
    return [
        line1.substring(0, sp1),
        line1.substring(sp1 + 1, sp2),
        line1.substring(sp2 + 1)
    ];
}

/// 将 "{key}: {value}" 数组转换为字典
Map<String, String>? parseFields(List<String> lines) {
    final fields = <String, String>{};
    for (int i = 0; i < lines.length; i++) {
        final pair = lines[i];
        final colon = pair.indexOf(':');
        if (colon < 0) {
            return null;
        } else if (colon == 0) {
            // 忽略伪头部
            continue;
        }
        final key = pair.substring(0, colon).trim();
        final value = pair.substring(colon + 1).trim();
        fields[key] = value;
    }
    return fields;
}
```
