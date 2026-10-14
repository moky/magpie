# SDK 设计

核心消息接口命名为 `Magpie`，其基类为 `MessagePacket`——网络中传输的每个消息包都是一个 Magpie。消息包分两大类：`BridgePacket`（桥接包，客户端与服务器互发、含服务器中转的包）和 `DirectPacket`（直连包，客户端之间直连互发）。

- [Magpie 接口](#magpie-接口)
- [MessagePacket 基类](#messagepacket-基类)
- [工厂方法](#工厂方法)
- [计算公式](#计算公式)
- [解析器](#解析器)
- [Dart 示例](#dart-示例)
- [工程目录](#工程目录)


## Magpie 接口

所有属性只读（不含 setter）。

| 成员 | 类型 | 说明 |
|------|------|------|
| `target` | 属性 | 目标 bid |
| `source` | 属性 | 来源 bid |
| `sn` | 属性 | 数据序列号 |
| `index` | 属性 | 分包编号 |
| `count` | 属性 | 分包总数 |
| `command` | 属性 | 命令 |
| `payload` | 属性 | 载荷字节 |
| `pack()` | 方法 | 序列化为可直接上 UDP 的 `Uint8List` |


## MessagePacket 基类

在 Magpie 基础上扩展协议标志位与长度字段：

| 成员 | 说明 |
|------|------|
| `version` | 协议版本，固定 `"1.0"` |
| `ack` / `bid` / `cmd` / `dsn` | 标志位，取值 0/1 |
| `ext` | 分包宽度，解包时 `E = type & 0x07`（0~4）；打包时仅取 0/2/4 |
| `headerLength` | 协议头长度，8~32 |
| `payloadLength` | 载荷长度（发送端构造约束 0~1024；解析端只校验 MSS） |
| `isAck` / `hasBid` / `hasCmd` / `hasDsn` / `hasExt` | 便捷判定谓词 |


## 工厂方法

两类消息包各暴露静态工厂方法。`request`/`response` 为可选附加 JSON 载荷（`data` 除外）。所有系统指令载荷都必须包含 `"time"`。

| 类别 | BridgePacket（C-S） | DirectPacket（C-C） | 备注 |
|------|---------------------|---------------------|------|
| 握手 | `syn(source, request)` | `syn(request)` | source 为预订 bid（可选） |
| | `synAck(target, response)` | `synAck(response)` | target 为新分配 bid |
| | `ack(source, response)` | `ack(response)` | |
| 结果 | `fail(target, response)` | — | |
| | `done(target, response)` | — | |
| 通行证 | `acpt(source, request)` | — | |
| | `deny(source, request)` | — | |
| 心跳 | `ping(source, request)` | `ping(request)` | |
| | `pong(magpie, response)` | `pong(magpie, response)` | 应答字段从 magpie 复制 |
| 挥手 | `fin(source, request)` | `fin(request)` | |
| | `finAck(magpie, response)` | `finAck(magpie, response)` | 应答字段从 magpie 复制 |
| 无操作 | `noop(source, request)` | `noop(request)` | 不应答保活 / 自愈 |
| 数据 | `data(target, source, sn, index, count, payload)` | `data(sn, index, count, payload)` | |
| | `copy(magpie, response)` | `copy(magpie, response)` | 应答字段从 magpie 复制 |


## 计算公式

```dart
static int calcType({required int ack, required int bid,
                     required int cmd, required int dsn, required int ext}) =>
    (ack << 7) | (bid << 6) | (cmd << 5) | (dsn << 4) | (ext & 0x07);

static int calcHeaderLength({required int bid, required int cmd,
                             required int dsn, required int ext}) =>
    8 + 8 * bid + 4 * dsn + 2 * ext + 4 * cmd;

static int calcCmd({required int command}) => command == 0 ? 0 : 1;
static int calcDsn({required int sn})       => sn == 0 ? 0 : 1;

static int calcExt({required int count}) {
  if (count >= 65536) return 4;
  if (count >= 2)     return 2;
  assert(count == 1, 'packet count error: $count');
  return 0;
}
```


## 解析器

```dart
abstract class MagpieParser {
  /// 校验失败返回 null
  Magpie? parse(Uint8List buffer);
}
```

校验顺序：

1. 缓冲区 >= 8 字节；校验 Magic Code；从 type 读出各标志位。
2. 校验 `E = type & 0x07` ∈ 0..4；拒绝 E>0 且 D=0 的组合。
3. 用 `calcHeaderLength(...)` 重算 N，与 `header_length` 字段比对；再校验 `N + payload_length` 与实际长度是否一致。
4. C=1 时 command 必须非 0（不在这里判断命令语义）。
5. 按顺序读出各可变字段并做边界校验。
6. B=0 创建 `DirectPacket`，否则创建 `BridgePacket`（若尾部有 32 字节附加校验码则创建 `ReliablePacket`，见 [security.md](security.md)）。


## Dart 示例

```dart
class MessagePacket implements Magpie {
  MessagePacket(this._buffer, {
    required this.ack, required this.bid, required this.cmd,
    required this.dsn, required this.ext,
    required this.headerLength, required this.payloadLength,
    required this.target, required this.source,
    required this.sn, required this.index, required this.count,
    required this.command, required this.payload,
  });

  Uint8List? _buffer;
  final int ack, bid, cmd, dsn, ext;
  final int headerLength, payloadLength;
  final int target, source, sn, index, count, command;
  final Uint8List? payload;

  @override
  Uint8List pack() {
    final data = _buffer;
    if (data == null) {
      // TODO: serialize all fields big-endian, cache into _buffer.
    }
    return _buffer!;
  }
}
```

`BridgePacket` 私有构造固定 `bid = 1`，并自动计算 header/payload 长度；各工厂方法通过上面的公式推导标志位。数据包使用 `command: 0`（C=0）以省略 4 字节字段：

```dart
factory BridgePacket.data(Uint8List data,
        {required int target, required int source,
         required int sn, required int index, required int count}) =>
    BridgePacket.create(
      ack: 0, target: target, source: source,
      sn: sn, index: index, count: count,
      command: 0, // empty command, omit the 4-byte field
      payload: data,
    );
```

`DirectPacket` 固定 `bid = 0`，不含 target/source。其余直连工厂与 `BridgePacket` 类似（无 `fail`/`done`/`acpt`/`deny`）。


## 工程目录

| SDK | 依赖版本 | 工程根目录 | 备注 |
|-----|----------|------------|------|
| Java | Java 8 | `sdk-java/` | gradle: `io.github.moky:Magpie` |
| Python | >= 3.6 | `sdk-py/` | 包名 `magpie-bridge`；`protocol/` + `magpie/`，与服务器共用 |
| Dart | >= 3.0.0 < 4.0.0 | `sdk-dart/` | 包名 `magpie-bridge` |
