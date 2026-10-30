# Magpie Bridge SDK (Dart 示例)

由于 Dart 语言对函数变量、空安全等特性更丰富，所以这里以 Dart 语言举例。

## 消息包

消息包分两大类： BridgePacket（桥接包）和 DirectPacket（直连包）。

### 消息包基类 MessagePacket

实现一切消息包的基础属性与方法。

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
    
    /// data package
    Uint8List? _buffer;
    
    /// flags
    final int ack;
    final int bid;
    final int cmd;
    final int dsn;
    final int ext;
    
    /// length
    final int headerLength;
    final int payloadLength;
    
    /// bid
    final int target;
    final int source;
    
    /// mid
    final int sn;
    final int index;
    final int count;
    
    /// command
    final int command;
    
    /// payload
    final Uint8List? payload;
    
    // ...
    
    @override
    Uint8List pack() {
        Uint8List? data = _buffer;
        if (data == null) {
            // TODO: 将各字段打包为网络字节序，更新 data，然后缓存到 buffer
            _buffer = data;
        }
        return data;
    }

    /// Clone this packet WITHOUT its attachment (附加校验码).
    /// Used by sign()/verify() so the HMAC is computed over the bare
    /// header + payload only. This is a packet-instance clone helper;
    /// it is distinct from the factory `copy(packet, [response])` that
    /// builds the "COPY" data-acknowledgment packet.
    MessagePacket copy();

}
```

### 桥接包 BridgePacket

客户端与服务器通信的消息包，包括委托服务器中转的消息包。

```dart
class BridgePacket extends MessagePacket {
    BridgePacket._(Uint8List? buffer, {
        
        required super.ack,
        // required super.bid,
        required super.cmd,
        required super.dsn,
        required super.ext,
        
        // required super.headerLength,
        // required super.payloadLength,
        
        required super.target,
        required super.source,
        
        required super.sn,
        required super.index,
        required super.count,
        
        required super.command,
        
        required super.payload,
    }) : super(buffer,
        
        /// 桥接包 B=1
        bid: 1,
            
        /// 计算 headerLength 和 payloadLength
        headerLength: calcHeaderLength(bid: 1, cmd: cmd, dsn: dsn, ext: ext),
        payloadLength: payload.length,
    );
    
    factory BridgePacket(Uint8List? buffer, {
        
        required int ack,
        // required int bid,
        // required int cmd,
        // required int dsn,
        // required int ext,
         
        // required int headerLength,
        // required int payloadLength,
         
        required int target,
        required int source,
         
        required int sn,
        required int index,
        required int count,
         
        required int command,
        
        required Uint8List? payload,
    }) => BridgePacket._(buffer,
        
        ack: ack,
        // bid: 1,
        cmd: calcCmd(command),
        dsn: calcDsn(sn),
        ext: calcExt(count),
        
        // headerLength: ...,
        // payloadLength: ...,
        
        target: target,
        source: source,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: command,
        
        payload: payload,
    );
    
    //
    //  Factory methods
    //
    
    factory BridgePacket.create({
        
        required int ack,
        // required int bid,
        // required int cmd,
        // required int dsn,
        // required int ext,
         
        // required int headerLength,
        // required int payloadLength,
         
        required int target,
        required int source,
         
        required int sn,
        required int index,
        required int count,
         
        required int command,
        
        required Uint8List? payload,
    }) => BridgePacket._(null,
        
        ack: ack,
        // bid: 1,
        cmd: calcCmd(command),
        dsn: calcDsn(sn),
        ext: calcExt(count),
        
        // headerLength: ...,
        // payloadLength: ...,
        
        target: target,
        source: source,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: command,
        
        payload: payload,
    );
```

### 命令枚举 Command

系统指令的 32 位无符号整数值由可读命令字符串按网络字节序（大端）转换得到（见 `110-design-type-cmd.md` 命令定义）。工厂方法统一通过下列枚举引用命令；`DATA` 可由空 command（C=0）打包，无需枚举值。

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

### 桥接包工厂 BridgePacketFactory

解析/创建客户端与服务器通信的消息包

```dart
class BridgePacketFactory {

    /// 第一次握手
    /// [source] 为预订 bid（可选）：0 表示普通申请（由服务器分配），
    /// 非 0 表示客户端希望预订该 bid（新建预订须 > 65535；
    /// 若是 loopback 重握手复用之前的内定 bid，且该 socket 记录尚未被回收，可传 = port ≤ 65535 的原值；
    /// 记录已回收时该 bid 不再可用，应传 0 重新申请）。
    BridgePacket syn(Uint8List? request, {
        int source = 0
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,       // 发给服务器
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.SYN,
        
        payload: request,
    );
    
    /// 第二次握手
    /// response 为载荷数据区（含 secret/token/token_time/UDP/time，
    /// 由服务器逻辑构造，纯 JSON 格式）
    BridgePacket synAck(Uint8List? response, {
        required int target,  // 服务器为该客户端分配的 bid
    }) => BridgePacket.create(
        ack: 1,
        
        target: target,
        source: 0,       // 来自服务器
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.SYN_ACK,
        
        payload: response,
    );
    
    /// 第三次握手
    /// response 原样回传第二次握手包中的 secret/token/token_time
    /// （数据区 time 取客户端当前时间），纯 JSON 格式
    BridgePacket ack(Uint8List? response, {
        required int source,  // 从第二次握手包中得到的 target
    }) => BridgePacket.create(
        ack: 1,
        
        target: 0,       // 发给服务器
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.ACK,
        
        payload: response,
    );
    
    /// 失败应答
    /// 服务器向客户端返回失败：target = 已分配的 bid；response 载荷按场景区分（bid 分配失败、对端离线、通行证修改失败等，具体格式见载荷文档）。
    BridgePacket fail(Uint8List? response, {
        required int target,  // 客户端 bid（期望或已分配）
        int sn = 0,
        int index = 0,
        int count = 1,
    }) => BridgePacket.create(
        ack: 1,
        
        target: target,
        source: 0,       // 来自服务器
        
        sn:    sn,
        index: index,
        count: count,
        
        command: Command.FAIL,
        
        payload: response,
    );
    
    /// 成功应答
    /// 服务器向客户端返回成功：target = 已分配的 bid；response 载荷按场景区分（如通行证修改成功回显实际写入的 bid 列表，具体格式见载荷文档）。
    BridgePacket done(Uint8List? response, {
        required int target,
        int sn = 0,
        int index = 0,
        int count = 1,
    }) => BridgePacket.create(
        ack: 1,
        
        target: target,
        source: 0,       // 来自服务器
        
        sn:    sn,
        index: index,
        count: count,
        
        command: Command.DONE,
        
        payload: response,
    );
    
    /// 添加通行证
    /// 允许通行的 source bid 列表放在 request（含 time）
    BridgePacket acpt(Uint8List? request, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,       // 发给服务器
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.ACPT,
        
        payload: request,
    );
    
    /// 撤销通行证
    /// 禁止通行的 source bid 列表放在 request（含 time）
    BridgePacket deny(Uint8List? request, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,       // 发给服务器
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.DENY,
        
        payload: request,
    );
    
    /// 心跳
    BridgePacket ping(Uint8List? request, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,       // 发给服务器
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.PING,
        
        payload: request,
    );
    
    /// 心跳应答
    /// （packet 为收到的 ping 包；response 为应答信息，遵循载荷文档格式（含 time），由调用方构造）
    BridgePacket pong(Magpie packet, [Uint8List? response]) => BridgePacket.create(
        ack: 1,
        
        /// bid 对调，原路返回
        target: packet.source,
        source: packet.target,  // 0
        
        // 原样保留
        sn:    packet.sn,       // 0
        index: packet.index,    // 0
        count: packet.count,    // 1
        
        command: Command.PONG,
        
        payload: response,
    );
    
    /// 第一次挥手
    BridgePacket fin(Uint8List? request, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,       // 发给服务器
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.FIN,
        
        payload: request,
    );
    
    /// 第二次挥手
    /// （packet 为收到的 fin 包；response 为应答信息，遵循载荷文档格式（含 time），由调用方构造）
    BridgePacket finAck(Magpie packet, [Uint8List? response]) => BridgePacket.create(
        ack: 1,
        
        /// bid 对调，原路返回
        target: packet.source,
        source: packet.target,  // 0
        
        // 原样保留
        sn:    packet.sn,       // 0
        index: packet.index,    // 0
        count: packet.count,    // 1
        
        command: Command.FIN_ACK,
        
        payload: response,
    );
    
    /// 无操作（保活/自愈）
    /// 用于意外收到 "FIN!" 时立即回复，以秒级恢复在线状态，无需应答（含 time）
    BridgePacket noop(Uint8List? request, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,       // 发给服务器
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.NOOP,
        
        payload: request,
    );
    
    /// 普通数据包，通过服务器转发给接收方
    BridgePacket data(Uint8List data, {
        required int target,
        required int source,
        required int sn,
        required int index,
        required int count,
    }) => BridgePacket.create(
        ack: 0,
        
        target: target,
        source: source,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: 0,  // 为了尽可能控制数据包体积，这里使用空 command 打包
        
        payload: data,
    );
    
    /// 数据应答包，通过服务器转发“确认收到”给原发送方
    /// （packet 为收到的数据包；response 为附加信息，默认为空）
    BridgePacket copy(Magpie packet, [Uint8List? response]) => BridgePacket.create(
        ack: 1,
        
        // bid 对调，原路返回
        target: packet.source,
        source: packet.target,
        
        // 原样保留
        sn:    packet.sn,
        index: packet.index,
        count: packet.count,
        
        command: Command.COPY,  // “确认收到”
        
        payload: response,
    );
    
    /// 对数据合法性进行校验，校验通过则返回相应的消息包
    /// （收到包后，先检查头部各项信息是否合规，然后读取各字段以生成 Magpie 对象）
	Magpie? parse(Uint8List buffer) {
	    if (buffer.length < 8) {
	        assert(false, 'data package error: $buffer');
	        return null;
	    }
	    // 1. 前 8 个字节的有效性检查
	    //    检查 Magic Code（buffer[0..3] == 'M','P',0,'\1'）；
	    //    读出 type 标志字节（偏移 4；其后偏移 5 为 header_length，偏移 6..7 为 payload_length）
	    //    并拆出本地标志位：
	    int type = buffer[4];
	    int ack = (type >> 7) & 0x01;
	    int bid = (type >> 6) & 0x01;
	    int cmd = (type >> 5) & 0x01;
	    int dsn = (type >> 4) & 0x01;
	    int ext = type & 0x07;
	    //    检查 E 合法性：E = type & 0x07（低 3 位，bit 3 不检查）；
	    //    E 只允许 0~4，取值 5/6/7 判定为错误包；
	    //    检查约束：E>0 时 D 必须为 1（D=0 且 E>0 判定为错误包）；
	    //    读出 headerLength 和 payloadLength，与 flags 一起计算检查头长度合法性；

	    // 2. 头参数的有效性检查
	    //    根据 flags 指示依次读出 target, source, sn, index, count, command 等参数（本地变量）；
	    //    检查各项参数是否越界：若 D=1，则 sn 必须非 0（全 0 判定为错误包）；E>0 时 count 必须 > 1，且 0 <= index < count，否则为错误包；
	    //    若 C=1，则 command 必须非 0（全 0 判定为错误包）；不校验 command 的具体取值（是否系统指令由上层判断）；
	    if (bid != 1) {
	        assert(false, 'not a bridge packet: ${buffer.length}');
	        return null;
	    }

	    // 3. 读取 payload，然后创建消息包对象
	    // TODO: 步骤 1/2 中已拆出的 ack/target/source/sn/index/count/command/payload
	    //       按下面的构造签名传入；buffer 为校验通过后的完整报文（含/不含 attachment
	    //       的差值判定见 docs/sdk.md 6.2）。
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
}
```

### 直连包 DirectPacket

客户端与客户端直接通信的消息包。

```dart
class DirectPacket extends MessagePacket {
    DirectPacket._(Uint8List? buffer, {
        
        required super.ack,
        // required super.bid,
        required super.cmd,
        required super.dsn,
        required super.ext,
        
        // required super.headerLength,
        // required super.payloadLength,
        
        // required super.target,
        // required super.source,
        
        required super.sn,
        required super.index,
        required super.count,
        
        required super.command,
        
        required super.payload
    }) : super(buffer,
        
        /// 直连包 B=0, 无 bid
        bid: 0,
            
        /// 计算 headerLength 和 payloadLength
        headerLength: calcHeaderLength(bid: 0, cmd: cmd, dsn: dsn, ext: ext),
        payloadLength: payload.length,
        
        target: 0,
        source: 0,
    );
    
    factory DirectPacket(Uint8List? buffer, {
        
        required int ack,
        // required int bid,
        // required int cmd,
        // required int dsn,
        // required int ext,
         
        // required int headerLength,
        // required int payloadLength,
         
        // required int target,
        // required int source,
         
        required int sn,
        required int index,
        required int count,
         
        required int command,
        
        required Uint8List? payload,
    }) => DirectPacket._(buffer,
        
        ack: ack,
        // bid: 0,
        cmd: calcCmd(command),
        dsn: calcDsn(sn),
        ext: calcExt(count),
        
        // headerLength: ...,
        // payloadLength: ...,
        
        // target: 0,
        // source: 0,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: command,
        
        payload: payload,
    );
    
    //
    //  Factory methods
    //
    
    factory DirectPacket.create({
        
        required int ack,
        // required int bid,
        // required int cmd,
        // required int dsn,
        // required int ext,
         
        // required int headerLength,
        // required int payloadLength,
         
        // required int target,
        // required int source,
         
        required int sn,
        required int index,
        required int count,
         
        required int command,
        
        required Uint8List? payload,
    }) => DirectPacket._(null,
        
        ack: ack,
        // bid: 0,
        cmd: calcCmd(command),
        dsn: calcDsn(sn),
        ext: calcExt(count),
        
        // headerLength: ...,
        // payloadLength: ...,
        
        // target: 0,
        // source: 0,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: command,
        
        payload: payload,
    );
```

### 直连包工厂 DirectPacketFactory

解析/创建客户端与客户端直接通信的消息包。

```dart
class DirectPacketFactory {
    
    /// 对数据合法性进行校验，校验通过则返回相应的消息包
    /// （收到包后，先检查头部各项信息是否合规，然后读取各字段以生成 Magpie 对象）
	Magpie? parse(Uint8List buffer) {
	    if (buffer.length < 8) {
	        assert(false, 'data package error: $buffer');
	        return null;
	    }
	    // 1. 前 8 个字节的有效性检查
	    //    检查 Magic Code（buffer[0..3] == 'M','P',0,'\1'）；
	    //    读出 type 标志字节（偏移 4）并拆出本地标志位：
	    int type = buffer[4];
	    int ack = (type >> 7) & 0x01;
	    int bid = (type >> 6) & 0x01;
	    int cmd = (type >> 5) & 0x01;
	    int dsn = (type >> 4) & 0x01;
	    int ext = type & 0x07;
	    //    检查 E 合法性：E = type & 0x07（低 3 位，bit 3 不检查）；
	    //    E 只允许 0~4，取值 5/6/7 判定为错误包；
	    //    检查约束：E>0 时 D 必须为 1（D=0 且 E>0 判定为错误包）；
	    //    读出 headerLength 和 payloadLength，与 flags 一起计算检查头长度合法性；

	    // 2. 头参数的有效性检查
	    //    根据 flags 指示依次读出 sn, index, count, command 等参数（本地变量；直连包无 target/source）；
	    //    检查各项参数是否越界：若 D=1，则 sn 必须非 0（全 0 判定为错误包）；E>0 时 count 必须 > 1，且 0 <= index < count，否则为错误包；
	    //    若 C=1，则 command 必须非 0（全 0 判定为错误包）；不校验 command 的具体取值（是否系统指令由上层判断）；
	    if (bid != 0) {
	        assert(false, 'not a direct packet: ${buffer.length}');
	        return null;
	    }

	    // 3. 读取 payload，然后创建消息包对象
	    // TODO: 步骤 1/2 中已拆出的 ack/sn/index/count/command/payload 按下面的构造签名传入；
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
    
    //
    //  TODO: 其他指令工厂跟 BridgePacket 类似，除了没有 target 和 source 参数
    //        包括：syn(), synAck(), ack(), ping(), pong(), fin(), finAck(), noop(), data(), copy()
    //        不包括：acpt(), deny(), fail(), done()
    //
    
}
```

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
