# SDK 设计

核心消息接口命名为 `Magpie`，其基类为 `MessagePacket`——网络中传输的每个消息包都是一个 Magpie。消息包分两大类：`BridgePacket`（桥接包，客户端与服务器互发、含服务器中转的包）和 `DirectPacket`（直连包，客户端之间直连互发）。

- [Magpie 接口](#magpie-接口)
- [MessagePacket 基类](#messagepacket-基类)
- [工厂方法](#工厂方法)
- [计算公式](#计算公式)
- [解析器](#解析器)
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
| `version` | 协议版本，固定 "1.0" |
| `ack` | 应答标志位（0/1） |
| `bid` | 桥接标志位（0/1） |
| `cmd` | 命令标志位（0/1，普通数据包默认 0） |
| `dsn` | 序列号标志位（0/1） |
| `ext` | 额外参数长度；解包 `E = type & 0x07`（允许 0~4），打包为字节对齐仅取 0/2/4 |
| `headerLength` | 协议头长度（8~32） |
| `payloadLength` | 载荷长度（0~1024，发送端构造约束；解析端不以此拒绝，只校验 MSS） |
| `isAck` / `hasBid` / `hasCmd` / `hasDsn` / `hasExt` | 各标志位判断方法 |

`BridgePacket` 固定 B=1（含 target/source bid 字段），`DirectPacket` 固定 B=0（无 bid 字段）。


## 工厂方法

在 `BridgePacket` 与 `DirectPacket` 上分别定义静态工厂方法，按协议调用 `create()` 创建各类消息包：

| | BridgePacket (C-S) | DirectPacket (C-C) | 说明 |
|---|--------------------|--------------------|------|
| 握手 | `syn(source, request)` | `syn(request)` | source 为预订 bid |
| | `synAck(target, response)` | `synAck(response)` | target 为新分配 bid |
| | `ack(source, response)` | `ack(response)` | |
| 结果 | `fail(target, response)` | - | 失败应答 |
| | `done(target, response)` | - | 成功应答 |
| 权限 | `acpt(source, request)` | - | 允许 bid_list 通行 |
| | `deny(source, request)` | - | 禁止 bid_list 通行 |
| 心跳 | `ping(source, request)` | `ping(request)` | |
| | `pong(magpie, response)` | `pong(magpie, response)` | 应答参数从 magpie 复制 |
| 挥手 | `fin(source, request)` | `fin(info, request)` | |
| | `finAck(magpie, response)` | `finAck(magpie, response)` | 应答参数从 magpie 复制 |
| 无操作 | `noop(source, request)` | `noop(request)` | 无操作保活（如意外 "FIN!" 后的自愈回复，无需应答） |
| 数据 | `data(target, source, sn, index, count, payload)` | `data(sn, index, count, payload)` | |
| | `copy(magpie, response)` | `copy(magpie, response)` | 应答参数从 magpie 复制 |

说明：

1. 第一次握手可填 source 作为预订（期望）bid，可选：0 表示普通申请（由服务器分配）；非 0 表示希望预订该 bid（新建预订须 > 65535，loopback 重握手可传 = port ≤ 65535 的原内定 bid）；记录已回收时该 bid 不再可用，应传 0 重新申请；预订失败（被占用/非法/服务器已满）时服务器回 "FAIL"，由客户端自行决定重新申请或放弃；
2. 除 "DATA"（payload 需承载文件数据）外，其余指令包均可携带可选参数 request/response 放在载荷当作附加信息；
3. 系统指令载荷遵循载荷文档定义的 JSON 格式，必须包含发送方时间戳 `"time"`（秒），所有指令（含应答）均须携带、不允许为空；
4. "DATA" 为控制体积使用空 command 打包（C=0）；应答型工厂（`pong`/`finAck`/`copy`）从收到的 magpie 复制 bid 对调等参数，原路返回。


## 计算公式

```dart
static int calcType({
    required int ack,
    required int bid,
    required int cmd,
    required int dsn,
    required int ext,
}) => (ack << 7) | (bid << 6) | (cmd << 5) | (dsn << 4) | (ext & 0x07);

static int calcHeaderLength({
    required int bid,
    required int cmd,
    required int dsn,
    required int ext,
}) => 8 + 8*bid + 4*dsn + 2*ext + 4*cmd;

static int calcCmd({
    required int command
}) => command == 0 ? 0 : 1;

static int calcDsn({
    required int sn
}) => sn == 0 ? 0 : 1;  // sn == 0 表示无 dsn（系统指令）

static int calcExt({
    required int count
}) {
    if (count >= 65536) {
        return 4;
    } else if (count >= 2) {
        return 2;
    } else {
        assert(count == 1, 'packet count error: $count');
        return 0;
    }
}
```


## 解析器

收到完整数据包后由解析器 `MagpieParser.parse(data)` 校验解析：

1. 前 8 字节有效性检查：检查 Magic Code；读出标志位（`bid = (type >> 6) & 0x01`）；检查 E 合法性（`E = type & 0x07`，只允许 0~4，5/6/7 判定错误包；bit 3 不检查）；检查约束（E>0 时 D 必须为 1）；读出 headerLength/payloadLength 并与标志位计算核对；
2. 头参数有效性检查：按标志位依次读出 target/source/sn/index/count/command；检查越界（E>0 时 count > 1 且 0 <= index < count）；C=1 时 command 必须非 0（具体取值不校验，是否系统指令由上层判断）；
3. 读取 payload，按 B 值创建消息包对象并返回：B=0 → `DirectPacket`，B=1 → `BridgePacket`（启用附加校验码后：tail=0 → `BridgePacket`，tail=32 → `ReliablePacket`，见安全扩展文档）；校验不通过返回空。


## 工程目录

SDK 包括 Java、Python、Dart 等多个语言版本，其中 Python 版服务器与 Python 版 SDK 共用一个库 `magpie-bridge`。

| 语言 | 工程根目录 | 关键参数 |
|------|-----------|----------|
| Java | `magpie/sdk-java/` | Java 8；name=`Magpie`，group=`io.github.moky` |
| Python | `magpie/sdk-py/` | Python >= 3.6；name=`magpie-bridge`；协议代码在 `protocol/`，工具类在 `magpie/` |
| Dart | `magpie/sdk-dart/` | sdk >= 3.0.0 < 4.0.0；name=`magpie-bridge` |
