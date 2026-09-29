# Magpie Bridge 客户端示例

两个客户端 A 和 B 通过服务器桥接通讯的完整流程示例。

## 1. 桥接通讯流程

```mermaid
sequenceDiagram
    participant A as 客户端 A
    participant B as 客户端 B
    participant S as 服务器

    A->>S: SYN? (申请 bid)
    S-->>A: SYN! (bid_A)
    B->>S: SYN? (申请 bid)
    S-->>B: SYN! (bid_B)

    Note over A,B: 相互告知 bid 与 socket 信息

    B->>S: DATA (target=bid_A, source=bid_B)
    S->>A: DATA (原样转发)
    A->>S: COPY (target=bid_B, source=bid_A)
    S->>B: COPY (原样转发)
    Note over B: 消息状态更新为"已接收"
```

> 申请 bid 时若收到 FAIL（预订被占用/非法、内定冲突、服务器已满），则重新申请或放弃。

## 2. 客户端 A（被动模式）

1. 绑定 UDP，向服务器申请 bid（若收到 FAIL 则重新申请或放弃）；
2. 显示获取到的 bid，包括服务器返回的 socket 信息；
3. 等待其他客户端发送数据；
4. 等待期间维护心跳机制；
5. 收到其他客户端的数据后按协议自动回复应答包（COPY）；
6. 展示收到的信息，包括发送方信息（bid 或 socket 信息）。

## 3. 客户端 B（主动模式）

1. 绑定 UDP，向服务器申请 bid（若收到 FAIL 则重新申请或放弃）；
2. 显示获取到的 bid，包括服务器返回的 socket 信息；
3. 等待用户输入接收方信息（bid 或 socket 信息）；
4. 等待用户输入接收方 bid 及要发送的文本内容；
5. 构建 BridgePacket 交由服务器转发；
6. 等待对方返回应答包，更新消息状态为"已接收"。

## 4. 工程目录

| 语言 | 工程根目录 |
|------|-----------|
| Java | magpie-bridge/tests-java/ |
| Dart | magpie-bridge/tests-dart/ |
