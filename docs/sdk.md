# Magpie Bridge SDK

核心消息接口命名为 `Magpie`，其基类为 `MessagePacket`——网络中传输的每个消息包都是一个 Magpie。消息包分两大类：

- **BridgePacket（桥接包）**：客户端与服务器相互发送的消息包（包括由服务器中转的消息包），须携带附加校验码；
- **DirectPacket（直连包）**：客户端之间直接发送的消息包，不需要校验码（数据合法性由应用层负责）。

本文档合并定义 SDK 全部接口：Magpie/MessagePacket、工厂类（*PacketFactory）、计算公式、附加校验码（sign/verify/ReliablePacket）、解析接口（*PacketFactory.parse），并以 Dart 为例给出实现要点。SDK 包括 Java、Python、Dart 等语言版本，接口一致。

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
| version | 协议版本，固定 "1.0"（仅 SDK 侧元数据，不序列化进 8–32 字节协议头；线上协议头只携带 Magic Code `MP\0\1`） |
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

在 `BridgePacketFactory` 与 `DirectPacketFactory` 上分别定义工厂方法，按协议调用 `create()` 创建各类消息包（工厂类同时承担解析，见 6 节）：

| 指令 | BridgePacketFactory (C-S) | DirectPacketFactory (C-C) | 说明 |
|------|--------------------|--------------------|------|
| 握手 | syn(source, request) | syn(request) | source 为预订 bid（可选，0 = 由服务器分配） |
| | synAck(target, response) | synAck(response) | target 为新分配 bid |
| | ack(source, response) | ack(response) | source 取自第二次握手包的 target |
| 结果 | fail(target, response) | - | 失败应答；sn/index/count 为可选超集（见下注） |
| | done(target, response) | - | 成功应答；sn/index/count 为可选超集（见下注） |
| 权限 | acpt(source, request) | - | 允许 bid_list 通行 |
| | deny(source, request) | - | 禁止 bid_list 通行 |
| 心跳 | ping(source, request) | ping(request) | |
| | pong(magpie, response) | pong(magpie, response) | 应答参数从 magpie 复制 |
| 挥手 | fin(source, request) | fin(request) | |
| | finAck(magpie, response) | finAck(magpie, response) | 应答参数从 magpie 复制 |
| 无操作 | noop(source, request) | noop(request) | 无操作保活（如意外 "FIN!" 后的自愈），无需应答 |
| 数据 | data(target, source, sn, index, count, payload) | data(sn, index, count, payload) | |
| | copy(magpie, response) | copy(magpie, response) | 应答参数从 magpie 复制 |

> 表格为便于对比的简化签名（先列 bid 角色参数，再列载荷）；完整实现见 3.1 节 Dart 示例（命名参数风格，载荷为第一个参数）。
>
> `fail`/`done` 的 `sn`/`index`/`count` 为可选超集（默认 `0/0/1`）：当前系统指令场景 D=0、不携带 sn，服务器校验不锁定 B/D/E，收到时忽略这些字段。

说明：

1. 第一次握手时可填 source 作为预订 bid（可选）；预订失败（被占用/非法/服务器已满）时服务器回复 "FAIL"，由客户端决定重新申请或放弃；
2. 除 "DATA" 外（payload 需承载文件数据），其余指令包均可携带可选参数 request/response 作为载荷附加信息；
3. 系统指令载荷为 JSON 字符串（须含发送方时间戳 "time"），所有指令（含应答）均须携带发送方当前时间戳（秒），不允许为空；
4. 通配授权（"ACPT *"）与清空通行证（"DENY *"）通过 acpt/deny 的 request 载荷传入通配标记 [1, 2, 3]（严格按序）实现，工厂方法本身不变（见协议文档 6.2）；
5. DirectPacketFactory 无 acpt/deny/fail/done 工厂方法（这些指令只与服务器通信）。

### 3.0 命令枚举 Command

系统指令的 32 位无符号整数值由可读命令字符串按网络字节序（大端）转换得到（命令定义见协议文档；权威映射见 `design/210-dev-sdk-dart.md` §命令枚举）。工厂方法统一通过下列枚举引用命令；`DATA` 由空 command（C=0）打包，无需枚举值。

| 枚举符号 | 线上命令字符串 | 32 位值（大端） | 标志位 | 说明 |
|---|---|---|---|---|
| `Command.SYN` | `"SYN?"` | `0x53594E3F` | A=0, C=1, D=0, E=0 | 第 1 次握手（请求连接） |
| `Command.SYN_ACK` | `"SYN!"` | `0x53594E21` | A=1, C=1, D=0, E=0 | 第 2 次握手（收到请求） |
| `Command.ACK` | `"ACK!"` | `0x41434B21` | A=1, C=1, D=0, E=0 | 第 3 次握手（确认连接） |
| `Command.FAIL` | `"FAIL"` | `0x4641494C` | A=1, C=1 | 失败应答 |
| `Command.DONE` | `"DONE"` | `0x444F4E45` | A=1, C=1 | 成功应答 |
| `Command.ACPT` | `"ACPT"` | `0x41435054` | A=0, B=1, C=1, D=0, E=0 | 接受（添加通行证） |
| `Command.DENY` | `"DENY"` | `0x44454E59` | A=0, B=1, C=1, D=0, E=0 | 拒绝（删除通行证） |
| `Command.PING` | `"PING"` | `0x50494E47` | A=0, C=1, D=0, E=0 | 发起心跳 |
| `Command.PONG` | `"PONG"` | `0x504F4E47` | A=1, C=1, D=0, E=0 | 心跳应答 |
| `Command.FIN` | `"FIN?"` | `0x46494E3F` | A=0, C=1, D=0, E=0 | 第 1 次挥手（请求关闭） |
| `Command.FIN_ACK` | `"FIN!"` | `0x46494E21` | A=1, C=1, D=0, E=0 | 第 2 次挥手（确认关闭）；枚举名 `FIN_ACK` 对应线上字符串 `"FIN!"` |
| `Command.NOOP` | `"NOOP"` | `0x4E4F4F50` | A=0, C=1, D=0, E=0 | 无操作 |
| `Command.COPY` | `"COPY"` | `0x434F5059` | A=1, C=1, D=1 | 确认收到（数据应答包） |
| —（空 command，C=0） | `""` ≡ `"DATA"` | `0`（字段不存在） | A=0, C=0, D=1 | 普通数据包；`"DATA"` 显式值为 `0x44415441`（A=0, C=1, D=1） |

```dart
/// System command identifiers; [value] is the big-endian 32-bit integer
/// packed into the 4-byte command field (C=1). Empty command (C=0) is
/// represented by value 0 and means "DATA".
enum Command {
    SYN(0x53594E3F),
    SYN_ACK(0x53594E21),
    ACK(0x41434B21),
    FAIL(0x4641494C),
    DONE(0x444F4E45),
    ACPT(0x41435054),
    DENY(0x44454E59),
    PING(0x50494E47),
    PONG(0x504F4E47),
    FIN(0x46494E3F),
    FIN_ACK(0x46494E21),  // wire string "FIN!"
    NOOP(0x4E4F4F50),
    COPY(0x434F5059);

    final int value;
    const Command(this.value);
}
```

### 3.1 BridgePacketFactory 要点（Dart 示例）

```dart
class BridgePacketFactory {
    /// 第一次握手：source 为预订 bid（可选，0 = 由服务器分配）
    BridgePacket syn(Uint8List? request, {int source = 0}) => BridgePacket.create(
        ack: 0, target: 0, source: source, sn: 0, index: 0, count: 1,
        command: Command.SYN, payload: request);

    /// 第二次握手：target 为服务器分配的 bid
    BridgePacket synAck(Uint8List? response, {required int target}) => ...;

    /// 第三次握手：原样回传第二次握手包中的 secret/token/token_time
    BridgePacket ack(Uint8List? response, {required int source}) => ...;

    BridgePacket fail(Uint8List? response, {required int target}) => ...;
    BridgePacket done(Uint8List? response, {required int target}) => ...;
    BridgePacket acpt(Uint8List? request, {required int source}) => ...;
    BridgePacket deny(Uint8List? request, {required int source}) => ...;
    BridgePacket ping(Uint8List? request, {required int source}) => ...;
    BridgePacket fin(Uint8List? request, {required int source}) => ...;
    BridgePacket noop(Uint8List? request, {required int source}) => ...;

    /// 应答类工厂：bid 对调、原路返回，其余字段从原包复制
    BridgePacket pong(Magpie packet, [Uint8List? response]) => ...;
    BridgePacket finAck(Magpie packet, [Uint8List? response]) => ...;
    BridgePacket copy(Magpie packet, [Uint8List? response]) => ...;

    /// 普通数据包：command = 0（空 command 打包，控制体积）
    BridgePacket data(Uint8List data, {
        required int target, required int source,
        required int sn, required int index, required int count,
    }) => ...;
}
```

### 3.2 直连包工厂 DirectPacketFactory 要点

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

## 6. 消息包解析接口

解析职责由工厂承担：`BridgePacketFactory.parse()` 与 `DirectPacketFactory.parse()` 各自校验并析出所属类型的消息包。两工厂共用同一套基础校验（见 6.1）；`BridgePacketFactory.parse()` 面向服务器场景（由**预处理线程**调用，只做包级校验与类型判定、不验证附加校验码，见 6.2）；`DirectPacketFactory.parse()` 面向客户端直连场景（见 6.3）。

### 6.1 基础校验（两工厂共用）

收到完整数据包后，按顺序校验，任一失败返回 null：

1. **前 8 字节有效性检查**：
   - Magic Code；读出 type 标志字节（偏移 4）并拆出本地标志位 `ack = (type >> 7) & 0x01`、`bid = (type >> 6) & 0x01`、`cmd = (type >> 5) & 0x01`、`dsn = (type >> 4) & 0x01`；
   - `E = type & 0x07`（bit 3 不检查）：只允许 0~4，5/6/7 为错误包；
   - E>0 时 D 必须为 1（否则错误包）；
   - headerLength（偏移 5）/payloadLength（偏移 6..7）与 flags 计算一致；
2. **头参数有效性检查**：
   - 依次读出 target/source/sn/index/count/command；
   - 若 D=1，则 sn 必须非 0；E>0 时 count 必须 > 1 且 0 <= index < count；
   - C=1 时 command 必须非 0（不校验是否系统指令，由上层判断）；
3. **长度与附加校验码判定**：按 6.2/6.3 各自的 B 位与差值规则处理。

### 6.2 BridgePacketFactory.parse（服务器场景）

服务器在**预处理线程**中调用本接口，该线程不查询分配表、拿不到客户端密钥，因此解析层只做包级校验与类型判定、**不验证**附加校验码——验证由管理/转发线程取得 `record.secret` 后调用 `ReliablePacket.verify()` 完成（见服务器文档 3 节）：

```dart
class BridgePacketFactory {
    Magpie? parse(Uint8List buffer) {
        if (buffer.length < 8) {
            assert(false, 'data package error: $buffer');
            return null;
        }
        // 1. 前 8 字节有效性检查（见 6.1）
        //    Magic Code（buffer[0..3] == 'M','P',0,'\1'）；
        //    读出 type 标志字节（偏移 4；其后偏移 5 为 header_length，偏移 6..7 为 payload_length）
        //    并拆出本地标志位：
        int type = buffer[4];
        int ack = (type >> 7) & 0x01;
        int bid = (type >> 6) & 0x01;
        int cmd = (type >> 5) & 0x01;
        int dsn = (type >> 4) & 0x01;
        int ext = type & 0x07;
        int headerLength = buffer[5];
        int payloadLength = (buffer[6] << 8) | buffer[7];
        //    E 合法性：E = type & 0x07（bit 3 不检查），只允许 0~4，5/6/7 为错误包；
        //    E>0 时 D 必须为 1；headerLength/payloadLength 与 flags 计算一致；
        // 2. 头参数有效性检查（见 6.1）
        //    按 flags 依次读出 target/source/sn/index/count/command（本地变量）；
        //    D=1 时 sn 必须非 0；E>0 时 count 必须 > 1 且 0 <= index < count；
        //    C=1 时 command 必须非 0（不校验是否系统指令，由上层判断）；
        if (bid != 1) {
            assert(false, 'not a bridge packet: ${buffer.length}');
            return null;
        }
        // 3. 长度与附加校验码判定
        final size = headerLength + payloadLength;
        final tail = buffer.length - size;
        if (tail < 0) {
            assert(false, 'packet too short: ${buffer.length}');  // 连 header+payload 都不够
            return null;
        }
        if (tail == 0) {
            // 桥接包无校验码（握手阶段例外：SYN?/SYN!/基础模式 ACK!/无 secret 的 FAIL，见协议文档 5.1）
            // TODO: 步骤 1/2 中已拆出的 target/source/sn/index/count/command/payload 按下述签名传入。
            return BridgePacket(buffer,
                ack: ack,
                target: target,
                source: source,
                sn: sn,
                index: index,
                count: count,
                command: command,
                payload: payload,
            );
        }
        assert(tail == 32);                           // 桥接包 + 32B 校验码
        final attachment = buffer.sublist(size);
        buffer = buffer.sublist(0, size);
        // TODO: 同上，target/source/sn/index/count/command/payload 由步骤 1/2 读出。
        return ReliablePacket(buffer,
            ack: ack,
            target: target,
            source: source,
            sn: sn,
            index: index,
            count: count,
            command: command,
            payload: payload,
            attachment: attachment,
        );
    }
}
```

### 6.3 DirectPacketFactory.parse（客户端直连场景）

```dart
class DirectPacketFactory {
    Magpie? parse(Uint8List buffer) {
        if (buffer.length < 8) {
            assert(false, 'data package error: $buffer');
            return null;
        }
        // 1/2. 基础校验（见 6.1）
        //    Magic Code；读出 type 标志字节（偏移 4）并拆出本地标志位：
        int type = buffer[4];
        int ack = (type >> 7) & 0x01;
        int bid = (type >> 6) & 0x01;
        int cmd = (type >> 5) & 0x01;
        int dsn = (type >> 4) & 0x01;
        int ext = type & 0x07;
        int headerLength = buffer[5];
        int payloadLength = (buffer[6] << 8) | buffer[7];
        //    E 合法性、E>0 时 D 必须为 1、头参数越界等校验规则同 6.1；
        if (bid != 0) {
            assert(false, 'not a direct packet: ${buffer.length}');
            return null;
        }
        // 3. 直连包无校验码：差值必须为 0
        final size = headerLength + payloadLength;
        if (buffer.length != size) {
            assert(false, 'direct packet length mismatch: ${buffer.length} != $size');
            return null;
        }
        // TODO: 步骤 1/2 中已拆出的 ack/sn/index/count/command/payload 按下述签名传入；
        //       直连包 target/source 恒为 0（B=0，无 bid 字段）。
        return DirectPacket(buffer,
            ack: ack,
            sn: sn,
            index: index,
            count: count,
            command: command,
            payload: payload,
        );
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
