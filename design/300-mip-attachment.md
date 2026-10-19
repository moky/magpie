# Magpie Improvement Proposal‌ 附加校验码

Magpie Protocol 核心协议层只定义了基础消息包格式，不包括整包校验码。

## 数据包结构升级

这里通过在原协议尾部追加一个 32 字节校验码的方式，
以实现对前面的基础协议包（header + body）进行 HMAC-SHA256 校验的需求。

     0                   1                   2                   3
     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                                                               |
    |                     header (8 ~ 32 Bytes)                     |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                                                               |
    |                    payload (0 ~ 1024 Bytes)                   |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                                                               |
    |                   attachment (0 or 32 Bytes)                  |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

其中 header 为原协议包头，所有字段定义不变；payload 为原协议载荷，
原协议包长度由 headerLength + payloadLength 得出，不再恒等于整个 UDP 包的数据长度。

即在原来的协议基础上，再追加一个 32 字节的 attachment 作为消息校验码（verify）。

## SDK 升级

由于直通包不需要 verify（其数据合法性由客户端应用负责），
所以对于升级后的协议，只需要升级 BridgePacket 相关部分的代码即可。

### 1. 升级 MessagePacket 类

增加 copy() 功能。

```dart
class MessagePacket implements Magpie {
    // ...
    
    // protected
    MessagePacket copy() => MessagePacket(_buffer,
        
        ack: ack,
        bid: bid,
        cmd: cmd,
        dsn: dsn,
        ext: ext,
        
        headerLength:  headerLength,
        payloadLength: payloadLength,
        
        target: target,
        source: source,
        
        sn:    sn,
        index: index,
        count: count,
        
        command: command,
        
        payload: payload,
    );
    
}
```

### 2. 升级 BridgePacket 类

增加 sign(secret) 功能。

```dart
import 'package:crypto/crypto.dart';


/// Compute HMAC-SHA256
/// [secret]: HMAC key
/// [message]: raw binary message
/// returns 32-byte HMAC result as Uint8List
Uint8List hmacSha256({required Uint8List secret, required Uint8List message}) {
  final hmac = Hmac(sha256, secret);
  final digest = hmac.convert(message);
  return Uint8List.fromList(digest.bytes);
}


class BridgePacket extends MessagePacket {
    // ...
    
    ReliablePacket sign(Uint8List secret) {
        // 1. 先剔除原 attachment 字段（如果有），
        //    再打包为二进制（如果 buffer 不为空则直接复用）
        final data = copy().pack();
        
        // 2. HMAC-SHA256
        final verify = hmacSha256(secret: secret, message: data);
        
        // 3. 返回带签名的包
        return ReliablePacket(data,
            
            ack: ack,
            ...
            payload: payload,
            
            attachment: verify,
        );
    }
}
```

### 3. 扩展 BridgePacket，增加带校验码的子类 ReliablePacket

（直通包不需要 verify）

```dart
class ReliablePacket extends BridgePacket {
    ReliablePacket(Uint8List? buffer, {
        
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
        
        required this.attachment,
    }) : super(buffer);
    
    /// verify
    final Uint8List? attachment;
    
    bool verify(Uint8List secret) {
        final digest = attachment;
        if (digest == null || digest.length != 32) {
            assert(false, 'verify error: ${digest?.length}');
            return false;
        } else if (secret.isEmpty) {
            assert(false, 'verify error: secret is empty');
            return false;
        }
        // 1. 打包原始报文（已剔除 attachment，和 sign 时的 data 保持一致）
        final data = copy().pack();
        
        // 2. HMAC-SHA256
        final computed = hmacSha256(secret: secret, message: data);
        
        // 3. 常量时间对比，防计时攻击，禁止直接使用 digest == computed
        return _constantTimeByteEq(digest, computed);
    }
    
}

/// 常量时间字节比较
bool _constantTimeByteEq(Uint8List a, Uint8List b) {
    if (a.length != b.length) {
        return false;
    }
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
}
```

### 4. 实现 MagpieParser 接口

更新最后的创建条件判断。

```dart
final class MessageParser implements MagpieParser {

    @override
    Magpie? parse(Uint8List buffer, {Uint8List? secret}) {
        // 1. 前 8 个字节的有效性检查
        //    ...
        //    读出 headerLength 和 payloadLength ...
        final size = headerLength + payloadLength;
        final tail = buffer.length - size;
        // tail < 0: 数据包长度不足（连 header + payload 都不够），判定为错误包
        if (tail < 0) {
            assert(false, 'data length error: ${buffer.length} < $headerLength + $payloadLength');
            return null;
        }
        
        // 2. 头参数的有效性检查
        //    ...
        
        // 3. 读取 payload，然后创建消息包对象
        
        if (bid == 0) {
            assert(tail == 0, 'data length error: ${buffer.length} != $headerLength + $payloadLength');
            return DirectPacket(buffer, ...);
        } else if (tail == 0) {
            return BridgePacket(buffer, ...);
        }
        assert(tail == 32, 'data length error: ${buffer.length} != $headerLength + $payloadLength + 32');
        final attachment = buffer.sublist(size);
        buffer = buffer.sublist(0, size);
        return ReliablePacket(buffer, ..., attachment: attachment);
    }

}
```

由于收到的 UDP 包一定是完整的（彼此独立，不存在 TCP 的粘包问题），所以收到一个数据包（data）之后，先按 header 校验规则进行处理，
校验通过之后，用取得的 header_length 和 payload_length 计算实际包长度 packet_length，然后和收到的 UDP 包 data_length 比较：

- 如果长度差既不是 0 也不是 32，则判定为错误包，直接丢弃；
- 如果长度差为 0，则整个 data 放入 MessagePacket 的 buffer，attachment 为空；
- 否则将 data 切成两段：前面的 packet_length 字节放入 MessagePacket 的 buffer，后面的 32 字节当成 attachment 一起返回。

## MSS 与附加层

扩展后的协议中，MSS 校验（见核心协议文档）作用于**整个 UDP 载荷**：
header + payload + attachment <= 1232，即任何数据包的总 IP 包大小均不超过 IPv6 最小 MTU 1280，
防分片保证与扩展前一致（attachment 计入校验后，不存在"基础包达标但整包超限"的漏洞）。

- 扩展前：载荷 1024 时，32 + 1024 = 1056，距 MSS（1232）缓冲 176 字节；
- 扩展后：32 + 1024 + 32 = 1088，距 MSS（1232）缓冲 144 字节，比扩展前少 32 字节；
- 该缓冲仍足以覆盖一层中等开销隧道（如 WireGuard 60~80 字节）而无分片风险；
- 若发送载荷超过 1024（接收端允许、但发送端不建议），叠加 32 字节附加层后缓冲进一步缩小，发送方需自行评估分片概率。
