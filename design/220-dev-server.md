# Magpie Bridge (Server)

这里定义 Magpie Bridge 服务器。

## 各模块（线程）设计

正如 **Magpie Bridge Architecture** 里定义的那样：

1. 服务器通过一个**接收线程**从绑定的 UDP 端口中读取数据包，然后直接放入等待处理队列；
2. **预处理线程**从前面的等待处理队列取出数据包，进行简单的校验之后，根据 target bid 决定是转交给“管理线程”处理，还是转交给“转发线程”处理；
3. 服务器有一个**管理线程**，专门负责 bid 的分配管理、超时记录回收（purge）、通行证管理（ACPT/DENY），以及几个系统命令的应答；
4. 服务器有 W 个**转发线程**，专门负责转发数据。

### 注意事项

1. **预处理线程**需要校验的内容包括：
	- 来源 IP 为广播或多播地址（IPv4 224.0.0.0/4 与 255.255.255.255、IPv6 ff00::/8 等）的数据包直接丢弃，不应答、不转发；正常数据包的来源地址不可能是广播/多播地址，此类来源多为伪造，若不丢弃，服务器向其应答/转发会使数据扩散到整个广播域或多播组，形成放大攻击；
	- Magic Code
	- Type、header length、payload length，以及相互关系；
	- 将实际数据包的长度与根据上面各字段计算得到的值进行比较；
	- C=1 时 command 必须非 0（全 0 判定为错误包）；除此之外**不校验 command 的具体取值**，一律放行（具体值是否为系统指令、如何应答，由管理线程按场景处理，客户端自定义 command 亦不受限）；
	- source bid = 0 且 target bid ≠ 0 属于服务端上行校验规则（客户端不得伪造服务器下发包），判定后直接丢弃；
		- B=1 时 target bid 和 source bid 非 0 时不能相等，即服务器转发包不能发往同一个客户端（同时为 0 是第一次握手包，这个属于例外），判定后直接丢弃；
2. **管理线程**需要检查 command 及 source bid：
	- 如果 command 是 "SYN?"，则为第一次握手（唯一允许 source bid 无内存记录的场景）：先根据 socket 信息查表——记录存在（socket 匹配）则复用该 bid（重新握手，secret 取原 record.secret）；否则 source bid 非 0 时一律走预订流程（无论来源是否 loopback，先检查是否合法且未被占用，失败则回复 "FAIL" 指令包）；source bid 为 0 时，loopback 来源按内定规则分配 bid = port，其余来源分配新 bid（均不创建记录）；然后生成客户端密钥 secret（复用场景取原 record.secret，否则随机生成），以服务器密钥对其关键信息（bid、socket、secret、当前时间）计算 HMAC-SHA256 得到 token，随 "SYN!" 下发（载荷文本头 mp-secret 携带 secret，数据区携带 token 与 token_time，Base64 编码）——此阶段服务器**不创建任何记录**（无状态），记录在 "ACK!" 验证通过后才创建；
	- 如果 command 是 "ACK!"，则为第三次握手（无状态验证）：先检查载荷数据区 token_time 是否超出有效窗口（handshake_token_timeout，默认 60 秒），超时则回复 "FAIL" 指令包；否则用服务器密钥组（最多 2 个，见密钥轮换）对 "bid={协议头 source};socket={服务器观察到的来源 ip:port};secret={载荷包头 mp-secret};time={数据区 token_time}" 重算 HMAC-SHA256（Base64）并与数据区 token 比对，全部不匹配则判定为不可信来源，直接丢弃、不应答；匹配则按协议头 source bid 查表：记录不存在则创建 bid record（bid → socket、secret 取包内 mp-secret 并固定不变，连接即已确认）；记录已存在且 socket 匹配则幂等更新（重复 "ACK!" 或重新握手场景）；记录已存在但 socket 不同（bid 竞态冲突）则回复 "FAIL" 指令包（客户端重新握手）；
	- 否则 source bid 必须跟内存记录（socket 信息）匹配；凡 record.secret 已建立后收到的系统指令（"SYN?" 与 "ACK!" 除外：前者无记录、后者走无状态令牌验证），须先校验载荷文本头 mp-verify，校验失败视为不可信来源直接丢弃、不应答；然后根据 command 值进行相应的处理和应答（ACPT/DENY 按通行证管理流程处理，"PING" 回 "PONG"，"FIN?" 先将记录标记为离线 offline，再回 "FIN!" 挥手应答——不删除记录、不立即释放 bid，详见架构文档）；
3. **转发线程**需要检查两个 bid，只有 socket 信息匹配才会转发；其中 source bid 的记录必须存在且 socket 信息匹配（记录创建即已确认、无需再检查握手状态），记录不存在或 socket 不匹配（连接未建立/未确认，含 "ACK!" 丢失场景）时以 "FAIL"（载荷带 socket 信息，与 "SYN!" 相同）通知客户端并丢弃；target 记录不存在则直接丢弃；target 记录不活跃（已标记离线 offline，或 last_time 超过 T_active 在线判定窗口、默认 120 秒）时——发送方已被收件人接纳（(source bid, 当前 socket) 在 target 记录的通行证列表中）则回复 "FAIL"（数据区说明对端离线）通知发送方，否则静默丢弃；转发前还须确认 (source bid, 当前 socket) 在 target 记录的通行证列表中（收件人已通过 "ACPT" 接纳发送方），否则静默丢弃（不应答、不转发，防止暴露收件人的存在与接纳状态）；

## Bridge ID 管理

bid 为一个 32 位无符号整数，实际应用中取高 16 位整数 H（0 ~ 65535，其中 0 为内定保留区间；1 ~ 32767 为当前启用的普通分配与预订区间；32768 ~ 65535 为预留区间，当前不启用但合法，仅可能由客户端预订产生，见下文）与低 16 位整数 L（0 ~ 65535）合并而成。

socket 信息包括 ip 和 port 两个值，当其作为 key 查询时为 "{ip}:{port}" 的字符串。

设计要求： bid 与 socket 信息一一对应。

### 生成规则

bid (32位无符号整数) 由高 16 位无符号整数 H 和低 16 位无符号整数 L 构成：

1. 初始化内部私有变量 n（初始值为 1，最大值 32767）；
2. 每次生成时取 H = n（然后 n 自动 +1，超过最大值后回到 1）；
3. 每次生成时取 L = r（r 为随机整数，取值范围 0 ~ 65535）；
4. 最终获得 32 位无符号整数 bid = (H << 16) | L；
5. 检查内存中的分配表，如果 bid 冲突，回到步骤 2 重试；
6. 重试达到 M 次仍然冲突，表示服务器已满，暂时无法分配 bid，由管理线程回复 "FAIL" 指令包。

> 其中常量 M 默认 = 16（可通过配置文件 bid_allocation_retries 调整）
> 自动分配范围：服务器自动分配 bid 时，H 仅在 1 ~ 32767 范围内循环，即不会自动分配 H ≥ 32768 的 bid；该预留区间（H ≥ 32768）仅可能由客户端预订产生（见“内定与预订机制”）。

### 冲突判定

通过 bid 查询，如果记录不存在，或者记录中的 socket 信息相同，则无冲突；
反之，只要记录中的 socket 信息与当前不同，则判定为冲突（记录回收仅由管理线程在空闲时通过 purge 完成，其他线程不做超时覆盖判断）。

### 内存分配表

以 bid 为 key，或者 socket 信息为 key，均可查询分配记录。

记录字段包括：

- bid
- key  // "{ip}:{port}"
- socket 信息
- last_time  // 最后活跃时间
- secret  // 握手密钥（已确认）：服务器在握手时生成并随 "SYN!" 下发（复用已确认记录时下发原值），"ACK!" 验证通过后创建记录时写入；一经写入不再改变，直到该记录被回收
- offline  // 离线标记：收到 "FIN?" 后置位（记录保留、bid 不立即释放，仍按超时规则回收）；任何上行数据清除该标记并更新 last_time
- passes  // 通行证列表：本记录持有者已接纳的发送方 (bid, socket) 集合（允许向持有者发数据的白名单），由 ACPT/DENY 指令维护；随记录回收（purge）自动删除，无需额外清理

> key 为 socket 信息的字符串形式（"{ip}:{port}"），创建记录时生成一次即可；由于 ip 和 port 固定不变，后续查询时直接取用该字段，无需每次重新拼接。

服务器每次收到数据包并检查通过之后，就会更新 last_time 为当前时间；
注意，只有预处理线程和管理线程会更新 last_time，转发线程不需要这个动作，因为在预处理线程指派之前已经更新过了。

### 分配与回收

握手采用**无状态**方式："SYN?" 阶段服务器只做分配决策并计算验证令牌（token），**不创建任何记录**；记录在 "ACK!" 验证通过后才创建（创建即已确认，无需 pending_secret / acknowledged 字段，secret 固定不变）。

服务器收到握手请求（"SYN?" 指令）时：

1. 先根据 socket 信息查询内存分配表，
	1. 如果记录存在（socket 信息一定匹配），则复用该记录中的 bid（重新握手，secret 取原 record.secret，无需再检查 source bid）；
2. 如果请求中预设了 source bid（非 0），则一律按预订规则处理（无论来源是否 loopback）：
	1. 先检查该 bid 是否已有匹配记录（记录存在且 socket 信息相同，例如 loopback 客户端重新握手时携带之前的内定 bid）：有则复用该 bid（secret 取原 record.secret）；
	2. 否则检查该 bid 是否合法：必须大于 65535（即不能预订保留给 loopback 的内定区间 H=0），不合法则回复 "FAIL" 指令包；
	3. 检查该 bid 是否被占用：如果未被占用，则采用该 bid（待 "ACK!" 时创建记录）；
	4. 如果被其他 socket 占用，则回复 "FAIL" 指令包（由客户端决定是否重新申请）；
3. 来源 IP 为环回地址（loopback: 127.0.0.0/8, ::1/128）且请求中未预设 bid（source bid = 0）时，按内定规则分配 bid = port：
	1. 如果该 bid 不存在对应的分配记录，或记录 socket 信息相同，则采用该 bid（待 "ACK!" 时创建/复用记录）；
	2. 如果被其他 socket 占用，则判定为冲突，直接回复 "FAIL" 指令包（冲突协商由客户端进程自行处理）；
4. 按前面的规则生成新 bid 并检查冲突：
	1. 如果新 bid 不存在对应的分配记录，则采用该 bid（待 "ACK!" 时创建记录）；
	2. 如果分配记录已存在且 socket 信息相同（小概率），则按 1.1. 复用该 bid；
	3. 如果存在 bid 相同但 socket 信息不同的记录，则判定为冲突，无法占用此 bid，需重新生成 bid 并再次检查冲突（重试达到 M 次仍冲突，则由管理线程回复 "FAIL" 指令包，见生成规则第 6 条）。

得到 bid（无论新建、复用、预订还是内定）之后，生成客户端密钥 secret（新建/内定/预订时随机生成；复用已确认记录时取原 record.secret），并以服务器密钥对其关键信息计算验证令牌：

> token = HMAC-SHA256(key = server_secret, message = UTF-8("bid={bid};socket={socket};secret={secret};time={time}"))
> 其中 bid 为 10 进制整数、socket 为 "{ip}:{port}" 字符串、secret 为 Base64 编码、time 为服务器当前时间戳（秒，10 进制整数）；token 再 Base64 编码后随 "SYN!" 下发（载荷数据区 token 字段，token_time 字段为同一时间戳）。**此阶段不创建记录、不保存 bid 与 secret**（无状态）。

客户端收到 "SYN!" 后，在 "ACK!" 中原样回传 secret（载荷文本头 mp-secret）、token 与 token_time（载荷数据区，数据区 time 为客户端当前时间戳），服务器验证通过后创建记录（见管理线程职责）；若 "ACK!" 丢失，客户端在发送下一个包时因服务器查不到 bid record 而收到 "FAIL"（连接未确认），据此补发 "ACK!" 或重新握手。

> 每次创建分配记录时，都需要同时建立两个索引（分别以 bid、socket 信息为 key）指向该记录，以方便后面查询。
> secret 一经确认写入记录后不再改变（重新握手仅下发原值），直到该记录被回收。

### 服务器密钥轮换与握手防洪

服务器内部维护一个**密钥组 server_secrets**（列表，初始化时包含一个随机密钥）与最后生成时间 last_secret_time，用于计算/验证握手令牌 token：

- 生成 token 时：若 ```now - last_secret_time > server_secret_rotate_interval```（默认 600 秒），生成一个新随机密钥放入队头、更新 last_secret_time，并只保留最近 2 个密钥，然后取队头密钥计算；
- 验证 token 时：取出全部密钥（最多 2 个）逐个重算比对，任一匹配即通过（旧 token 在旧密钥被轮换出列表之前仍可验证）。

由于 "SYN?" 阶段不创建任何记录，握手洪流**不再消耗服务器内存**（无 syn_set、无未确认记录上限），防洪由以下手段共同承担：

- **防放大**：要求第 1 次握手包 "SYN?" 载荷不小于 handshake_min_payload（默认 512 字节），使应答 "SYN!" 显著小于请求，攻击者无法以微小请求放大出大流量应答；载荷不足或来源为广播/多播地址的请求直接丢弃、不应答（见预处理线程校验）；
- **无状态计算成本**：每次 "SYN?" 仅消耗一次 HMAC 计算与一次 bid 分配决策（只读查表），不落任何内存；洪水主要打满攻击者自身带宽与服务器 CPU，属可线性扩展的正常负载；
- **token 有效窗口**：token_time 超出 handshake_token_timeout（默认 60 秒）的 "ACK!" 直接回复 "FAIL"，防止旧握手包的重放与滞留；
- 更高强度的握手洪流（G 级）属运维层（防火墙包速率限制、流量清洗、Anycast/带宽冗余）的范畴，单机应用无法在协议层抵御。

管理线程空闲时执行回收职责：按 record_recycle_interval（默认 10 分钟）调用 purge(now) 回收超过 expires 的记录（同时删除对应的 bid 和 socket 信息索引）。

purge(now) 只负责回收超过 expires（默认 24 小时）的记录（```last_time < now - expires```），调用间隔默认 10 分钟，可通过配置文件 record_recycle_interval 调整；正常运营时分配表规模为在线用户数（万级），一次遍历毫秒级，10 分钟一次的摊销 CPU 占比不足 0.01%。purge 实现上分两阶段：第一阶段**只读遍历**分配表、收集过期记录（不写，仅短暂共享读锁），第二阶段再**逐条删除**，以缩短持锁时间。

> 回收时效默认 24 小时（expires = 3600 * 24，秒），可通过配置文件 record_expires 调整。

- **不做惰性回收**：管理线程在按 bid 或 socket 信息查询分配表时**不检查是否过期**（只要记录存在就按存在处理，分配与冲突判定逻辑保持简单）；过期记录的回收统一由 purge 完成。
- 按来源 IP 的 "SYN?" 限速在 UDP 下可被伪造来源地址绕过，不作为协议层防洪水手段。

> 注：“在线”判定窗口 T_active（见工作流文档，默认 2 分钟，可通过配置文件 record_active_timeout 调整）与回收时效 expires（默认 24 小时，可通过配置文件 record_expires 调整）是两个不同的参数：T_active 用于转发线程判断记录是否活跃（在线），expires 用于管理线程回收超时记录。

### 内定与预订机制

由于一台机器能绑定的端口 port 取值范围刚好是 0 ~ 65535，与 bid 的低 16 位 L 取值范围一致，所以特设 H=0 作为保留 bid 给内部进程使用：

- **内定**：对于来源 IP 是环回地址（loopback: 127.0.0.0/8, ::1/128）且第一次握手请求中 source bid 为 0 的客户端，则直接用其端口 port 作为 bid（即 bid 的高 16 位 H=0），这个属于 Bridge ID 管理机制为内部进程保留的 bid 区间。内定 bid 与其他 bid 一样，在 "ACK!" 验证通过后创建记录并参与超时回收（24 小时无上行数据即释放）。若内定 bid 被其他 socket 占用（例如不同 loopback IP 使用相同端口），直接回复 "FAIL" 指令包，由客户端进程自行协商后续。
- **预订**：客户端（无论 loopback 还是外部来源）在发送 "SYN?" 请求分配 bid 的时候，只要预设了 source bid（非 0），即走预订流程，不再走内定流程：先检查该 source bid 是否已有匹配记录（记录存在且 socket 信息相同，例如 loopback 客户端重新握手时携带之前的内定 bid），有则直接复用；否则检查其是否合法（必须大于 65535，即不能预订保留给 loopback 的内定区间）且未被其他 socket 占用：合法且空闲则采用该 bid（待 "ACK!" 验证通过后创建记录）；如果非法、或被其他 socket 占用，则回复 "FAIL" 指令包。

注意：客户端不能预订 H=0 的内定区间（0 ~ 65535），即所有预订成功的 bid 必定大于 65535；预订 bid 不设上限（H 合法范围 0 ~ 65535），其中 H ≥ 32768（bid ≥ 2147483648）属于预留区间，服务器校验时不拒绝，但实际应用中无特殊原因不要申请这类预订 bid；loopback 客户端若想放弃“内定权利”（不想要 bid = port），在 "SYN?" 中预设 source bid 走预订流程即可。

## 流量控制

限流采用**滑动窗口**方式：每条转发线程在 `forward_window` 秒内最多处理 `forward_limit_per_window` 个任务，达到上限后本轮窗口内不再取新任务，等待下一个窗口再继续；超过队列容量（forwarder_queue_size）的新包直接丢弃并记录日志（由客户端可靠传输机制重试）。

当前默认配置下单线程上限为 `4096 / 0.1s = 40960 包/秒`，8 条线程合计约 `327,680 包/秒`；单线程转发队列容量 `65536`（最坏约 64 MiB/线程，按满载荷 1KiB 计），足以缓冲约 1.6 秒的突发流量。相关参数均可通过配置文件调整（见 server 文档）：

- forwarders（线程数，默认 8）
- forwarder_queue_size（单线程转发队列容量，默认 65536）
- forward_limit_per_window（每窗口处理上限，默认 4096）
- forward_window（窗口时长，默认 0.1 秒）

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
# 120.0 = 2 minutes)
record_active_timeout = 120.0
# handshake flood guard: minimum payload length of the first
# handshake packet "SYN?" (bytes, default: 512)
handshake_min_payload = 512
# server secret rotation: a new server secret is generated and put at
# the head of server_secrets when it has been longer than this since
# the last rotation; at most the latest 2 secrets are kept for token
# verification (seconds, default: 600.0 = 10 minutes)
server_secret_rotate_interval = 600.0
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
2. 容量类参数（waiting_queue_size、manager_queue_size、forwarder_queue_size、socket_buffer_length）均为整数：前三者是包数，后者是字节数；
3. 所有键缺失、段缺失或文件缺失时均回退到代码默认值（host 默认 0.0.0.0、port 默认 9527、forwarders 默认 8，与其余键行为一致）；
4. 命令行 --config 指定的路径优先于默认路径；配置文件不存在时不报错，直接使用全部默认值。
