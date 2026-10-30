# Magpie Bridge SDK

这里定义基础库的关键接口和类实现。

## 消息包定义

核心消息接口命名为 Magpie，其基类为 MessagePacket，即每一个在网络中传输的消息包就是一个 Magpie。

消息包分两大类： BridgePacket（桥接包）和 DirectPacket（直连包）。前者是客户端与服务器相互发送的消息包（包括由服务器中转的消息包），后者是客户端之间直接发送的消息包

### 核心接口 Magpie

所有属性均为只读（不含 setter）

- 属性（只读）
	- target  : 目标 bid
	- source  : 来源 bid
	- sn      : 数据序列号
	- index   : 分包编号
	- count   : 分包总数
	- command : 命令
	- payload : 数据载荷
- 方法
	- pack()  : 生成网络数据包

### 实现类 MessagePacket

所有属性均为只读（不含 setter）

- 扩展属性（只读）
	- version : 协议版本，固定值 "1.0"（**仅 SDK 侧元数据，不序列化进 8–32 字节协议头**；线上协议头只携带 Magic Code `MP\0\1`，见协议文档）
	- ack : 应答标志位，取值范围 0 或 1
	- bid : 桥接标志位，取值范围 0 或 1
	- cmd : 命令标志位，取值范围 0 或 1 （普通数据包默认取 0）
	- dsn : 序列号标志位，取值范围 0 或 1
	- ext : 额外参数长度，解包时 E = type & 0x07（低 3 位），允许 0~4；打包时为字节对齐仅取 0/2/4
	- headerLength  : 协议头长度，取值范围 8 - 32
	- payloadLength : 载荷长度，取值范围 0 - 1024（**发送端构造约束**；解析端不以此拒绝，只校验 MSS）
- 扩展方法
	- isAck  : 是否为应答包
	- hasBid : 是否包含 bid（门牌号），即是否与服务器通信
	- hasCmd : 是否包含命令（普通数据包默认为 false）
	- hasDsn : 是否包含数据序列号
	- hasExt : 是否包含额外分包参数
	- copy() : 复制当前消息包（**不携带 attachment 附加校验码**；与工厂方法 `copy(magpie, response)` 构造 "COPY" 数据应答包的含义不同，注意区分）

## 消息包工厂

分别为 BridgePacket 和 DirectPacket 各定义一个工厂类，用于创建对应的消息包：

|     | BridgePacketFactory      | DirectPacketFactory      | 说明                 |
|-----|--------------------------|--------------------------|----------------------|
| 握手 | syn(source, request)     | syn(request)             | source 为预订 bid（可选，0 = 由服务器分配） |
|     | synAck(target, response) | synAck(response)         | target 为新分配 bid   |
|     | ack(source, response)    | ack(response)            | source 取自第二次握手包的 target |
| 结果 | fail(target, response)   | -                        | 失败应答；sn/index/count 为可选超集（见下注） |
|     | done(target, response)   | -                        | 成功应答；sn/index/count 为可选超集（见下注） |
| 权限 | acpt(source, request)    | -                        | 允许 bid_list 通行    |
|     | deny(source, request)    | -                        | 禁止 bid_list 通行    |
| 心跳 | ping(source, request)    | ping(request)            |                     |
|     | pong(magpie, response)   | pong(magpie, response)   | 应答参数从 magpie 复制 |
| 挥手 | fin(source, request)     | fin(request)             |                     |
|     | finAck(magpie, response) | finAck(magpie, response) | 应答参数从 magpie 复制 |
| 无操作 | noop(source, request)  | noop(request)            | 无操作保活（如意外 "FIN!" 后的自愈回复，无需应答） |
| 数据 | data(target, source, sn, index, count, payload) | data(sn, index, count, payload) | |
|     | copy(magpie, response)   | copy(magpie, response)   | 应答参数从 magpie 复制 |
| 解析器 | parse(data)            | parse(data)              | 检查校验 data 并析出消息包 |

> 表格为便于对比的简化签名（先列 bid 角色参数，再列载荷）；完整实现见 210-dev-sdk-dart.md（Dart 命名参数示例，载荷为第一个参数）。
>
> **fail/done 可选超集**：`fail`/`done` 工厂额外接受可选 `sn`/`index`/`count`（默认 `0/0/1`），是 `110-design-type-cmd.md` 说明 2/5 允许的未来扩展位；当前系统指令场景 D=0、不携带 sn，服务器校验不锁定 B/D/E，收到时忽略这些字段。

说明：

1. 在服务器上只有 BridgePacketFactory，客户端则两者都需要；
2. 在服务器场景中，第一次握手时可填 source 作为预订（期望）bid，可选；预订失败（被占用/非法/服务器已满）时服务器回复 "FAIL" 指令包，由客户端自行决定重新申请或放弃；
3. 服务器场景中的通配授权（"ACPT *"）与清空通行证（"DENY *"）通过 acpt/deny 的 request 载荷传入通配标记 [1, 2, 3]（严格按序）实现，工厂方法本身不变（见载荷文档）；
4. 除了 "DATA" 消息包之外（因其 payload 需要承载文件数据），其余各指令包在实现时均可携带一个可选参数 request/response 放在载荷当作附加信息；
5. 系统指令的载荷遵循载荷文档定义的格式（纯 JSON 字符串，必须包含发送方时间戳 "time"），所有指令（含应答）均须携带发送方当前时间戳（秒），不允许为空。

### 消息包解析接口

接收到完整的数据包之后，由相应消息工厂的 parse(data) 接口进行校验解析：

1. 服务器上只有 BridgePacketFactory 对象，客户端上则需要根据数据包来源决定选择对应的工厂；
2. 根据协议依次检查 Magic Code、取得 type 中的各项标志位以及长度等信息，然后对数据合法性进行校验；
3. 如果数据包校验不通过，则返回空，否则用解析出来的所有参数，创建对应的消息包对象并返回（服务器场景下的消息包可以有附加校验码）；解析层只做包级校验与类型判定，**不验证**附加校验码——验证由上层流程取得密钥后调用 ReliablePacket.verify() 完成（见附加校验码提案）。

> 由于服务器场景下只有 BridgePacket，所以 BridgePacketFactory 的 parse() 函数遇到 B=0 的可以直接丢弃；
> 反之，DirectPacketFactory 的 parse() 函数遇到 B=1 的也可以直接丢弃。
