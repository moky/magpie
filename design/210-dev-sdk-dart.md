# Magpie Bridge SDK (Dart 示例)

由于 Dart 语言对函数变量、空安全等特性更丰富，所以这里以 Dart 语言举例。

## 消息包

消息包分两大类： BridgePacket（桥接包）和 DirectPacket（直连包）。

### 消息包基类 MessagePacket

实现一切消息包的基础属性与方法。

```dart
class MessagePacket implements Magpie {
    MessagePacket(this.buffer, {
        
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
        
        required this.payload
    });
    
    /// data package
    Uint8List? buffer;
    
    /// flags
    final int ack;
    final int bid;
    final int cmd;
    final int dsn;
    final int ext;
    
    final int headerLength;
    final int payloadLength;
    
    /// bid
    final int target;
    final int source;

    /// mid
    final int sn;
    final int index;
    final int count;

    final int command;
    
    final Uint8List? payload;
    
    // ...
    
    @override
    Uint8List pack() {
        Uint8List? binary = buffer;
        if (binary == null) {
            // TODO: 将各字段打包为网络字节序，更新 binary，然后缓存到 buffer
            buffer = binary;
        }
        return binary;
    }
}
```

### 桥接包 BridgePacket

客户端与服务器通信的消息包，包括委托服务器中转的消息包。

```dart
final class BridgePacket extends MessagePacket {
    BridgePacket._(super.buffer, {
        
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
        
        required super.payload
    }) : super(
        /// 桥接包 B=1
        bid: 1,
            
        /// 计算 headerLength 和 payloadLength
        headerLength: calcHeaderLength(bid: 1, cmd: cmd, dsn: dsn, ext: ext),
        payloadLength: calcPayloadLength(payload),
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
        
        Uint8List? payload
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
        
        payload: payload
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
        
        Uint8List? payload
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
        
        payload: payload
    );
    
    /// 第一次握手
    /// [source] 为预订 bid（可选）：0 表示普通申请（由服务器分配），
    /// 非 0 表示客户端希望预订该 bid（新建预订须 > 65535，若是 loopback 重握手复用之前的内定 bid，可传 = port ≤ 65535 的原值）。
    factory BridgePacket.syn(Uint8List? info, {
        int source = 0
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,  // 0 = 普通申请；非 0 = 预订 bid
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.SYN,
        
        payload: info
    );
    
    /// 第二次握手
    factory BridgePacket.synAck(Uint8List? info, {
        required int target,  // 服务器为该客户端分配的 bid
    }) => BridgePacket.create(
        ack: 1,
        
        target: target,
        source: 0,  // 这个包是服务器发给客户端的，所以这里 source = 0
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.SYN_ACK,
        
        payload: info
    );
    
    /// 第三次握手
    factory BridgePacket.ack(Uint8List? info, {
        required int source,  // 从第二次握手包中得到的 target
    }) => BridgePacket.create(
        ack: 1,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.ACK,
        
        payload: info
    );
    
    /// 失败
    /// 1. bid 分配失败：target = 期望的（预订）bid，info 仅含 time；
    /// 2. 第三次握手包缺失：target = 已分配的 bid，info 为 socket 信息（同 "SYN!"，含 time）；
    /// 3. 无法修改通行证： target = 已分配的 bid，info 为失败的 bid 列表（含 time）。
    factory BridgePacket.fail(Uint8List? info, {
        required int target,  // 客户端 bid（期望或已分配）
        int sn = 0,
        int index = 0,
        int count = 1,
    }) => BridgePacket.create(
        ack: 1,
        
        target: target,
        source: 0,  // 这个包是服务器发给客户端的，所以这里 source = 0
        
        sn:    sn,
        index: index,
        count: count,
        
        command: Command.FAIL,
        
        payload: info
    );
    
    /// 成功完成
    factory BridgePacket.done(Uint8List? info, {
        required int target,
        int sn = 0,
        int index = 0,
        int count = 1,
    }) => BridgePacket.create(
        ack: 1,
        
        target: target,
        source: 0,  // 这个包是服务器发给客户端的，所以这里 source = 0
        
        sn:    sn,
        index: index,
        count: count,
        
        command: Command.DONE,
        
        payload: info
    );
    
    /// 添加通行证
    factory BridgePacket.acpt(Uint8List? info, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.ACPT,
        
        payload: info
    );
    
    /// 撤销通行证
    factory BridgePacket.deny(Uint8List? info, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.DENY,
        
        payload: info
    );
    
    /// 心跳
    factory BridgePacket.ping(Uint8List? info, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.PING,
        
        payload: info
    );
    
    /// 心跳应答
    /// （packet 为收到的 ping 包；info 为应答数据区，遵循载荷文档格式（含 time 与 mp-verify），由调用方构造）
    factory BridgePacket.pong(Magpie packet, [Uint8List? info]) => BridgePacket.create(
        ack: 1,
        
        target: packet.source,
        source: packet.target,  // 0
        
        sn:    packet.sn,       // 0
        index: packet.index,    // 0
        count: packet.count,    // 1
        
        command: Command.PONG,
        
        payload: info
    );
    
    /// 第一次挥手
    factory BridgePacket.fin(Uint8List? info, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.FIN,
        
        payload: info
    );
    
    /// 第二次挥手
    /// （packet 为收到的 fin 包；info 为应答数据区，遵循载荷文档格式（含 time 与 mp-verify），由调用方构造）
    factory BridgePacket.finAck(Magpie packet, [Uint8List? info]) => BridgePacket.create(
        ack: 1,
        
        target: packet.source,
        source: packet.target,  // 0
        
        sn:    packet.sn,       // 0
        index: packet.index,    // 0
        count: packet.count,    // 1
        
        command: Command.FIN_ACK,
        
        payload: info
    );
    
    /// 无操作（保活/自愈）
    /// 用于意外收到 "FIN!" 时立即回复，以秒级恢复在线状态，无需应答
    factory BridgePacket.noop(Uint8List? info, {
        required int source,
    }) => BridgePacket.create(
        ack: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.NOOP,
        
        payload: info
    );
    
    /// 普通数据包，通过服务器转发给接收方
    factory BridgePacket.data(Uint8List data, {
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
        
        payload: data
    );
    
    /// 数据应答包，通过服务器转发“确认收到”给原发送方
    /// （packet 为收到的数据包；info 为附加信息，默认为空）
    factory BridgePacket.copy(Magpie packet, [Uint8List? info]) => BridgePacket.create(
        ack: 1,
        
        // bid 对调
        target: packet.source,
        source: packet.target,
        
        // 原样保留
        sn:    packet.sn,
        index: packet.index,
        count: packet.count,
        
        command: Command.COPY,  // “确认收到”
        
        payload: info
    );
    
}
```

### 直连包 DirectPacket

客户端与客户端直接通信的消息包。

```dart
final class DirectPacket extends MessagePacket {
    DirectPacket._(super.buffer, {
        
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
    }) : super(
        /// 直连包 B=0, 无 bid
        bid: 0,
            
        /// 计算 headerLength 和 payloadLength
        headerLength: calcHeaderLength(bid: 0, cmd: cmd, dsn: dsn, ext: ext),
        payloadLength: calcPayloadLength(payload),
        
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
        
        Uint8List? payload
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
        
        payload: payload
    );
    
    //
    //  TODO: 各种指令工厂，不包括 fail(), done(), acpt(), deny()
    //        （跟 BridgePacket 类似，除了没有 target 和 source 参数）
    //        包括：syn(), synAck(), ack(), ping(), pong(), noop(), fin(), finAck(), data(), copy()
    //
    
}
```

### 计算公式

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
    
static int calcPayloadLength(
    Uint8List? payload
) => payload?.length ?? 0;
    
static int calcCmd({
    required int command
}) => command == 0 ? 0 : 1;
    
static int calcDsn({
    required int sn
}) => sn == 0 ? 0 : 1;  // sn == 0 表示无 dsn（系统指令），数据包 sn 从 1 开始自增
    
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

## 消息包处理器

主要包括：有效性检查、解包和打包。

打包操作由 Magpie 接口的 pack() 函数实现。

### 处理器接口 MagpieParser

收到包之后，第一步先检查头部各项信息是否合规，然后读取各字段生成 Magpie 对象。

```dart
final class MessageParser implements MagpieParser {

	@override
	Magpie? parse(Uint8List buffer) {
	    if (buffer.length < 8) {
	        assert(false, 'data package error: $buffer');
	        return null;
	    }
	    // 1. 前 8 个字节的有效性检查
	    //    检查 Magic Code；
	    //    读出 flags（bid = (type >> 6) & 0x01），检查 E 合法性：E = type & 0x07（低 3 位，bit 3 不检查）；
	    //    E 只允许 0~4，取值 5/6/7 判定为错误包；
	    //    检查约束：E>0 时 D 必须为 1（D=0 且 E>0 判定为错误包）；
	    //    读出 headerLength 和 payloadLength，然后与 flags 一起计算检查头长度合法性；
	    
	    // 2. 头参数的有效性检查
	    //    根据 flags 指示依次读出 target, source, sn, index, count, command 等参数；
	    //    检查各项参数是否越界；
	    //    若 B=1 且 target 与 source 均非 0 且相等（转发包发往同一客户端），判定为错误包；
	    //    若 C=1，则 command 必须非 0（全 0 判定为错误包）；不校验 command 的具体取值（是否系统指令由上层判断）；
	    
	    // 3. 读取 payload，然后创建消息包对象
	    
	    if (bid == 0) {
	        return DirectPacket(buffer, ...);
	    } else {
	        return BridgePacket(buffer, ...);
	    }
	}

}
```
