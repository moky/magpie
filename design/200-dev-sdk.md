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

**载荷接口 Payload**

> 数据载荷分 3 大类：原始字节类 RawPayload、请求类 Request 和 应答类 Response。

- 属性（只读）
	- length  : 载荷长度
- 方法
	- pack()  : 生成网络数据包

### 实现类 MessagePacket

所有属性均为只读（不含 setter）

- 扩展属性（只读）
	- version : 协议版本，固定值 "1.0"
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

## 消息包工厂

在两个工具接口 BridgePacket 和 DirectPacket 上分别定义所对应的静态工厂方法，
根据协议调用 create() 创建各类消息包：

|     | BridgePacket (C-S)       | DirectPacket (C-C)       | 说明                 |
|-----|--------------------------|--------------------------|----------------------|
| 握手 | syn(source, request)     | syn(request)             | source 为预订 bid    |
|     | synAck(target, response) | synAck(response)         | target 为新分配 bid   |
|     | ack(source, response)    | ack(response)            |                      |
| 结果 | fail(target, response)   | -                        | 失败应答              |
|     | done(target, response)   | -                        | 成功应答              |
| 权限 | acpt(source, request)    | -                        | 允许 bid_list 通行    |
|     | deny(source, request)    | -                        | 禁止 bid_list 通行    |
| 心跳 | ping(source, request)    | ping(request)            |                     |
|     | pong(magpie, response)   | pong(magpie, response)   | 应答参数从 magpie 复制 |
| 挥手 | fin(source, request)     | fin(info, request)       |                     |
|     | finAck(magpie, response) | finAck(magpie, response) | 应答参数从 magpie 复制 |
| 无操作 | noop(source, request)  | noop(request)            | 无操作保活（如意外 "FIN!" 后的自愈回复，无需应答） |
| 数据 | data(target, source, sn, index, count, payload) | data(sn, index, count, payload) | |
|     | copy(magpie, response)   | copy(magpie, response)   | 应答参数从 magpie 复制 |

说明：

1. 第一次握手时可填 source 作为预订（期望）bid，可选；预订失败（被占用/非法/服务器已满）时服务器回复 "FAIL" 指令包，由客户端自行决定重新申请或放弃；
2. 除了 "DATA" 消息包之外（因其 payload 需要承载文件数据），其余各指令包在实现时均可携带一个可选参数 request/response 放在载荷当作附加信息；
3. 系统指令的载荷遵循载荷文档定义的格式（文本头 + 空行 + 数据区），所有指令（含应答）的载荷数据区均须携带发送方当前时间戳（秒），不允许为空。

### 消息包解析器

接收到完整的数据包之后，由解析器 Message Parser 进行校验解析。

### 解析器接口 Parser

接口方法： parse(data)

1. 根据协议依次检查 Magic Code、取得 type 中的各项标志位以及长度等信息，然后对数据合法性进行校验；
2. 如果数据包校验不通过，则返回空，否则用解析出来的所有参数，根据 B 的值创建对应的消息包对象并返回（B=1 时创建 BridgePacket，B=0 时创建 DirectPacket）。

## 工程目录

SDK 包括 Java、Python、Dart 等多个语言版本，
其中 Python 版服务器与 Python 版 SDK 共用一个库 'magpie-bridge'。

### Java SDK

依赖版本：
> Java 8

工程配置参数：
    name = 'Magpie'
    group = 'io.github.moky'

工程根目录：
    magpie/sdk-java/

### Python SDK

依赖版本：
> Python: >= 3.6

工程配置参数：
    name='magpie-bridge'

工程根目录：
    magpie/sdk-py/

代码目录：
    magpie/sdk-py/magpie_bridge/protocol/
    magpie/sdk-py/magpie_bridge/magpie/

协议定义相关的代码放在 protocol/ 目录下，工具类代码放在 magpie/ 下。

### Dart SDK

依赖版本：
> sdk: '>=3.0.0 <4.0.0'

工程配置参数：
    name: magpie-bridge

工程根目录：
    magpie/sdk-dart/
