# Magpie Bridge SDK

核心消息接口命名为 `Magpie`，其基类为 `MessagePacket`——网络中传输的每个消息包都是一个 Magpie。消息包分两大类：

- **BridgePacket（桥接包）**：客户端与服务器相互发送的消息包（包括由服务器中转的消息包），须携带附加校验码；
- **DirectPacket（直连包）**：客户端之间直接发送的消息包，不需要校验码（数据合法性由应用层负责）。

本文档合并定义 SDK 全部接口：Magpie/MessagePacket、工厂方法、计算公式、附加校验码（sign/verify/ReliablePacket）、解析器，并以 Dart 为例给出实现要点。SDK 包括 Java、Python、Dart 等语言版本，接口一致。

---

## 1. 核心接口 Magpie

所有属性均为只读（不含 setter）。

| 成员 | 类型 | 说明 |
|------|------|------|
| target | int | 目标 bid |
| source | int | 来源 bid |
| sn | int | 数据序列号 |
| index | int | 分包编号 |
| count | int | 分包总数 |
| command | int | 命令 |
| payload | bytes | 数据载荷 |
| pack() | bytes | 生成网络数据包 |

---

## 2. 消息包基类 MessagePacket

实现一切消息包的基础属性与方法。所有属性只读。

| 成员 | 说明 |
|------|------|
| version | 协议版本，固定 "1.0" |
| ack | 应答标志位（0/1） |
| bid | 桥接标志位（0/1） |
| cmd | 命令标志位（0/1，普通数据包默认 0） |
| dsn | 序列号标志位（0/1） |
| ext | 额外参数长度；解包 E = type & 0x07（低 3 位）允许 0~4；打包为字节对齐仅取 0/2/4 |
| headerLength | 协议头长度（8 ~ 32） |
| payloadLength | 载荷长度（0 ~ 1024，**发送端构造约束**；解析端不以此拒绝，只校验 MSS） |
| isAck() | 是否为应答包 |
| hasBid() | 是否包含 bid（与服务器通信） |
| hasCmd() | 是否包含命令（普通数据包默认 false） |
| hasDsn() | 是否包含数据序列号 |
| hasExt() | 是否包含额外分包参数 |
| copy() | 复制当前消息包（不携带 attachment） |

```dart
class MessagePacket implements Magpie {
    MessagePacket(this._buffer, {
        required this.ack,
        required this.bid,
        required this.cmd,
        required this.dsn,
        required this.ext,
        required this.headerLength,
        required this.payloadLength,
        required this.target,
        required this.source,
        required this.sn,
        required this.index,
        required this.count,
        required this.command,
        required this.payload,
    });

    Uint8List? _buffer;   // 打包缓存

    final int ack, bid, cmd, dsn, ext;
    final int headerLength, payloadLength;
    final int target, source;
    final int sn, index, count;
    final int command;
    final Uint8List? payload;

    @override
    Uint8List pack() {
        Uint8List? data = _buffer;
        if (data == null) {
            // 将各字段打包为网络字节序（见计算公式），更新 data 并缓存
            _buffer = data;
        }
        return data;
    }
}
```

---

## 3. 消息包工厂

在两个工具接口 `BridgePacket` 与 `DirectPacket` 上分别定义静态工厂方法，按协议调用 `create()` 创建各类消息包：

| 指令 | BridgePacket (C-S) | DirectPacket (C-C) | 说明 |
|------|--------------------|--------------------|------|
| 握手 | syn(source, request) | syn(request) | source 为预订 bid |
| | synAck(target, response) | synAck(response) | target 为新分配 bid |
| | ack(source, response) | ack(response) | |
| 结果 | fail(target, response) | - | 失败应答 |
| | done(target, response) | - | 成功应答 |
| 权限 | acpt(source, request) | - | 允许 bid_list 通行 |
| | deny(source, request) | - | 禁止 bid_list 通行 |
| 心跳 | ping(source, request) | ping(request) | |
| | pong(magpie, response) | pong(magpie, response) | 应答参数从 magpie 复制 |
| 挥手 | fin(source, request) | fin(info, request) | |
| | finAck(magpie, response) | finAck(magpie, response) | 应答参数从 magpie 复制 |
| 无操作 | noop(source, request) | noop(request) | 无操作保活（如意外 "FIN!" 后的自愈），无需应答 |
| 数据 | data(target, source, sn, index, count, payload) | data(sn, index, count, payload) | |
| | copy(magpie, response) | copy(magpie, response) | 应答参数从 magpie 复制 |

说明：

1. 第一次握手时可填 source 作为预订 bid（可选）；预订失败（被占用/非法/服务器已满）时服务器回复 "FAIL"，由客户端决定重新申请或放弃；
2. 除 "DATA" 外（payload 需承载文件数据），其余指令包均可携带可选参数 request/response 作为载荷附加信息；
3. 系统指令载荷为 JSON 字符串（须含发送方时间戳 "time"），所有指令（含应答）均须携带发送方当前时间戳（秒），不允许为空；
4. DirectPacket 无 acpt/deny/fail/done 工厂（这些指令只与服务器通信）。

### 3.1 BridgePacket 要点（Dart 示例）

```dart
class BridgePacket extends MessagePacket {
    // 桥接包 B=1；headerLength 由公式计算；payloadLength = payload.length

    /// 第一次握手：source 为预订 bid（可选，0 = 由服务器分配）
    factory BridgePacket.syn(Uint8List? request, {int source = 0}) => ...;

    /// 第二次握手：target 为服务器分配的 bid
    factory BridgePacket.synAck(Uint8List? response, {required int target}) => ...;

    /// 第三次握手：原样回传第二次握手包中的 secret/token/token_time
    factory BridgePacket.ack(Uint8List? response, {required int source}) => ...;

    factory BridgePacket.fail(Uint8List? response, {required int target}) => ...;
    factory BridgePacket.done(Uint8List? response, {required int target}) => ...;
    factory BridgePacket.acpt(Uint8List? request, {required int source}) => ...;
    factory BridgePacket.deny(Uint8List? request, {required int source}) => ...;
    factory BridgePacket.ping(Uint8List? request, {required int source}) => ...;
    factory BridgePacket.fin(Uint8List? request, {required int source}) => ...;
    factory BridgePacket.noop(Uint8List? request, {required int source}) => ...;

    /// 应答类工厂：bid 对调、原路返回，其余字段从原包复制
    factory BridgePacket.pong(Magpie packet, [Uint8List? response]) => ...;
    factory BridgePacket.finAck(Magpie packet, [Uint8List? response]) => ...;
    factory BridgePacket.copy(Magpie packet, [Uint8List? response]) => ...;

    /// 普通数据包：command = 0（空 command 打包，控制体积）
    factory BridgePacket.data(Uint8List data, {
        required int target, required int source,
        required int sn, required int index, required int count,
    }) => ...;
}
```

### 3.2 直连包 DirectPacket 要点

无 target/source 参数（B=0）；`bid: 0, target: 0, source: 0`；工厂含 syn()/synAck()/ack()/ping()/pong()/fin()/finAck()/noop()/data()/copy()；**不含** acpt()/deny()/fail()/done()。

---

## 4. 计算公式

```dart
/// 类型字节：A(7) B(6) C(5) D(4) E(低 3 位)
static int calcType({required int ack, required int bid, required int cmd,
                     required int dsn, required int ext})
    => (ack << 7) | (bid << 6) | (cmd << 5) | (dsn << 4) | (ext & 0x07);

/// 协议头长度：N = 8 + 8B + 4D + 2E + 4C
static int calcHeaderLength({required int bid, required int cmd,
                             required int dsn, required int ext})
    => 8 + 8*bid + 4*dsn + 2*ext + 4*cmd;

/// 命令标志：command 为 0 时 C=0
static int calcCmd({required int command}) => command == 0 ? 0 : 1;

/// 序列号标志：sn 为 0 时 D=0（系统指令）
static int calcDsn({required int sn}) => sn == 0 ? 0 : 1;

/// 分包参数宽度：count ≥ 65536 → E=4；count ≥ 2 → E=2；否则 E=0
static int calcExt({required int count}) {
    if (count >= 65536) return 4;
    if (count >= 2) return 2;
    assert(count == 1, 'packet count error: $count');
    return 0;
}
```

---

## 5. 附加校验码（Attachment）

### 5.1 HMAC-SHA256

```dart
/// Compute HMAC-SHA256
/// [secret]: HMAC key
/// [message]: raw binary message
/// returns 32-byte HMAC result as Uint8List
Uint8List hmacSha256({required Uint8List secret, required Uint8List message}) {
    final hmac = Hmac(sha256, secret);
    final digest = hmac.convert(message);
    return Uint8List.fromList(digest.bytes);
}
```

### 5.2 签名（BridgePacket.sign）

只升级 BridgePacket（直连包不需要 verify）：

```dart
class BridgePacket extends MessagePacket {
    /// 对 (header + payload) 计算 HMAC-SHA256，返回带校验码的包
    ReliablePacket sign(Uint8List secret) {
        // 1. 先剔除原 attachment（如果有），再打包为二进制（有缓存直接复用）
        final data = copy().pack();
        // 2. HMAC-SHA256
        final verify = hmacSha256(secret: secret, message: data);
        // 3. 返回带签名的包
        return ReliablePacket(data, ..., attachment: verify);
    }
}
```

### 5.3 带校验码子类 ReliablePacket

```dart
class ReliablePacket extends BridgePacket {
    ReliablePacket(Uint8List? buffer, {
        required super.ack, ..., required super.payload,
        required this.attachment,
    }) : super(buffer);

    /// verify（32 字节 HMAC-SHA256）
    final Uint8List? attachment;

    bool verify(Uint8List secret) {
        final digest = attachment;
        if (digest == null || digest.length != 32) return false;
        if (secret.isEmpty) return false;
        // 1. 打包原始报文（已剔除 attachment，与 sign 时的 data 一致）
        final data = copy().pack();
        // 2. HMAC-SHA256
        final computed = hmacSha256(secret: secret, message: data);
        // 3. 常量时间对比，防计时攻击（禁止直接 == 比较）
        return _constantTimeByteEq(digest, computed);
    }
}

/// 常量时间字节比较
bool _constantTimeByteEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
        diff |= a[i] ^ b[i];
    }
    return diff == 0;
}
```

---

## 6. 消息包解析器（Parser）

实现 `MagpieParser` 接口，对收到的完整数据包进行校验与解析。

```dart
final class MessageParser implements MagpieParser {
    @override
    Magpie? parse(Uint8List buffer, {Uint8List? secret}) {
        if (buffer.length < 8) { ... return null; }

        // 1. 前 8 字节有效性检查
        //    Magic Code；type 标志位（bid = (type >> 6) & 0x01）；
        //    E = type & 0x07（bit 3 不检查）：只允许 0~4，5/6/7 为错误包；
        //    E>0 时 D 必须为 1（否则错误包）；
        //    headerLength/payloadLength 与 flags 计算一致；

        // 2. 头参数有效性检查
        //    依次读出 target/source/sn/index/count/command；
        //    E>0 时 count 必须 > 1 且 0 <= index < count；
        //    C=1 时 command 必须非 0（不校验是否系统指令，由上层判断）；

        // 3. 长度与附加校验码判定
        final size = headerLength + payloadLength;
        final tail = buffer.length - size;
        if (tail < 0) { ... return null; }           // 连 header+payload 都不够
        if (bid == 0) {
            assert(tail == 0);                        // 直连包无校验码
            return DirectPacket(buffer, ...);
        } else if (tail == 0) {
            return BridgePacket(buffer, ...);         // 桥接包无校验码（握手阶段例外：SYN?/SYN!/基础模式 ACK!/无 secret 的 FAIL，见协议文档 5.1）
        }
        assert(tail == 32);                           // 桥接包 + 32B 校验码
        final attachment = buffer.sublist(size);
        buffer = buffer.sublist(0, size);
        return ReliablePacket(buffer, ..., attachment: attachment);
    }
}
```

**解析判定规则**（UDP 包天然完整，无粘包问题）：

- 差值（实际包长 − header − payload）**既不是 0 也不是 32** → 错误包，丢弃；
- 差值为 0 → 整个 data 放入 buffer，attachment 为空；
- 差值为 32 → 前段为报文，尾部 32 字节作为 attachment。

---

## 7. 工程目录

### Java SDK

- 依赖：Java 8；
- 工程配置：`name = 'Magpie'`、`group = 'io.github.moky'`；
- 根目录：`magpie/sdk-java/`。

### Python SDK

- 依赖：Python >= 3.6；
- 工程配置：`name='magpie-bridge'`；
- 根目录：`magpie/sdk-py/`；
- 代码目录：`magpie/sdk-py/magpie_bridge/protocol/`（协议定义）、`magpie/sdk-py/magpie_bridge/magpie/`（工具类）；
- Python 版服务器与 Python 版 SDK 共用一个库 `magpie-bridge`。

### Dart SDK

- 依赖：`sdk: '>=3.0.0 <4.0.0'`；
- 工程配置：`name: magpie-bridge`；
- 根目录：`magpie/sdk-dart/`。
