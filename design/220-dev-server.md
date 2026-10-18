# Magpie Bridge (Server)

这里定义 Magpie Bridge 服务器的具体实现。

## 各模块（线程）设计

正如 **Magpie Bridge Architecture** 里定义的那样：

1. 服务器通过一个**接收线程**从绑定的 UDP 端口中读取数据包，连同来源 socket 信息封装成任务对象，放入等待处理队列；
2. **预处理线程**从前面的等待处理队列取出任务，进行基础校验之后，根据 target bid 决定是转交给“管理线程”处理，还是转交给“转发线程”处理；
3. 服务器有一个**管理线程**，专门负责 bid 的分配管理、超时记录回收（purge）、通行证管理（ACPT/DENY），以及几个系统命令的应答；
4. 服务器有 W 个**转发线程**，专门负责转发数据。

### 注意事项

1. **预处理线程**需要校验的内容包括来源 IP 和协议头信息：
	- 来源 IP 为广播或多播地址（IPv4 224.0.0.0/4 与 255.255.255.255、IPv6 ff00::/8 等）：
		- 处理方式：静默丢弃（不应答、不转发）；
		- 正常数据包的来源地址不可能是广播/多播地址，此类来源多为伪造，若不丢弃，服务器向其应答/转发会使数据扩散到整个广播域或多播组，形成放大攻击；
	- 检查协议头，判定是否为合法数据包：
		- Magic Code 不匹配的，静默丢弃（不应答、不转发）；
		- 将由```type```各标志位计算的协议头长度 N 与```header_length```字段比较，不相等则静默丢弃；
		- 将头长度 N 与```payload_length```相加，得到的值与实际数据包长度比较，不相等则静默丢弃（附加校验码格式校验见附加校验码文档）；
		- 当 C=1 时 command 必须非 0，全 0 则判定为错误包，静默丢弃；
			- 除此之外**不校验 command 的具体取值**，一律放行（具体值是否为系统指令、如何应答，由管理线程按场景处理，客户端自定义 command 亦不受限）；
		- 当 D=0 时必须 E=0，否则判定为错误包，静默丢弃；
		- 当 D=1 时 sn 必须非 0，全 0 则判定为错误包，静默丢弃；
		- 当 E>0 时，count 必须 > 1，且 0 <= index < count，否则为错误包，静默丢弃；
	- 上行校验违规检查：
		- 发给服务器/求转发的包必须 B=1，否则静默丢弃（不应答、不转发）；
		- 如果 target bid ≠ 0，但 source bid = 0 的，静默丢弃（客户端不得伪造来源为服务器的数据包）；
		- 如果 target bid ≠ 0 且与 source bid 相等的，静默丢弃（不能自己发给自己）；

2. **管理线程**需要检查 command 及 source bid：
	- **【握手阶段】**如果 command 是 "SYN?"，则为第一次握手（唯一允许 source bid 为 0 的场景）：
		- 分配 bid 与生成客户端密钥 secret、握手 token 等步骤见架构设计文档；
		- 此阶段服务器**不创建任何新记录**（无状态），新记录在 "ACK!" 验证通过后才创建；
	- **【确认阶段】**如果 command 是 "ACK!"，则为第三次握手（无状态验证）：
		- 检查校验 token 信息、查询 bid record 分配表等步骤见架构设计文档；
		- 直到这一步结束，新的 bid record 才会被创建；
	- **【服务阶段】**如果是其他系统指令（要求 source bid > 0）：source bid 为 0 属于上行校验违规，直接丢弃；
		- 先做来源检查（见架构设计文档）：连接未确认则先回复 "FAIL"（应答受共享计数器限频，见安全提案）再丢弃；source bid 不匹配则直接丢弃；
		- 凡 bid record 已建立后收到的系统指令（"SYN?" 与 "ACK!" 除外：前者无记录、后者走无状态令牌验证），均须对**附加校验码**进行 HMAC-SHA256 校验（见安全提案），校验失败视为不可信来源直接丢弃、不应答；
		- 以上校验全部通过之后，**更新活跃时间**```record.last_time = now```；
		- 然后根据 command 值进行相应的处理和应答（详见架构文档）；
		- 已绑定客户端的应答不限频（见安全提案）；

3. **转发线程**每条转发线程只负责 source bid 与本线程编号对应的转发任务。
	- 正常情况下，必须先完成握手才能转发数据，所以拿到转发任务时要先检查发送者状态：
		- 先做来源检查（见架构设计文档）：连接未确认则先回复 "FAIL"（应答受共享计数器限频，见安全提案）再丢弃；source bid 不匹配则直接丢弃；
		- 凡 bid record 已建立后收到的数据包，均须对**附加校验码**进行 HMAC-SHA256 校验（见安全提案），校验失败视为不可信来源直接丢弃、不应答；
	- 来源校验通过之后，**更新活跃时间**```record.last_time = now```，然后检查目标状态（见架构设计文档）；
	- 以上校验全部通过之后，用接收方的 record.secret 重新对数据包进行签名（见安全提案），然后再执行转发操作。

## Bridge ID 管理

bid 为一个 32 位无符号整数，实际应用中取高 16 位整数 H（0 ~ 65535，其中 0 为内定保留区间；1 ~ 32767 为当前启用的普通分配与预订区间；32768 ~ 65535 为预留区间，当前不启用但合法，仅可能由客户端预订产生，见下文）与低 16 位整数 L（0 ~ 65535）合并而成。

socket 信息包括 ip 和 port 两个值（类型为 SocketAddress，见用户信息记录文档附 2），当其作为 key 查询时为 "{ip}:{port}" 的字符串（即 SocketAddress 的字符串形式）。

设计要求： bid 与 socket 信息一一对应。

### 生成规则

bid (32位无符号整数) 采用**全随机**方式生成：直接在 `0x00010000 ~ 0x7FFFFFFF` 之间取一个均匀随机整数（该范围即高 16 位 H = 1 ~ 32767、低 16 位 L = 0 ~ 65535 的全部组合）：

1. 取一个均匀随机整数 bid，取值范围 `0x00010000 (65536) ~ 0x7FFFFFFF (2147483647)`；
2. 检查内存中的分配表，如果 bid 冲突，回到步骤 1 重新随机；
3. 重试达到 M 次仍然冲突（该概率极低，见下），暂时无法分配 bid，由管理线程回复 "FAIL" 指令包。

> 其中常量 M 默认 = 16（可通过配置文件 bid_allocation_retries 调整）
> 随机下限 0x00010000 保证不会落入 0 ~ 65535 的内定保留区间；随机上限 0x7FFFFFFF 保证不会自动分配 H ≥ 32768 的预留区间——该预留区间（H ≥ 32768）仅可能由客户端预订产生（见“内定与预订机制”）。
> 可用空间约 21.47 亿（2147418112 个值）；正常在线规模（万级）下新分配的碰撞概率不足万分之一，重试几乎一次成功；M 上限仅为极端情况的理论兜底（防止死循环），不代表“服务器已满”。

### 冲突判定

通过 bid 查询，如果记录不存在，或者记录中的 socket 信息相同，则无冲突；
反之，只要记录中的 socket 信息与当前不同，则判定为冲突（记录回收仅由管理线程在空闲时通过 purge 完成，其他线程不做超时覆盖判断）。

### 内存分配表

以 bid 为 key，或者 socket 信息为 key，均可查询分配记录。
记录字段（属性）见架构设计文档。

服务器每次收到数据包并检查通过之后，就会更新 last_time 为当前时间；
注意，只有管理线程和转发线程会更新 last_time：

- **管理线程**在收到客户端系统指令并验证身份时更新；
- **转发线程**在转发包通过来源 socket 预检后更新；
- **预处理线程**只负责分拣、不查表、不更新。

### 分配与回收

握手采用**无状态**方式：

- "SYN?" 阶段服务器只做分配决策并计算验证令牌（token），**不创建任何记录**；
- 记录在 "ACK!" 验证通过后才创建（创建即已确认，secret 固定不变）。

服务器收到握手请求（"SYN?" 指令）时分配 bid；

客户端收到 "SYN!" 后，在 "ACK!" 中原样回传 secret、token 与 token_time，服务器验证通过后创建记录（见管理线程职责）；
若 "ACK!" 丢失，客户端在发送下一个包时因服务器查不到 bid record 而收到 "FAIL"（连接未确认），据此补发 "ACK!" 或重新握手。

> 每次创建分配记录时，都需要同时建立两个索引（分别以 bid、socket 信息为 key）指向该记录，以方便后面查询。
> secret 一经确认写入记录后不再改变（重新握手仅下发原值），直到该记录被回收。

### 服务器密钥轮换与握手防洪

服务器内部维护一个**密钥组 server_secrets**（列表，初始化时包含一个随机密钥，须用密码学安全随机数）与最后生成时间 last_secret_time，用于计算/验证握手令牌 token：

- 生成 token 时：若 ```now - last_secret_time > server_secret_rotate_interval```（默认 600 秒），生成一个新随机密钥放入队头、更新 last_secret_time，并只保留最近 2 个密钥，然后取队头密钥计算；
- 验证 token 时：取出全部密钥（最多 2 个）逐个重算比对，任一匹配即通过（旧 token 在旧密钥被轮换出列表之前仍可验证）。

由于 "SYN?" 阶段不创建任何记录，握手洪流不产生任何共享状态、不占用内存，
防洪策略见安全提案。

管理线程每轮循环先执行回收检查：若距上次调用已超过 `record_recycle_interval`（默认 10 分钟），调用 ```purge(now)``` 回收超过 expires 的记录（同时删除对应的 bid 和 socket 信息索引）；随后从管理请求队列取出下一个任务处理（队列为空时阻塞等待）。

```purge(now)``` 只负责回收超过 expires（默认 24 小时）的记录（```last_time < now - expires```），调用间隔默认 10 分钟，可通过配置文件 `record_recycle_interval` 调整；
正常运营时分配表规模为在线用户数（万级），一次遍历毫秒级，10 分钟一次的摊销成本可忽略。
实现上建议先只读遍历收集过期记录、再统一删除，以缩短可能的持锁时间。

> 回收时效默认 24 小时（expires = 3600 * 24，秒），可通过配置文件 `record_expires` 调整。

- **不做惰性回收**：管理线程在按 bid 或 socket 信息查询分配表时**不检查是否过期**，记录存在即按有效记录处理（分配与冲突判定逻辑保持简单）；过期记录的回收统一由 purge 完成。
- 按来源 IP 的 "SYN?" 限速在 UDP 下可被伪造来源地址绕过，不作为协议层防洪水手段。

> 注：“在线”判定窗口 `T_active`（见工作流文档，默认 60 秒，可通过配置文件 `record_active_timeout` 调整）与回收时效 `expires`（默认 24 小时，可通过配置文件 `record_expires` 调整）是两个不同的参数：`T_active` 用于转发线程判断记录是否活跃（在线），`expires` 用于管理线程回收超时记录。

### 内定与预订机制

由于一台机器能绑定的端口 port 取值范围刚好是 0 ~ 65535，与 bid 的低 16 位 L 取值范围一致，所以特设 H=0 作为保留 bid 给内部进程使用：

- **内定**：对于来源 IP 是环回地址（loopback: 127.0.0.0/8, ::1/128）且第一次握手请求中 source bid 为 0 的客户端，则直接用其端口 port 作为 bid（即 bid 的高 16 位 H=0），这个属于 Bridge ID 管理机制为内部进程保留的 bid 区间。内定 bid 与其他 bid 一样，在 "ACK!" 验证通过后创建记录并参与超时回收（24 小时无上行数据即释放）。若内定 bid 被其他 socket 占用（例如不同 loopback IP 使用相同端口），直接回复 "FAIL" 指令包，由客户端进程自行协商后续。
- **预订**：客户端（无论 loopback 还是外部来源）在发送 "SYN?" 请求分配 bid 的时候，只要预设了 source bid（非 0），即走预订流程（而非内定流程）：先检查该 source bid 是否合法（必须大于 65535，即不能预订保留给 loopback 的内定区间）：不合法则回复 "FAIL" 指令包；合法则按该 bid 查表——当前 socket 已确认无绑定记录（见上一步），故记录存在则其 socket 必不相同（该 bid 已被其他 socket 占用），回复 "FAIL" 指令包；记录不存在（空闲）则采用该 bid（待 "ACK!" 验证通过后创建记录）。

注意：客户端不能预订 H=0 的内定区间（0 ~ 65535），即所有预订成功的 bid 必定大于 65535；预订 bid 不设上限（H 合法范围 0 ~ 65535），其中 H ≥ 32768（bid ≥ 2147483648）属于预留区间，服务器校验时不拒绝，但实际应用中无特殊原因不要申请这类预订 bid；loopback 客户端若想放弃“内定权利”（不想要 bid = port），在 "SYN?" 中预设 source bid 走预订流程即可。

## 流量控制

限流采用**滑动窗口**方式：每条转发线程在 `forward_window` 秒内最多处理 `forward_limit_per_window` 个任务，达到上限后本轮窗口内不再取新任务，等待下一个窗口再继续；超过队列容量（`forwarder_queue_size`）的新任务直接丢弃并记录日志（由客户端可靠传输机制重试）。

当前默认配置下单线程上限为 `4096 / 0.1s = 40960 包/秒`，8 条线程合计约 `327,680 包/秒`；单线程转发队列容量 `65536`（最坏约 64 MiB/线程，按满载荷 1KiB 计），足以缓冲约 1.6 秒的突发流量。相关参数均可通过配置文件调整（见 server 文档）：

- `forwarders`（线程数，默认 8）
- `forwarder_queue_size`（单线程转发队列容量，默认 65536）
- `forward_limit_per_window`（每窗口处理上限，默认 4096）
- `forward_window`（窗口时长，默认 0.1 秒）

## 工程目录

> 其中 Python 版服务器与 Python 版 SDK 共用一个库 'magpie-bridge'。

### Java 版服务器

工程根目录：
    magpie/server-java/

### Python 版服务器

代码目录：
    magpie/sdk-py/magpie_bridge/bridge/

工程配置参数：
    'console_scripts': [
        'magpie-bridge=magpie_bridge.bridge.run:main'
    ]

协议定义相关的代码放在 protocol/ 目录下，工具类代码放在 magpie/ 下，服务器代码放在 bridge/ 下。

> pip install magpie-bridge

执行此命令安装之后，即可通过命令 ```magpie-bridge [参数]``` 启动服务器。

### 启动参数

命令行均为命名参数，全部可选：

    magpie-bridge [--config=<FILE>] [--log-dir=/tmp]    (Python 版命令)
    java -jar magpie-bridge.jar [--config=<FILE>] [--log-dir=/tmp]   (Java 版入口)

- --config     配置文件路径（缺省尝试默认路径，见下；两版均支持）
- --log-dir    日志目录（默认为空，不写文件；两版均支持）

未知参数会打印用法提示并退出。

### 配置文件

默认路径： /etc/magpie/config.ini

> 未通过 --config 指定时尝试读取默认路径；文件不存在、段或键缺失时，一律回退到代码默认值。

默认配置：

```
[magpie-bridge]
host = 0.0.0.0
port = 9527

# UDP receive buffer size of the kernel socket (bytes, default:
# 4194304 = 4 MB; the kernel may clamp it to the system rmem_max)
socket_buffer_length = 4194304

# threads: forwarder thread count W (default: 8)
forwarders = 8
# forwarder rate limit: max packets processed per window (default: 4096)
forward_limit_per_window = 4096
# forwarder rate limit window (seconds, default: 0.1)
forward_window = 0.1

# record lifecycle: a bid record is recycled when it has no uplink
# traffic for longer than this (seconds, default: 86400.0 = 24 hours)
record_expires = 86400.0
# minimum interval between two purge(now) runs (seconds, default:
# 600.0 = 10 minutes; purge only recycles records that exceeded
# record_expires, so a full-table scan is rare and cheap)
record_recycle_interval = 600.0
# online judging window: the forwarder drops the target when its
# record has been inactive for longer than this (seconds, default:
# 60.0 = 1 minute)
record_active_timeout = 60.0
# handshake flood guard: minimum payload length of the first
# handshake packet "SYN?" (bytes, default: 512; keeps the "SYN!"
# reply smaller than the request to prevent amplification)
handshake_min_payload = 512
# unconfirmed reply buckets: number of shared reply counters for
# source sockets with no bound record (the "connection not confirmed"
# case, e.g. a lost "ACK!"); the bucket is selected by
# hash("ip:port") % U, and each bucket shares the reply_rate_limit
# below, so forged unconfirmed packets can trigger at most
# reply_rate_limit FAIL replies per second per bucket (default: 1024)
unconfirmed_reply_buckets = 1024
# reply rate limit: maximum FAIL replies sent per unconfirmed bucket
# per second (see unconfirmed_reply_buckets above); caps reflection
# amplification triggered by forged packets from sources with no bound
# record; when the limit is exceeded the reply is silently dropped
# (packets per second, default: 10)
reply_rate_limit = 10
# allowlist capacity: maximum number of entries in a bid record's
# allowlist; an "ACPT" that would exceed this limit is rejected as a
# whole (no bid is added) and answered with "FAIL", bounding the memory
# a forged ACPT flood can occupy (entries, default: 1000)
allowlist_max_entries = 1000
# NOOP immunity window: after a "NOOP" that cancels a forged "FIN!" the
# record's last_noop_time is refreshed; a later "FIN?" within this
# window is ignored (not marked offline, no "FIN!" reply), so a forged
# "FIN?" flood cannot keep the victim offline (seconds, default: 2.0)
noop_immunity_window = 2.0
# server secret rotation: a new server secret is generated and put at
# the head of server_secrets when it has been longer than this since
# the last rotation; at most the latest 2 secrets are kept for token
# verification (seconds, default: 600.0 = 10 minutes)
server_secret_rotate_interval = 600.0
# app secret (enigma) file: path to the application-secret JSON file
# (see the "enigma" MIP). When unset or empty, the file is missing,
# unparsable, or its "enigmas" map is empty, the server runs in
# non-encrypted mode (default: unset; uncomment the example below or
# set this value to enable)
# app_secret_file = /etc/magpie/private/enigma.json
app_secret_file =
# app secret reload interval: the manager thread re-reads app_secret_file
# this often; on success the in-memory map is replaced wholesale (key
# rotation/revocation takes effect), on failure or missing file the old
# map is kept (seconds, default: 600.0 = 10 minutes)
app_secret_reload_interval = 600.0
# handshake token timeout: an "ACK!" whose token_time is older than
# this is rejected (seconds, default: 60.0; a normal handshake
# completes in milliseconds, this only guards against replay and
# stale handshake packets)
handshake_token_timeout = 60.0
# bid allocation retries: treat the server as full after M conflicts
# (default: 16)
bid_allocation_retries = 16

# waiting queue capacity: receiver -> preprocessor (default: 4096)
waiting_queue_size = 4096
# manager queue capacity: preprocessor -> manager (default: 1024)
manager_queue_size = 1024
# forwarder queue capacity: preprocessor -> forwarder, per forward
# thread (default: 65536; when full the packet is dropped and logged,
# the client retries it via the reliable transport)
forwarder_queue_size = 65536
```

**规则说明**：

1. 所有时间值均为**浮点数的秒**（如 0.1 秒），代码内部自行转换为毫秒等内部单位；
2. 容量类参数均为整数：waiting_queue_size、manager_queue_size、forwarder_queue_size 为任务数（任务即数据包与来源 socket 信息的封装，见架构文档），allowlist_max_entries 为条目数，socket_buffer_length 为字节数；
3. 所有键缺失、段缺失或文件缺失时均回退到代码默认值（host 默认 0.0.0.0、port 默认 9527、forwarders 默认 8，与其余键行为一致）；
4. 命令行 --config 指定的路径优先于默认路径；配置文件不存在时不报错，直接使用全部默认值。
