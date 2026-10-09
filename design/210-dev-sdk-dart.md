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
    
    /// body
    final Payload payload;
    
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
}
```

### 桥接包 BridgePacket

客户端与服务器通信的消息包，包括委托服务器中转的消息包。

```dart
final class BridgePacket extends MessagePacket {
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
        
        required Payload payload,
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
        
        required Payload payload,
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
    
    /// 第一次握手
    /// [source] 为预订 bid（可选）：0 表示普通申请（由服务器分配），
    /// 非 0 表示客户端希望预订该 bid（新建预订须 > 65535，若是 loopback 重握手复用之前的内定 bid，可传 = port ≤ 65535 的原值）。
    factory BridgePacket.syn(Payload? request, {
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
    /// response 为载荷数据区（含 UDP、token、token_time，由服务器逻辑构造；
    /// 文本头 mp-secret 携带握手密钥，由调用方加入）
    factory BridgePacket.synAck(Payload? response, {
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
    /// response 原样回传第二次握手包中的 token/token_time（数据区 time 取
    /// 客户端当前时间；文本头 mp-secret 携带握手密钥，由调用方加入）
    factory BridgePacket.ack(Payload? response, {
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
    
    /// 失败
    /// 1. bid 分配失败：target = 期望的（预订）bid；response 仅含 time；
    /// 2. "ACK!"包缺失：target = 期望或已分配的 bid；response 为 socket 信息（含 time，不含 Content-Type 和 Content-Length）；
    /// 3. 无法修改通行证：target = 已分配的 bid；response 为失败的 bid 列表（含 time）。
    factory BridgePacket.fail(Payload? response, {
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
    
    /// 成功完成
    /// 修改通行证：target = 已分配的 bid；response 为请求的 bid 列表（含 time）。
    factory BridgePacket.done(Payload? response, {
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
    factory BridgePacket.acpt(Payload? request, {
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
    factory BridgePacket.deny(Payload? request, {
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
    factory BridgePacket.ping(Payload? request, {
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
    /// （packet 为收到的 ping 包；response 为应答信息，遵循载荷文档格式（含 time 与 mp-verify），由调用方构造）
    factory BridgePacket.pong(Magpie packet, [Payload? response]) => BridgePacket.create(
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
    factory BridgePacket.fin(Payload? request, {
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
    /// （packet 为收到的 fin 包；response 为应答信息，遵循载荷文档格式（含 time 与 mp-verify），由调用方构造）
    factory BridgePacket.finAck(Magpie packet, [Payload? response]) => BridgePacket.create(
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
    factory BridgePacket.noop(Payload? request, {
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
        
        payload: data,
    );
    
    /// 数据应答包，通过服务器转发“确认收到”给原发送方
    /// （packet 为收到的数据包；response 为附加信息，默认为空）
    factory BridgePacket.copy(Magpie packet, [Payload? response]) => BridgePacket.create(
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
    
}
```

### 直连包 DirectPacket

客户端与客户端直接通信的消息包。

```dart
final class DirectPacket extends MessagePacket {
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
        
        required Payload payload,
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
        
        required Payload payload,
    }) => DirectPacket._(null,
        
        ack: ack,
        // bid: 1,
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
    //  TODO: 其他指令工厂跟 BridgePacket 类似，除了没有 target 和 source 参数
    //        包括：syn(), synAck(), ack(), ping(), pong(), fin(), finAck(), noop(), data(), copy()
    //        不包括：acpt(), deny(), fail(), done()
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
	    //    读出 flags（其中 bid = (type >> 6) & 0x01）；
	    //    检查 E 合法性：E = type & 0x07（低 3 位，bit 3 不检查）；
	    //    E 只允许 0~4，取值 5/6/7 判定为错误包；
	    //    检查约束：E>0 时 D 必须为 1（D=0 且 E>0 判定为错误包）；
	    //    读出 headerLength 和 payloadLength，与 flags 一起计算检查头长度合法性；
	    
	    // 2. 头参数的有效性检查
	    //    根据 flags 指示依次读出 target, source, sn, index, count, command 等参数；
	    //    检查各项参数是否越界；
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
