# Magpie Bridge Messaging Protocol （载荷）

本文档描述的是定义在协议载荷区之上的扩展协议。

> 此扩展协议主要针对系统指令。
> 
> 对于普通数据包 "DATA" 及其应答包 "COPY"，不强制要求应用此扩展。
> 即普通数据默认直接原样传输，由应用层负责校验处理；而应答包通常无需 payload；
> 如果应用层需要对大文件数据包加一个头（以便在收到第一个分包的时候便知道文件总大小等信息），或者在数据应答包 "COPY" 中附带一些校验参数等，其格式可自行决定（也可以复用本协议），本协议不做强制要求。


## 扩展协议

该协议参照 HTTP 协议格式，分为**头部参数区**与**二进制数据区**两部分。
头部参数区为纯文本内容，以换行符分割；头部参数区与数据区以一个空行分割。

换行符标准： \r\n (CRLF)

因此实际解析时以第一个出现的 \r\n\r\n 为分割符，其后即为二进制数据区。

协议版本固定为 "MP/1.0"。

### 通用规则

1. 换行符一律为 \r\n：头部参数区每行以 \r\n 结尾，不允许出现裸 \n 或裸 \r；数据区为任意二进制，不做换行约束；
2. **Content-Length** 表示数据区字节数：生成时必选且必须准确；解析时可选（缺省时以 \r\n\r\n 之后剩余的全部字节作为数据区），但若存在则必须与实际数据区长度一致，不一致判定为错误包；
3. **Content-Type** 表示数据区格式，照搬 HTTP 的 MIME 类型定义（当前所有系统指令的数据区均为 JSON，统一使用 application/json；将来出现其他格式时使用 application/octet-stream、text/plain 等标准值）：生成时必选且必须与实际数据区格式一致；解析时可选（缺省按二进制 application/octet-stream 处理），若声明为 application/json 而数据区无法按 JSON 解析，判定为错误包；
4. 协议自有参数前缀为 **"mp-"**（如 mp-secret、mp-verify、mp-src-command、mp-src-target），表示载荷子协议自身的参数；magpie 头已能表达的字段（target/source/sn 等）不重复放入数据区；
5. **time**：所有系统指令（含应答）的数据区均须携带发送方当前时间（浮点秒，如 123.45），用于防重放（具体校验规则见安全文档）；即使某指令用不到其他信息，数据区也至少包含 time，不允许为空；
6. 应答类包一般不回显原请求字段（应答指令与请求一一对应，接收方凭 command 即可识别归属）；仅当应答与请求**非一一对应**时，需要回显原请求字段，使用前缀 **"mp-src-"**（如 mp-src-command: 0x41435054，取原 command 的十六进制形式；mp-src-target: 123456，取原请求 target bid 的十进制形式）——当前需要该字段的为 **"DONE" 与 "FAIL"**：
   - "DONE"：对应 ACPT/DENY 两种请求（成功回 "DONE"），回显原 command 以区分归属；
   - "FAIL"：为多场景复用的通用失败应答，一律回显被应答的原请求 command——bid 分配失败回显 "SYN?"（0x53594E3F）；连接未确认与 target 离线（转发时发现收件人不活跃）均回显被拒数据包的 command（如 "DATA" 0x44415441）；无法修改通行证回显 ACPT/DENY（0x41435054 / 0x44454E59）；其中 target 离线还需额外回显原请求的收件人 bid（mp-src-target: 十进制整数）；
7. 数据区内容由各指令自行定义（示例中使用 JSON，便于携带多个字段；如追求更小体积可改用二进制编码，文本头字段除 Content-Type 外保持不变）。

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
| "FAIL"  | 400  | Bad Request  | 失败（分配 bid 失败/连接未确认/target 离线/无法修改通行证） |
| "DONE"  | 200  | OK           | 完成（成功修改通行证）       |
| "PONG"  | 304  | Not Modified | 心跳应答                   |
| "FIN!"  | 410  | Gone         | 第2次挥手（确认关闭）        |

> 状态码语义参照 HTTP：102 表示请求已收到、仍在处理中（第三次握手尚未完成）；200 表示处理成功；400 表示请求无法处理（具体原因由数据区说明）；304 表示状态未改变（心跳应答）；410 表示目标资源已关闭/删除（挥手确认）。多个指令可共用同一状态码（如 "ACK!" 与 "DONE" 均为 200），状态码只表达语义类别，具体指令以 command 区分。

### Secret （密钥）

握手采用**无状态**方式（详见架构/服务器文档）："SYN?" 阶段服务器不创建记录，通过验证令牌（token）在 "ACK!" 阶段完成身份验证后，才创建 bid record 并写入固定不变的 secret。

#### 服务器密钥组（server_secrets）

服务器内部维护一个随机密钥组 server_secrets（初始化含 1 个密钥，须用密码学安全随机数）与最后生成时间 last_secret_time：

- 生成 token 时：若 ```now - last_secret_time > server_secret_rotate_interval```（默认 600 秒），则生成一个新随机密钥放入队头、更新 last_secret_time，并只保留最近 2 个密钥，然后取队头密钥计算；
- 验证 token 时：取出全部密钥（最多 2 个）逐个重算比对，任一匹配即通过（旧 token 在旧密钥被轮换出列表之前仍可验证）。

#### 握手流程（客户端 A → 服务器 S）

1. A 发送 "SYN?"：S 根据流程分配 bid（复用/预订/内定/新分配，详见服务器文档），生成客户端密钥 secret（复用已确认记录时取原 record.secret，否则随机生成，须用密码学安全随机数），以服务器密钥对关键信息计算验证令牌：

   > token = HMAC-SHA256(key = server_secret, message = UTF-8(规范字符串))
   >
   > 规范字符串：字段按 key 字典序排序（bid < secret < socket < time），以 "&" 连接 "key=value"，例如 "bid=123&secret=YWJj&socket=1.2.3.4:5678&time=123"；其中 bid 为 10 进制整数、socket 为 "{ip}:{port}" 字符串、secret 为 Base64 编码、time 为服务器当前时间戳（秒，10 进制整数）。

   然后回复 "SYN!"：载荷文本头 mp-secret 携带 secret（Base64 编码），载荷数据区携带 socket 信息、token 与 token_time（即上述 time）。**此阶段 S 不创建任何记录**（无状态，不保存 bid 与 secret）。

2. A 收到后**原样回传**（token 由服务器密钥计算，有且只有服务器能校验，客户端不能篡改——任何字段改动都会导致重算不匹配）："ACK!" 载荷文本头 mp-secret 携带同样的 secret，载荷数据区携带同样的 token 与 token_time（数据区 time 为 A 当前时间戳，仅用于防重放）。

3. S 收到 "ACK!" 后先用服务器密钥组对 "bid={协议头 source bid}&secret={包内 mp-secret}&socket={服务器观察到的来源 ip:port}&time={包内 token_time}"（按 key 字典序排序的键值对）重算 token 并与包内 token 比对：不匹配则判定为不可信来源，直接丢弃、不应答（攻击者无法伪造 token，故无法触发任何应答）；匹配（说明包确为 S 签发、未被篡改）后再检查 token_time 是否超出有效窗口（handshake_token_timeout，默认 60 秒）：超时回复 "FAIL"（客户端重新握手）；否则创建 bid record（bid → socket、secret 取包内 mp-secret 并固定不变，连接即已确认；记录已存在且 socket 匹配时幂等更新，secret 保持不变；记录已存在但 socket 不同则回复 "FAIL"）。

此后 S 与 A 之间发送/接收**所有系统指令（含应答）**时，均须携带 mp-verify（HMAC-SHA256，key = 双方共享的 record.secret，对数据区全部字节计算，Base64 编码），供对端校验，校验失败按错误包处理；secret 一经确认写入记录后不再改变（重新握手仅下发原值），直到该记录被回收。

注：

1. Secret 只会在握手阶段出现（"SYN!" 下发、 "ACK!" 原样回传），由服务器发给客户端；重新握手（复用已确认记录）时下发的仍是原值，不再生成新密钥；
2. 握手完成后的任何数据包都不会带密钥，只会带校验信息（mp-verify 哈希值）；
3. 此机制不能防御嗅探级威胁，即如果攻击者在 S 与 A 之间的网络路径上就有可能获取 "SYN!" 内容（token 是认证码而非加密）；
4. mp-verify 机制仅在双方共享 secret 时使用，当前仅存在于服务器场景（客户端直连尚无 secret，是否引入见安全文档）；无 secret 时相关字段一律不出现；
5. 防重放（时间戳单调性校验等）属安全设计范畴，见安全文档，本文档不展开。

## 示例

> 以下示例中 mp-verify 均为 HMAC-SHA256 对数据区全部字节计算的 Base64 编码（握手示例 0.2/0.3 除外：其文本头为 mp-secret、数据区为 token/token_time，见上文 Secret 节）；"DONE" 与 "FAIL" 使用 mp-src-command 回显被应答的原请求 command（"FAIL" 按场景回显：SYN?/DATA/ACPT/DENY）。

### 示例 0.1 - 第1次握手 "SYN?"

```
CONNECT /bid MP/1.0
Content-Type: application/json
Content-Length: 512

{"meta":{一些用户资料信息等},"time":123.44}
```

> 当前服务器默认要求第1次握手包载荷不小于 512 字节（配置项 handshake_min_payload，可调整），
> 防止放大攻击并抬高握手洪流门槛；
> 数据区示例仅为示意，实际内容由应用层定义，不足时须填充至不低于该值。

### 示例 0.2 - 第2次握手 "SYN!"

```
MP/1.0 102 Processing
mp-secret: {密钥，Base64 编码}
Content-Type: application/json
Content-Length: ...

{"UDP":"12.34.56.78:90","time":123.45,"token":"{令牌，Base64 编码}","token_time":123}
```

> token 为服务器密钥计算的验证令牌（HMAC-SHA256，Base64 编码），
> token_time 为生成 token 时的服务器时间戳（秒，10 进制整数）；
> 两者由客户端在 "ACK!" 中原样回传。

### 示例 0.3 - 第3次握手 "ACK!"

```
MP/1.0 200 OK
mp-secret: {密钥，Base64 编码}
Content-Type: application/json
Content-Length: ...

{"time":123.46,"token":"{令牌，Base64 编码}","token_time":123}
```

> 数据区仅需携带 time（客户端当前时间戳，防重放）与 token/token_time（原样回传）；
> 服务器以来源地址校验 token，验证通过后创建 bid record。

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

### 示例 1.3 - 创建失败 "FAIL"

```
MP/1.0 400 Bad Request
mp-src-command: 0x41435054
mp-verify: {哈希值，Base64 编码}
Content-Type: application/json
Content-Length: 34

{"sources":[123457],"time":234.58}
```

> 该示例为 "ACPT"（创建通行证失败：任一 bid 无效则整体不执行，数据区为未通过校验的 bid 子集）的失败应答；
> "FAIL" 在其他场景下 mp-src-command 相应回显 SYN?/DATA/DENY，数据区按场景变化（见工作流文档）。

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
