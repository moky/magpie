# Magpie Bridge (Server)

这里定义 Magpie Bridge 服务器。

## 各模块（线程）设计

正如 **Magpie Bridge Architecture** 里定义的那样：

1. 服务器通过一个**接收线程**从绑定的 UDP 端口中读取数据包，然后直接放入等待处理队列；
2. **预处理线程**从前面的等待处理队列取出数据包，进行简单的校验之后，根据 target bid 决定是转交给“管理线程”处理，还是转交给“转发线程”处理；
3. 服务器有一个**管理线程**，专门负责 bid 的分配管理、超时记录回收（未确认记录的 syn_set 高频扫描 + 常规记录的 purge）、通行证管理（ACPT/DENY），以及几个系统命令的应答；
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
	- 如果 command 是 "SYN?"，则为第一次握手（唯一允许 source bid 无内存记录的场景）：source bid 非 0 时一律走预订流程（无论来源是否 loopback，先检查是否合法且未被占用，失败则回复 "FAIL" 指令包）；source bid 为 0 时，loopback 来源按内定规则分配 bid = port，其余来源分配新 bid；新建（未确认）记录时生成一个随机数存于记录（pending_secret），随 "SYN!" 下发（载荷文本头 mp-secret，Base64 编码）；复用已确认记录时不再重新生成，直接下发原 record.secret（secret 一经确认不再改变）；
	- 如果 command 是 "ACK!"，则为第三次握手：校验 "ACK!" 载荷文本头 mp-verify（HMAC-SHA256，对数据区全部字节计算，与记录中的待确认密钥比对：pending_secret 存在时用 pending_secret，否则用 record.secret）；校验通过后清除 offline 标记并标记/保持该记录为已确认（acknowledged，连接建立）——若记录尚未确认则将密钥转存为 record.secret（删除 pending_secret）；若记录已确认则 secret 保持不变（不覆盖、不轮换）；
	- 否则 source bid 必须跟内存记录（socket 信息）匹配；凡 record.secret 已建立后收到的系统指令（"SYN?" 除外），须先校验载荷文本头 mp-verify，校验失败视为不可信来源直接丢弃、不应答；然后根据 command 值进行相应的处理和应答（ACPT/DENY 按通行证管理流程处理，"PING" 回 "PONG"，"FIN?" 先将记录标记为离线 offline，再回 "FIN!" 挥手应答——不删除记录、不立即释放 bid，详见架构文档）；
3. **转发线程**需要检查两个 bid，只有 socket 信息匹配才会转发；其中 source bid 还须已完成第三次握手（ACK!），连接未确认时以 "FAIL"（载荷带 socket 信息，与 "SYN!" 相同）通知客户端；target 记录不存在则直接丢弃；target 记录不活跃（已标记离线 offline，或 last_time 超过 T_active 在线判定窗口、默认 120 秒）时——发送方已被收件人接纳（(source bid, 当前 socket) 在 target 记录的通行证列表中）则回复 "FAIL"（数据区说明对端离线）通知发送方，否则静默丢弃；转发前还须确认 (source bid, 当前 socket) 在 target 记录的通行证列表中（收件人已通过 "ACPT" 接纳发送方），否则静默丢弃（不应答、不转发，防止暴露收件人的存在与接纳状态）；

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
反之，只要记录中的 socket 信息与当前不同，则判定为冲突（记录回收仅由管理线程在空闲时完成——未确认记录经 syn_set 高频扫描、常规记录经 purge，其他线程不做超时覆盖判断）。

### 内存分配表

以 bid 为 key，或者 socket 信息为 key，均可查询分配记录。

记录字段包括：

- bid
- key  // "{ip}:{port}"
- socket 信息
- last_time  // 最后活跃时间
- acknowledged  // 是否已完成第三次握手（ACK!），置位后连接才算 established
- pending_secret  // 握手密钥（待确认）：仅服务器**新建** bid 记录（尚未确认）时生成，随 "SYN!" 下发，客户端 "ACK!" 回传校验值通过后转正为 record.secret；复用已确认记录时不再重新生成，直接下发原 record.secret
- secret  // 握手密钥（已确认）：双方共享，用于此后所有系统指令（含应答）的 HMAC-SHA256 校验（mp-verify）；一经确认写入记录后不再改变（重新握手仅下发原值），直到该记录被回收
- offline  // 离线标记：收到 "FIN?" 后置位（记录保留、bid 不立即释放，仍按超时规则回收）；任何上行数据清除该标记并更新 last_time
- passes  // 通行证列表：本记录持有者已接纳的发送方 (bid, socket) 集合（允许向持有者发数据的白名单），由 ACPT/DENY 指令维护；随记录回收（purge）自动删除，无需额外清理

> key 为 socket 信息的字符串形式（"{ip}:{port}"），创建记录时生成一次即可；由于 ip 和 port 固定不变，后续查询时直接取用该字段，无需每次重新拼接。

服务器每次收到数据包并检查通过之后，就会更新 last_time 为当前时间；
注意，只有预处理线程和管理线程会更新 last_time，转发线程不需要这个动作，因为在预处理线程指派之前已经更新过了。

### 分配与回收

服务器收到握手请求（"SYN?" 指令）时：

1. 先根据 socket 信息查询内存分配表，
	1. 如果记录存在（socket 信息一定匹配），则更新 last_time，然后返回该记录 bid；
2. 如果请求中预设了 source bid（非 0），则一律按预订规则处理（无论来源是否 loopback）：
	1. 先检查该 bid 是否已有匹配记录（记录存在且 socket 信息相同，例如 loopback 客户端重新握手时携带之前的内定 bid）：有则更新 last_time 并复用该 bid；
	2. 否则检查该 bid 是否合法：必须大于 65535（即不能预订保留给 loopback 的内定区间 H=0），不合法则回复 "FAIL" 指令包；
	3. 检查该 bid 是否被占用：如果未被占用，则创建该记录并返回 bid；
	4. 如果被其他 socket 占用，则回复 "FAIL" 指令包；
3. 来源 IP 为环回地址（loopback: 127.0.0.0/8, ::1/128）且请求中未预设 bid（source bid = 0）时，按内定规则分配 bid = port：
	1. 如果该 bid 不存在对应的分配记录，或记录 socket 信息相同，则创建/复用该记录并返回 bid；
	2. 如果被其他 socket 占用，则判定为冲突，直接回复 "FAIL" 指令包（冲突协商由客户端进程自行处理）；
4. 按前面的规则生成新 bid 并检查冲突：
	1. 如果新 bid 不存在对应的分配记录，则创建新记录，然后返回该 bid；
	2. 如果分配记录已存在且 socket 信息相同（小概率），则按 1.1. 重用该记录；
	3. 如果存在 bid 相同但 socket 信息不同的记录，则判定为冲突，无法占用此 bid，需重新生成 bid 并再次检查冲突（重试达到 M 次仍冲突，则由管理线程回复 "FAIL" 指令包，见生成规则第 6 条）。

> 每次新建分配记录时，都需要同时建立两个索引（分别以 bid、socket 信息为 key）指向该记录，以方便后面查询。
> 新建（未确认）记录回复 "SYN!" 时，管理线程生成一个随机数存入记录（pending_secret），随 "SYN!" 载荷文本头下发（mp-secret，Base64 编码）；待客户端 "ACK!" 回传校验值（mp-verify）并通过校验后，转存为 record.secret（见管理线程职责）。**复用已确认记录的重新握手（无论 socket 匹配复用、内定还是预订）不再重新生成 secret，直接下发原 record.secret**——secret 一经确认写入记录后不再改变，直到该记录被回收。

管理线程空闲时，按以下两条路径执行回收职责（均同时删除对应的 bid 和 socket 信息索引）：

**（1）syn_set 高频扫描（防洪核心，未确认记录的回收）**

管理线程内部维护一个**私有集合 syn_set**（用哈希集合实现，add/remove 均 O(1)），存放所有"尚未完成握手"（未收到 "ACK!"、acknowledged 未置位）的 bid：

- 创建/复用 bid 记录并回复 "SYN!" 时，将该 bid 加入 syn_set（幂等：重复 add 无害，预订复用同一 bid 时无需额外处理）；
- 收到 "ACK!" 且校验通过（acknowledged 置位）时，将该 bid 移出 syn_set；
- 扫描时先**复制 syn_set 快照**（复制成本可忽略：正常同时握手的只有几十~几百条；洪水极端 100 万条也仅 10~20 ms/轮），再逐个调用内部方法 recyclePending(bid) 检查回收——这样遍历期间无需长持锁，管理线程的 add/remove 不被阻塞。

recyclePending(bid)（BidManager 内部方法，幂等）：

1. 持有 BidManager 锁，按 bid 查询分配记录；
2. 记录不存在 → 返回 False（调用方将该 bid 移出 syn_set，防止集合残留"僵尸"bid——purge 等路径删除记录后由这里自愈）；
3. 记录已 acknowledged → 返回 False（竞态防护：避免"刚收到 "ACK!" 却被删除"——ACK! 处理与 recyclePending 共用同一把 BidManager 锁，二者互斥，不会误删刚完成的握手）；
4. 记录未超时（```last_time >= now - handshake_pending_timeout```，默认 10 秒）→ 返回 False（保留）；
5. 否则删除记录 → 返回 True（由调用方将该 bid 移出 syn_set）。

扫描循环的 sleep 分三档：

- syn_set 为空：sleep **2 秒**（没有可过期的对象，尽量少空转；新 bid 最迟 2 秒后被纳入扫描，10 秒有效期内无影响）；
- 非空但本轮无回收：sleep **1 秒**（有记录在"倒计时"，1 秒间隔把回收滞后压到 1 秒内）；
- 本轮有回收：**立即进入下一轮**（洪水时自动保持高频，连续扫到一轮无回收为止）。

未确认记录的**最坏滞留时间 = handshake_pending_timeout + 1 秒 ≈ 11 秒**；洪水稳态存量 ≈ 攻击速率 × 11 秒。

**（2）purge(now) 低频回收（常规超时记录）**

purge(now) 只负责回收超过 expires（默认 24 小时）的记录（```last_time < now - expires```），调用间隔默认 10 分钟，可通过配置文件 record_recycle_interval 调整。未确认记录的回收已由 syn_set 高频扫描承担，purge 不再参与，因此 10 分钟一次的全表遍历成本可以忽略：正常运营时分配表规模为在线用户数（万级），一次遍历毫秒级；即使极端到百万条记录（洪水场景下未确认记录已被 syn_set 及时清除、不会滞留到 24 小时），一次遍历也仅 10~50 ms，10 分钟一次的摊销 CPU 占比不足 0.01%。purge 实现上分两阶段：第一阶段**只读遍历**分配表、收集过期记录（不写，仅短暂共享读锁），第二阶段再**逐条删除**，以缩短持锁时间。

> 回收时效默认 24 小时（expires = 3600 * 24，秒），可通过配置文件 record_expires 调整；
> 未确认握手短超时（默认 10 秒）可通过配置文件 handshake_pending_timeout 调整。

- **不做惰性回收**：管理线程在按 bid 或 socket 信息查询分配表时**不检查是否过期**（只要记录存在就按存在处理，分配与冲突判定逻辑保持简单）；过期记录的回收统一由上述两条路径完成。洪水创建的"僵尸"未确认记录被查询路径恰好命中的概率极小（bid 空间 2^32，命中概率与未确认记录数/总空间同阶），为此引入额外的过期判断分支收益极小、得不偿失；
- **未确认记录上限（内存保护）**：syn_set 的大小达到 unconfirmed_record_limit（默认 1000000）时，新的 "SYN?" 直接丢弃、不应答（syn_set 的 size 查询是 O(1)，上限判断零成本）。该上限仅用于防止极端情况下的内存失控（每条未确认记录约几十字节，100 万条约 64 MiB）。要打满此上限，攻击者需以约 53 MB/s 的维持流量（按最小载荷 512 字节、最坏滞留 11 秒计，约 10 万 "SYN?"/秒）持续灌注伪造来源的握手包——达到该强度的攻击已会先打满单机 CPU（每包分配+回包约 1~2 µs，10 万包/秒占 10~20% 单核）与带宽，**内存上限并非最先失效的防线**，它只负责"CPU 与带宽被打满之前，内存不被堆爆"。更高强度的握手洪流（G 级）属运维层（防火墙包速率限制、流量清洗、Anycast/带宽冗余）的范畴，单机应用无法在协议层抵御；协议层不为此牺牲正常客户端（不缩短有效时间），仅适度提高握手最小载荷（默认 512 字节，见配置）以抬高攻击门槛并增大防放大余量，防洪水由 handshake_min_payload（防放大）、syn_set 高频回收与内存保护上限共同承担。
- 按来源 IP 的 "SYN?" 限速在 UDP 下可被伪造来源地址绕过，不作为协议层防洪水手段。

> 注：“在线”判定窗口 T_active（见工作流文档，默认 2 分钟，可通过配置文件 record_active_timeout 调整）与回收时效 expires（默认 24 小时，可通过配置文件 record_expires 调整）是两个不同的参数：T_active 用于转发线程判断记录是否活跃（在线），expires 用于管理线程回收超时记录。

### 内定与预订机制

由于一台机器能绑定的端口 port 取值范围刚好是 0 ~ 65535，与 bid 的低 16 位 L 取值范围一致，所以特设 H=0 作为保留 bid 给内部进程使用：

- **内定**：对于来源 IP 是环回地址（loopback: 127.0.0.0/8, ::1/128）且第一次握手请求中 source bid 为 0 的客户端，则直接用其端口 port 作为 bid 绑定（即 bid 的高 16 位 H=0），这个属于 Bridge ID 管理机制为内部进程保留的 bid 区间。内定 bid 与其他 bid 一样参与超时回收（24 小时无上行数据即释放）。若内定 bid 被其他 socket 占用（例如不同 loopback IP 使用相同端口），直接回复 "FAIL" 指令包，由客户端进程自行协商后续。
- **预订**：客户端（无论 loopback 还是外部来源）在发送 "SYN?" 请求分配 bid 的时候，只要预设了 source bid（非 0），即走预订流程，不再走内定流程：先检查该 source bid 是否已有匹配记录（记录存在且 socket 信息相同，例如 loopback 客户端重新握手时携带之前的内定 bid），有则直接复用；否则检查其是否合法（必须大于 65535，即不能预订保留给 loopback 的内定区间）且未被其他 socket 占用：合法且空闲则分配给当前 socket；如果非法、或被其他 socket 占用，则回复 "FAIL" 指令包。

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
# record_expires, so a full-table scan is rare and cheap; unconfirmed
# handshake records are recycled by the high-frequency syn_set scan
# instead, see the server doc)
record_recycle_interval = 600.0
# online judging window: the forwarder drops the target when its
# record has been inactive for longer than this (seconds, default:
# 120.0 = 2 minutes)
record_active_timeout = 120.0
# handshake flood guard: minimum payload length of the first
# handshake packet "SYN?" (bytes, default: 512)
handshake_min_payload = 512
# handshake pending timeout: an unconfirmed bid record (the client
# sent "SYN?" but has not completed "ACK!") is considered expired
# when it has been inactive for longer than this (seconds, default:
# 10.0; the syn_set scan reclaims it within ~1 second afterwards, so
# the worst-case lifetime is about 11 seconds)
handshake_pending_timeout = 10.0
# unconfirmed record limit (memory protection only): when the number
# of unconfirmed bid records (syn_set size) reaches this limit, new
# "SYN?" packets are dropped silently (default: 1000000; about 64 MiB
# at ~64 bytes per record; sustaining this limit needs roughly
# 23 MB/s of forged handshake traffic, see the server doc)
unconfirmed_record_limit = 1000000
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
