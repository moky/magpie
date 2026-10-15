# Magpie Bridge Messaging Protocol （载荷格式）

本文档定义各系统指令的载荷格式。


## 载荷 (Payload)

本协议定义的载荷区为连续的二进制数据区，其长度由协议头中的 `payload_length` 字段指明。

载荷最大长度不超过 1024 字节（发送端建议上限）。

> 由于防放大攻击的需要，服务器规定握手阶段的两个上行包 SYN?/ACK! 的载荷长度不得少于 512 字节，因此这两个包需要填充信息以满足此要求。


### 系统指令载荷

所有系统指令都要求有载荷（JSON 格式字符串），
且其中必须包含发送方时间戳 "time"。

字段类型说明：
- "time"：发送方本地时间戳，浮点数（秒），仅用于记录与展示，精度可到毫秒级；
- "token_time"：服务器生成握手 token 时的时间戳，**必须为整数秒**，参与 HMAC-SHA256 校验计算，不可随意改动。

因此最小的载荷为 19 字节：

```{"time":1736835254}```

#### 第一次握手 "SYN?" 

第一次握手包只要求不少于 512 字节，没有其他字段要求，
所以只需要带上发送方时间戳 "time"，并填充任意信息使之不少于 512 字节即可：

```json
{
    "sender"   : "moki@4WDfe3zZ4T7opFSi3iDAKiuTnUHjxmXekk",
    "receiver" : "hulk@4YeVEN3aUnvC1DNUufCq1bs9zoBSJTzVEj",
    "time"     : 1545405083,
    
    "data"      : "9cjCKG99ULCCxbL2mkc/MgF1saeRqJaCc+S12+HCqmsuF7TWK61EwTQWZSKskUeF",
    "key"       : "WH/wAcu+HfpaLq+vRblNnYufkyjTm4FgYyzW3wBDeRtXs1TeDmRxKVu7nQI/sdIALGLXrY+O5mlRfhU8f8TuIBilZUlX/eIUpL4uSDYKVLaRG9pOcrCHKevjUpId9x/8KBEiMIL5LB0Vo7sKrvrqosCnIgNfHbXMKvMzwcqZEU8=",
    "signature" : "Yo+hchWsQlWHtc8iMGS7jpn/i9pOLNq0E3dTNsx80QdBboTLeKoJYAg/lI+kZL+g7oWJYpD4qKemOwzI+9pxdMuZmPycG+0/VM3HVSMcguEOqOH9SElp/fYVnm4aSjAJk2vBpARzMT0aRNp/jTFLawmMDuIlgWhBfXvH7bT7rDI="
}
```

#### 第二次握手 "SYN!"

压缩后大约 190 字节左右：

```json
{
    "secret": "{Base64 编码的 secret}",
    "token":  "{Base64 编码的 token}",
    "token_time": {服务器生成此 token 的时间戳，整数秒},
	
    "time": 1234567890.123,
    
    "UDP": "12.34.56.78:90"
}
```

#### 第三次握手 "ACK!"

客户端需要在此回传第二次握手包中的 3 个握手参数（secret/token/token_time）
同时要求长度不能少于 512 字节：

```json
{
    "secret": "{Base64 编码的 secret}",
    "token":  "{Base64 编码的 token}",
    "token_time": {服务器生成此 token 的时间戳，整数秒},
    
    "time": 1234567890.123,
    
    "blahblah": "{填充长度 500 字节}"
}
```

#### 失败应答 "FAIL"

握手失败（预订被占用/非法、内定冲突、服务器已满）一律只带当前服务器时间戳：

```json
{
    "time": 1234567890
}
```

连接未确认：

```json
{
    "src-command": {被拒数据包的 command，十六进制编码},
    "time": {服务器当前时间戳}
}
```

接收方离线，无法转发：

```json
{
    "src-command": {被拒数据包的 command，十六进制编码},
    "src-target": {bid，十进制整数},
    "time": {服务器当前时间戳}
}
```

添加/删除通行证失败（未列出的 bid 视为可修改，但本次操作未执行）：

```json
{
    "src-command": "41435054",
    "sources": [123],
    "time": 1234567890
}
```

```json
{
    "src-command": "44454E59",
    "sources": [123],
    "time": 1234567890
}
```

#### 成功应答 "DONE"

添加通行证成功：

```json
{
    "src-command": "41435054",
    "sources": [123],
    "time": 1234567890
}
```

删除通行证成功：

```json
{
    "src-command": "44454E59",
    "sources": [123],
    "time": 1234567890
}
```

清空通行证成功（请求为清空标记 [-1, -2, -3] 时，DONE 回显被清空的 bid 列表，即服务器实际清除的 keys）：

```json
{
    "src-command": "44454E59",
    "sources": [123, 456, 789],
    "time": 1234567890
}
```

#### 通行证管理 "ACPT" / "DENY"

添加/删除：

```json
{
    "sources": [123],
    "time": 1234567890
}
```

清空：

```json
{
    "sources": [-1, -2, -3],
    "time": 1234567890
}
```

#### 心跳机制 "PING" / "PONG"

```{"time":1234567890}```

#### 挥手阶段 "FIN?" / "FIN!"

```{"time":1234567890}```

#### 无操作 "NOOP"

```{"time":1234567890}```

### 数据指令载荷

服务器本身不会接收（处理）或应答此类指令，只有代转发功能。

#### 发送数据 "DATA"

发送数据指令的载荷就是二进制数据本身，不额外定义 JSON 格式，否则带宽占用会变大：

```{二进制数据}```

#### 收到数据 "COPY"

数据应答指令的载荷由应用层自定义。
