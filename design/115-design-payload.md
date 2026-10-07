# Magpie Bridge Messaging Protocol （载荷）

本文档描述的是定义在协议载荷区之上的扩展协议。

> 此扩展协议主要针对系统指令。
> 
> 对于普通数据包 "DATA" 及其应答包 "COPY"，不属于此扩展范围。
> 即普通数据直接原样传输，由应用层负责校验处理；而应答包无需 payload。
> 如果应用层需要对大文件数据包加一个头（以便在收到第一个分包的时候便知道文件大小等信息），可自行决定，本协议不做要求。

## 扩展协议

该协议参照 HTTP 协议格式，分为**头部参数区**与**二进制数据区**两部分。
头部参数区为纯文本内容，以换行符分割；头部参数区与数据区以一个空行分割。

换行符标准： \r\n (CRLF)

因此实际解析时以第一个出现的 \r\n\r\n 为分割符，其后为二进制数据区。

协议版本固定为 "MP/1.0"。

### 通用规则

1. 换行符一律为 \r\n：头部参数区每行以 \r\n 结尾，不允许出现裸 \n 或裸 \r；数据区为任意二进制，不做换行约束；
2. **Content-Length** 表示数据区字节数：生成时必选且必须准确；解析时可选（缺省时以 \r\n\r\n 之后剩余的全部字节作为数据区），但若存在则必须与实际数据区长度一致，不一致判定为错误包；
3. **Content-Type** 表示数据区格式，照搬 HTTP 的 MIME 类型定义（当前所有系统指令的数据区均为 JSON，统一使用 application/json；将来出现其他格式时使用 application/octet-stream、text/plain 等标准值）：生成时必选且必须与实际数据区格式一致；解析时可选（缺省按二进制 application/octet-stream 处理），若声明为 application/json 而数据区无法按 JSON 解析，判定为错误包；
4. 协议自有参数前缀为 **"mp-"**（如 mp-secret、mp-verify、mp-src-command），表示载荷子协议自身的参数；magpie 头已能表达的字段（target/source/sn 等）不重复放入数据区；
5. **time**：所有系统指令（含应答）的数据区均须携带发送方当前时间（浮点秒，如 123.45），用于防重放（具体校验规则见安全文档）；即使某指令用不到其他信息，数据区也至少包含 time，不允许为空；
6. 应答类包一般不回显原请求字段（应答指令与请求一一对应，接收方凭 command 即可识别归属）；仅当应答与请求**非一一对应**，或应答为多场景复用的通用失败包时，需要回显原 command，使用前缀 **"mp-src-command"**（如 mp-src-command: 0x41435054，取原 command 的十六进制形式）——当前需要该字段的为 **"DONE" 与 "FAIL"**：
   - "DONE"：对应 ACPT/DENY 两种请求（成功回 "DONE"），回显原 command 以区分归属；
   - "FAIL"：为多场景复用的通用失败应答，一律回显被应答的原请求 command——bid 分配失败回显 "SYN?"（0x53594E3F）；连接未确认回显被拒数据包的 command（如 "DATA" 0x44415441）；无法修改通行证回显 ACPT/DENY（0x41435054 / 0x44454E59）；
7. 数据区内容由各指令自行定义（示例中使用 JSON，便于携带多个字段；如追求更小体积可改用二进制编码，文本头字段保持不变）。

### Request

请求类属性：

- method
- target  (Request-Target)
- version (Protocol-Version)
- fields
- data    (Blob)

所有在**鹊桥协议**中 A=0 的数据包 payload 全部归为此类：

| Command | Method  | Target     | Description        |
|---------|---------|------------|--------------------|
| "SYN?"  | CONNECT | /bid       | 第1次握手（请求连接） |
| "ACPT"  | PUT     | /contacts  | 接受（添加通行证）    |
| "DENY"  | DELETE  | /contacts  | 拒绝（删除通行证）    |
| "PING"  | OPTIONS | /last_time | 发起心跳            |
| "FIN?"  | DELETE  | /bid       | 第1次挥手（请求关闭） |
| "NOOP"  | HEAD    | /          | 无操作              |

> method 语义参照 HTTP：CONNECT 表示建立连接（握手）；PUT 表示设置资源（添加通行证，幂等）；DELETE 表示删除资源（撤销通行证/请求关闭）；OPTIONS 表示探测（心跳探活）；HEAD 表示无返回体的空操作（无操作指令）。

### Response

应答类属性：

- version (Protocol-Version)
- code    (Status-Code)
- reason  (Reason-Phrase)
- fields
- data    (Blob)

所有在**鹊桥协议**中 A=1 的数据包 payload 全部归为此类：

| Command | Code | Reason       | Description               |
|---------|------|--------------|---------------------------|
| "SYN!"  | 102  | Processing   | 第2次握手（收到请求，处理中）  |
| "ACK!"  | 200  | OK           | 第3次握手（确认连接）        |
| "FAIL"  | 400  | Bad Request  | 失败（分配 bid 失败/连接未确认/无法修改通行证） |
| "DONE"  | 200  | OK           | 完成（成功修改通行证）       |
| "PONG"  | 304  | Not Modified | 心跳应答                   |
| "FIN!"  | 410  | Gone         | 第2次挥手（确认关闭）        |

> 状态码语义参照 HTTP：102 表示请求已收到、仍在处理中（第三次握手尚未完成）；200 表示处理成功；400 表示请求无法处理（具体原因由数据区说明）；304 表示状态未改变（心跳应答）；410 表示目标资源已关闭/删除（挥手确认）。多个指令可共用同一状态码（如 "ACK!" 与 "DONE" 均为 200），状态码只表达语义类别，具体指令以 command 区分。

### Secret （密钥）

密钥的生成：客户端 A 向服务器 S 发送第1次握手包 "SYN?" 时。

S 收到 "SYN?" 指令之后，根据流程分配 bid record，
同时生成一个随机数存在 record.pending_secret，然后在应答包 "SYN!" 中发给 A（mp-secret 字段，Base64 编码）。

A 收到此密钥之后，以 HMAC-SHA256 算法、该密钥为 key、**数据区全部字节**为消息，计算消息认证码得到哈希值 H，然后在 "ACK!" 中将 H 发给 S（mp-verify 字段，Base64 编码）。
S 收到并校验通过之后，将此密钥存为 record.secret，并删除 record.pending_secret。

此后 S 与 A 之间发送/接收**所有系统指令（含应答）**时，均须按同样方式携带 mp-verify（对数据区全部字节计算 HMAC-SHA256，Base64 编码），供对端校验，校验失败按错误包处理。

注：

1. Secret 只会在网络中出现一次，即 "SYN!" 包中，由服务器发给客户端；
2. 此后任何数据包都不会带密钥，只会带校验信息（mp-verify 哈希值）；
3. 此机制不能防御嗅探级威胁，即如果攻击者在 S 与 A 之间的网络路径上就有可能获取 "SYN!" 内容；
4. mp-verify 机制仅在双方共享 secret 时使用，当前仅存在于服务器场景（客户端直连尚无 secret，是否引入见安全文档）；无 secret 时相关字段一律不出现；
5. 防重放（时间戳单调性校验等）属安全设计范畴，见安全文档，本文档不展开。

## 示例

> 以下示例中 mp-verify 均为 HMAC-SHA256 对数据区全部字节计算的 Base64 编码；"DONE" 与 "FAIL" 使用 mp-src-command 回显被应答的原请求 command（"FAIL" 按场景回显：SYN?/DATA/ACPT/DENY）。

### 示例 0.1 - 第1次握手 "SYN?"

```
CONNECT /bid MP/1.0
Content-Type: application/json
Content-Length: 256

{"meta":{一些用户资料信息等},"time":123.44}
```

> 当前服务器默认要求第1次握手包载荷不小于 256 字节（配置项 handshake_min_payload，可调整），防止放大攻击；数据区示例仅为示意，实际内容由应用层定义。

### 示例 0.2 - 第2次握手 "SYN!"

```
MP/1.0 102 Processing
mp-secret: {密钥，Base64 编码}
Content-Type: application/json
Content-Length: 38

{"UDP":"12.34.56.78:90","time":123.45}
```

### 示例 0.3 - 第3次握手 "ACK!"

```
MP/1.0 200 OK
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 38

{"UDP":"12.34.56.78:90","time":123.46}
```

### 示例 1.1 - 创建通行证 "ACPT"

```
PUT /contacts MP/1.0
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 34

{"sources":[123456],"time":234.56}
```

### 示例 1.2 - 创建成功 "DONE"

```
MP/1.0 200 OK
mp-src-command: 0x41435054
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 34

{"sources":[123456],"time":234.57}
```

### 示例 1.3 - 失败应答 "FAIL"（bid 分配失败）

```
MP/1.0 400 Bad Request
mp-src-command: 0x53594E3F
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 15

{"time":123.47}
```

> 该示例为 "SYN?"（预订被占用/非法、内定冲突或服务器已满）的失败应答；"FAIL" 在其他场景下 mp-src-command 相应回显 DATA/ACPT/DENY，数据区按场景变化（见工作流文档）。

### 示例 2.1 - 心跳 "PING"

```
OPTIONS /last_time MP/1.0
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 15

{"time":345.67}
```

### 示例 2.2 - 心跳应答 "PONG"

```
MP/1.0 304 Not Modified
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 15

{"time":345.68}
```

### 示例 3.1 - 第1次挥手 "FIN?"

```
DELETE /bid MP/1.0
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 15

{"time":456.78}
```

### 示例 3.2 - 第2次挥手 "FIN!"

```
MP/1.0 410 Gone
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 15

{"time":456.79}
```

### 示例 3.3 - 断线恢复 "NOOP"

```
HEAD / MP/1.0
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 15

{"time":456.80}
```
