# Magpie Bridge（鹊桥项目）

[![License](https://img.shields.io/github/license/moky/magpie)](https://github.com/moky/magpie/blob/main/LICENSE)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreeng)](https://github.com/moky/magpie/pulls)
[![Issues](https://img.shields.io/github/issues/moky/magpie)](https://github.com/moky/magpie/issues)
[![Repo Size](https://img.shields.io/github/repo-size/moky/magpie)](https://github.com/moky/magpie/archive/refs/heads/main.zip)
[![Tags](https://img.shields.io/github/tag/moky/magpie)](https://github.com/moky/magpie/tags)

[![Watchers](https://img.shields.io/github/watchers/moky/magpie)](https://github.com/moky/magpie/watchers)
[![Forks](https://img.shields.io/github/forks/moky/magpie)](https://github.com/moky/magpie/forks)
[![Stars](https://img.shields.io/github/stars/moky/magpie)](https://github.com/moky/magpie/stargazers)
[![Followers](https://img.shields.io/github/followers/moky)](https://github.com/orgs/moky/followers)

**基于 UDP 的可靠中继网络** —— **Magpie Bridge Messaging Protocol**（鹊桥通信协议），
一个构建于 UDP 之上的应用层消息协议，支持桥接（服务器中转）与直连（点对点）两种模式，
提供多语言 SDK 与可配置的中继服务器。

## 特性

- **基于 UDP 的可靠传输**：可靠数据包（D=1）通过 `"COPY"` 应答确认（按 sn 配对）；
  发送方超时重传，接收方到达去重。
- **桥接与直连模式**：数据包由服务器中转（B=1，按桥接 ID 寻址），
  或客户端之间直接发送（B=0，按 socket 寻址）。
- **桥接 ID（bid）管理**：32 位 `bid = (H << 16) | L`，支持自动分配、客户端预订
  与环回内定分配——约 21.5 亿个可用 id。
- **通行证机制**：双向通行证（`"ACPT"`/`"DENY"`）——仅当双方互相接纳后才转发数据；
  伪造的单方 "DENY" 无法中断通信。
- **防伪造与防放大**：除两个握手包外所有消息包均携带 HMAC-SHA256 校验码；
  可选的应用密钥（enigma）加密握手；握手上行包 ≥512 字节；对未确认来源的应答限频；
  "NOOP" 免疫窗口防恶意踢人。
- **会话生命周期**：三次握手（`"SYN?"`/`"SYN!"`/`"ACK!"`）、心跳（`"PING"`/`"PONG"`）、
  两次挥手（`"FIN?"`/`"FIN!"`）、"NOOP" 自愈，以及超时回收桥接 id。
- **多语言 SDK**：Java（`sdk-java/`）、Python（`sdk-py/`）与 Dart（`sdk-dart/`，规划中）。
- **可配置服务器**：INI 配置线程数、限流、队列容量与内核 socket 缓冲区——保留默认值，
  可通过 `--config` 覆盖。

## 快速开始

### 1. 启动中继服务器

Java：

```bash
cd server-java
gradle run        # 默认监听 0.0.0.0:9527
# 可选：gradle run --args='--config=/path/to/config.ini --log-dir=/path/to/logs'
```

Python：

```bash
cd sdk-py
python3 -m magpie_bridge.bridge.run    # 默认监听 0.0.0.0:9527
```

### 2. 运行测试客户端

先将 Java SDK 发布到本地 Maven 仓库（一次性）：

```bash
cd sdk-java
gradle publishToMavenLocal
```

然后在两个终端分别运行两个示例客户端：

```bash
cd tests-java
gradle :tests-java:clientA --args="--host 127.0.0.1 --port 9527"    # 终端 1（被动）
gradle :tests-java:clientB --args="--host 127.0.0.1 --port 9527"    # 终端 2（主动）
```

每个客户端绑定 UDP，向服务器申请 bid，并通过服务器相互交换消息。

## 文档

| 文档                                                           | 面向读者                                            |
|---------------------------------------------------------------|-----------------------------------------------------|
| [docs/protocol.md](docs/protocol.md)                          | 协议实现者 —— 线格式、字段、校验与错误码           |
| [docs/architecture.md](docs/architecture.md)                  | 所有人 —— 系统架构与线程模型                       |
| [docs/workflow.md](docs/workflow.md)                          | 所有人 —— 握手、心跳、挥手与转发流程               |
| [docs/security.md](docs/security.md)                          | 所有人 —— 威胁模型、完整性、防放大/防反射          |
| [docs/sdk.md](docs/sdk.md)                                    | SDK 使用者 —— 接口、工厂与解析器                   |
| [docs/server.md](docs/server.md)                              | 服务器运维 —— 部署、配置与调优                     |
| [docs/client.md](docs/client.md)                              | 示例应用 —— 测试客户端说明                         |

设计思路（[`design/`](design/)）中存放任务说明，docs/ 由前者生成。

## 许可证

[MIT](LICENSE) © 2026 Albert Moky
