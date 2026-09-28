# Magpie SDK (Dart 示例)

由于 Dart 语言对函数变量、空安全等特性更丰富，所以这里以 Dart 语言举例。

## 消息包

消息包分两大类： BridgePacket（桥接包）和 DirectPacket（直通包）。

### 消息包基类 MessagePacket

实现一切消息包的基础属性与方法。

```dart
class MessagePacket implements Magpie {
    MessagePacket(this.buffer, {
        
        required this.act,
        required this.bid,
        required this.cmd,
        required this.dsn,
        required this.ext,
         
        required this.headSize,
        required this.bodySize,
         
        required this.target,
        required this.source,
         
        required this.sn,
        required this.index,
        required this.count,
         
        required this.command,
        
        required this.body
    });
    
    /// data package
    Uint8List? buffer;
    
    /// flags
    final int act;
    final int bid;
    final int cmd;
    final int dsn;
    final int ext;
    
    final int headSize;
    final int bodySize;
    
    /// bid
    final int target;
    final int source;

    /// mid
    final int sn;
    final int index;
    final int count;

    final int command;
    
    final Uint8List? body;
    
    // ...
    
    @override
    Uint8List pack() {
        Uint8List? binary = buffer;
        if (binary == null) {
            // TODO: 将各字段打包为网络字节序，并缓存到 buffer
            buffer = binary;
        }
        return binary;
    }
}
```

### 桥接包 BridgePacket

客户端与服务器通讯的消息包，包括委托服务器中转的消息包。

```dart
final class BridgePacket extends MessagePacket {
    BridgePacket._(super.buffer, {
        
        required super.act,
        // required super.bid,
        required super.cmd,
        required super.dsn,
        required super.ext,
        
        // required super.headSize,
        // required super.bodySize,

        required super.target,
        required super.source,
        
        required super.sn,
        required super.index,
        required super.count,
        
        required super.command,
        
        required super.body
    }) : super(
        /// 桥接包 B=1
        bid: 1,
            
        /// 计算 headSize 和 bodySize
        headSize: calcHeadSize(bid: 1, cmd: cmd, dsn: dsn, ext: ext),
        bodySize: calcBodySize(body),
    );
    
    factory BridgePacket(Uint8List? buffer, {
        
        required int act,
        // required int bid,
        // required int cmd,
        // required int dsn,
        // required int ext,
         
        // required int headSize,
        // required int bodySize,
         
        required int target,
        required int source,
         
        required int sn,
        required int index,
        required int count,
         
        required int command,
        
        Uint8List? body
    }) => BridgePacket._(buffer,
        
        act: act,
        // bid: 1,
        cmd: calcCmd(command),
        dsn: calcDsn(sn),
        ext: calcExt(count),
        
        // headSize: ...,
        // bodySize: ...,
        
        target: target,
        source: source,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: command,
        
        body: body
    );
    
    //
    //  Factory methods
    //
    
    /// 第一次握手
    /// [source] 为预订 bid（可选）：0 表示普通申请（由服务器分配），
    /// 非 0 表示客户端希望预订该 bid（新建预订须 > 65535，若是 loopback 重握手复用之前的内定 bid，可传 = port ≤ 65535 的原值）。
    factory BridgePacket.syn(Uint8List? info, {
        int source = 0
    }) => BridgePacket(null,
        act: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,  // 0 = 普通申请；非 0 = 预订 bid
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.SYN,
        
        body: info
    );
    
    /// 第二次握手
    factory BridgePacket.synAck(Uint8List? info, {
        required int target,  // 服务器为该客户端分配的 bid
    }) => BridgePacket(null,
        act: 1,
        
        target: target,
        source: 0,  // 这个包是服务器发给客户端的，所以这里 source = 0
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.SYN_ACK,
        
        body: info
    );
    
    /// 第三次握手
    factory BridgePacket.ack(Uint8List? info, {
        required int source,  // 从第二次握手包中得到的 target
    }) => BridgePacket(null,
        act: 1,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.ACK,
        
        body: info
    );
    
    /// 失败
    /// （packet 为收到的 syn 包；info 为附加信息，默认为 syn.body ）
    factory BridgePacket.fail(Magpie packet, [Uint8List? info]) => BridgePacket(null,
        act: 1,
        
        target: packet.source,
        source: packet.target,  // 0
        
        sn:    packet.sn,       // 0
        index: packet.index,    // 0
        count: packet.count,    // 1
        
        command: Command.FAIL,
        
        body: info ?? packet.body
    );
    
    /// 普通数据包，通过服务器转发给接收方
    factory BridgePacket.data(Uint8List data, {
        required int target,
        required int source,
        required int sn,
        required int index,
        required int count,
    }) => BridgePacket(null,
        act: 0,
        
        target: target,
        source: source,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: 0,  // 为了尽可能控制数据包体积，这里使用空 command 打包
        
        body: data
    );
    
    /// 数据应答包，通过服务器转发“确认收到”给原发送方
    /// （packet 为收到的数据包；info 为附加信息，默认为空）
    factory BridgePacket.copy(Magpie packet, [Uint8List? info]) => BridgePacket(null,
        act: 1,
        
        // bid 对调
        target: packet.source,
        source: packet.target,
        
        // 原样保留
        sn:    packet.sn,
        index: packet.index,
        count: packet.count,
        
        command: Command.COPY,  // “确认收到”
        
        body: info
    );
    
    /// 心跳
    factory BridgePacket.ping(Uint8List? info, {
        required int source,
    }) => BridgePacket(null,
        act: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.PING,
        
        body: info
    );
    
    /// 心跳应答
    /// （packet 为收到的 ping 包；info 为附加信息，默认为 ping.body ）
    factory BridgePacket.pong(Magpie packet, [Uint8List? info]) => BridgePacket(null,
        act: 1,
        
        target: packet.source,
        source: packet.target,  // 0
        
        sn:    packet.sn,       // 0
        index: packet.index,    // 0
        count: packet.count,    // 1
        
        command: Command.PONG,
        
        body: info ?? packet.body
    );
    
    /// 第一次挥手
    factory BridgePacket.fin(Uint8List? info, {
        required int source,
    }) => BridgePacket(null,
        act: 0,
        
        target: 0,  // 这个包是发给服务器的指令，所以这里 target = 0
        source: source,
        
        sn:    0,
        index: 0,
        count: 1,
        
        command: Command.FIN,
        
        body: info
    );
    
    /// 第二次挥手
    /// （packet 为收到的 fin 包；info 为附加信息，默认为 fin.body ）
    factory BridgePacket.finAck(Magpie packet, [Uint8List? info]) => BridgePacket(null,
        act: 1,
        
        target: packet.source,
        source: packet.target,  // 0
        
        sn:    packet.sn,       // 0
        index: packet.index,    // 0
        count: packet.count,    // 1
        
        command: Command.FIN_ACK,
        
        body: info ?? packet.body
    );
    
}
```

### 直通包 DirectPacket

客户端与客户端直接通讯的消息包。

```dart
final class DirectPacket extends MessagePacket {
    DirectPacket._(super.buffer, {
        
        required super.act,
        // required super.bid,
        required super.cmd,
        required super.dsn,
        required super.ext,
        
        // required super.headSize,
        // required super.bodySize,

        // required super.target,
        // required super.source,
        
        required super.sn,
        required super.index,
        required super.count,
        
        required super.command,
        
        required super.body
    }) : super(
        /// 直通包 B=0, 无 bid
        bid: 0,
            
        /// 计算 headSize 和 bodySize
        headSize: calcHeadSize(bid: 0, cmd: cmd, dsn: dsn, ext: ext),
        bodySize: calcBodySize(body),
        
        target: 0,
        source: 0,
    );
    
    factory DirectPacket(Uint8List? buffer, {
        
        required int act,
        // required int bid,
        // required int cmd,
        // required int dsn,
        // required int ext,
         
        // required int headSize,
        // required int bodySize,
         
        // required int target,
        // required int source,
         
        required int sn,
        required int index,
        required int count,
         
        required int command,
        
        Uint8List? body
    }) => DirectPacket._(buffer,
        act: act,
        // bid: 0,
        cmd: calcCmd(command),
        dsn: calcDsn(sn),
        ext: calcExt(count),
        
        // headSize: ...,
        // bodySize: ...,
        
        // target: 0,
        // source: 0,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: command,
        
        body: body
    );
    
    //
    //  TODO: 各种指令工厂
    //        （跟 BridgePacket 类似，除了没有 target 和 source 参数）
    //
    
}
```

### 计算公式

```dart
static int calcType({
    required int act,
    required int bid,
    required int cmd,
    required int dsn,
    required int ext,
}) => (act << 7) | (bid << 6) | (cmd << 5) | (dsn << 4) | (ext & 0x07);
    
static int calcHeadSize({
    required int bid,
    required int cmd,
    required int dsn,
    required int ext,
}) => 8 + 8*bid + 4*dsn + 2*ext + 4*cmd;
    
static int calcBodySize(
    Uint8List? body
) => body?.length ?? 0;
    
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
	    //    读出 flags，检查 E 合法性：E = type & 0x07（低 3 位，bit 3 不检查）；
	    //    检查约束：E>0 时 D 必须为 1（D=0 且 E>0 判定为错误包）；
	    //    读出 headSize 和 bodySize，然后与 flags 一起计算检查头长度合法性；
	    
	    // 2. 头参数的有效性检查
	    //    根据 flags 指示依次读出 target, source, sn, index, count, command 等参数；
	    //    检查各项参数是否越界；
	    
	    // 3. 读取 payload，然后创建消息包对象
	    return MessagePacket(buffer, ...);
	}

}
```
