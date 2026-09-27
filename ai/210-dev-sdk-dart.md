# Magpie SDK (Dart 版)

由于 Dart 语言对函数变量、空安全等特性更丰富，所以这里以 Dart 语言举例。

## 消息包

消息包分两大类： BridgePacket（桥接包）和 DirectPacket（直通包）。

### 消息包基类 MessagePacket

实现一切消息包的基础属性与方法。

```dart
class MessagePacket implements Magpie {
    MessagePacket(this.body, {
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
         
        required this.command
    });
    
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
    
    //
    // TODO: overrides
    //
}
```

### 桥接包 BridgePacket

客户端与服务器通讯的消息包，包括委托服务器中转的消息包。

```dart
final class BridgePacket extends MessagePacket {
    BridgePacket._(super.body, {
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
        
        required super.command
    }) : super(
        /// 桥接包 B=1
        bid: 1,
            
        /// 计算 headSize 和 bodySize
        headSize: calcHeadSize(bid: 1, cmd: cmd, dsn: dsn, ext: ext),
        bodySize: calcBodySize(body),
    );
    
    factory BridgePacket(Uint8List? body, {
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
         
        required int command
    }) => BridgePacket._(body,
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
        
        command: command
    );
    
    //
    //  TODO: 各种指令工厂
    //
    
    /// 生成普通数据包，通过服务器转发给对方
    /// （为了尽可能控制数据包体积，默认使用空 command 打包）
    factory BridgePacket.data(Uint8List data, {
        required int target,
        required int source,
        required int sn,
        required int index,
        required int count,
    }) => BridgePacket(data,
        act: 0,
        
        target: target,
        source: source,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: 0
    );
    
    /// 生成应答包，通过服务器转发“确认收到”给对方（info 为附加信息，默认为空）
    factory BridgePacket.copy(Magpie packet, [Uint8List? info]) => BridgePacket(info,
        act: 1,
        
        // bid 对调
        target: packet.source,
        source: packet.target,
        
        // 原样保留
        sn:    packet.sn,
        index: packet.index,
        count: packet.count,
        
        // 应答指令
        command: Command.COPY
    );
    
    // ...
    
}
```

### 直通包 DirectPacket

客户端与客户端直接通讯的消息包。

```dart
final class DirectPacket extends MessagePacket {
    DirectPacket._(super.body, {
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
        
        required super.command
    }) : super(
        /// 直通包 B=0, 无 bid
        bid: 0,
            
        /// 计算 headSize 和 bodySize
        headSize: calcHeadSize(bid: 0, cmd: cmd, dsn: dsn, ext: ext),
        bodySize: calcBodySize(body),
        
        target: 0,
        source: 0,
    );
    
    factory DirectPacket(Uint8List? body, {
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
         
        required int command
    }) => DirectPacket._(body,
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
        
        command: command
    );
    
    //
    //  TODO: 各种指令工厂
    //
    
    /// 生成普通数据包，直接发送给对方
    /// （为了尽可能控制数据包体积，默认使用空 command 打包）
    factory DirectPacket.data(Uint8List data, {
        required int sn,
        required int index,
        required int count,
    }) => DirectPacket(data,
        act: 0,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: 0
    );
    
    /// 生成应答包，直接发送“确认收到”给对方（info 为附加信息，默认为空）
    factory DirectPacket.copy(Magpie packet, [Uint8List? info]) => DirectPacket(info,
        act: 1,
        
        // 原样保留
        sn:    packet.sn,
        index: packet.index,
        count: packet.count,
        
        // 应答指令
        command: Command.COPY
    );
    
    // ...
    
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
}) => sn == 0 ? 0 : 1;
    
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
	Magpie? parse(Uint8List data) {
	    if (data.length < 8) {
	        assert(false, 'data error: $data');
	        return null;
	    }
	    // 1. 前 8 个字节的有效性检查
	    //    检查 Magic Code；
	    //    读出 flags，检查 E 合法性：E = type & 0x07（低 3 位，bit 3 不检查）；
	    //    读出 headSize 和 bodySize，然后与 flags 一起计算检查头长度合法性；
	    
	    // 2. 头参数的有效性检查
	    //    根据 flags 指示依次读出 target, source, sn, index, count, command 等参数；
	    //    检查各项参数是否越界；
	    
	    // 3. 读取 payload，然后创建消息包对象
	    return MessagePacket(...);
	}

}
```
