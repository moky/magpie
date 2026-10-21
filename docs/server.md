# Magpie Bridge 服务器实现

实现 [architecture.md](architecture.md) 与 [workflow.md](workflow.md) 中定义的服务器行为。本文档合并给出完整实现细节：线程模块、校验链、Bridge ID 管理、记录生命周期、密钥轮换、流量控制、应用密钥重载与全部配置项。

---

## 1. 模块与线程

| 线程 | 数量 | 职责 |
|------|------|------|
| 接收线程 | 1 | 绑定 UDP 端口收包，封装为**任务**（数据包 + 来源 socket）放入等待队列 |
| 预处理线程 | 1 | 基础校验与分拣（见 2 节），target=0 给管理线程、其余按 `source bid % W` 给转发线程 |
| 管理线程 | 1 | bid 分配、purge 回收、通行证管理、系统指令应答、应用密钥重载 |
| 转发线程 | W（默认 8） | 数据转发（见 3 节） |

> 队列元素是"任务"（数据包 + 来源 socket 的封装），不是裸数据包；队列容量见配置表（waiting/manager/forwarder 三个队列）。

---

## 2. 预处理线程校验链

按顺序执行，任一失败静默丢弃（不应答、不转发）：

1. **来源 IP 检查**：广播/组播地址（IPv4 224.0.0.0/4、255.255.255.255；IPv6 ff00::/8 等）→ 丢弃；
2. **协议头校验**：
   - Magic Code 4 字节匹配；
   - 由 type 计算的协议头长度 N = 8 + 8B + 4D + 2E + 4C，须与 header_length 字段一致（E 取 5/6/7 即错误）；
   - `N + payload_length` 与实际包长差值 ∈ {0, 32}（0 无校验码，32 尾 32B 为 attachment）；
   - C=1 时 command 必须非 0；D=0 时 E 必须为 0；D=1 时 sn 必须非 0；E>0 时 `0 <= index < count` 且 count > 1；
3. **上行校验违规**：B 必须为 1；target≠0 时 source 不能为 0；target 与 source 不能相等；
4. **分拣**：target=0 → 管理线程；target/source 均非 0 → 转发线程。

> 预处理不查分配表、不更新活跃时间，只做纯包级校验与分拣。

---

## 3. 转发线程

### 3.1 任务指派

- 预处理按 `n = source bid % W` 指派任务；每条转发线程辖若干 source bid；
- 线程内部为每个 source bid 维护等待转发队列；
- runloop **广度优先轮询**辖下 bid，取队首任务，全部空则 sleep 后再轮询。

### 3.2 转发校验链

1. **来源检查**：按来源 socket 查分配表——
   - 无记录 → "连接未确认"，回复 "FAIL"（受共享计数器限频）后丢弃；
   - socket 匹配但 source bid 与记录不一致 → 伪造来源，丢弃；
2. **附加校验**：带校验码的包用 `record.secret` 验证 HMAC-SHA256，失败即丢弃；
3. **离线分流**：记录 offline == true → 静默丢弃（不更新 last_time）；
4. 以上检查全部通过后更新 last_time；
5. **目标检查**：target bid 记录不存在 → 伪造包，静默丢弃；
6. **通行证检查**：发送方是否有权向 target 发送（双向查找 + 通配放行，见架构文档 8.5），不满足 → 静默丢弃（不暴露收件人存在状态）；
7. **目标状态**：target 记录 offline 或 `last_time` 超 `T_active`（60s）→ 回复 "FAIL"（src-command + src-target + time）通知发送方；
8. **转发**：用接收方的 secret 重新签名（替换校验码），原样发给 target socket。

### 3.3 流量控制

滑动窗口限流：每条转发线程在 `forward_window` 秒内最多处理 `forward_limit_per_window` 个任务；队列满（`forwarder_queue_size`）的新任务直接丢弃并记日志（由客户端可靠传输重试）。

---

## 4. 管理线程

每个 runloop：

1. **回收检查**：距上次调用超过 `record_recycle_interval`（600s）则调用 `purge(now)` 回收超时记录及关联的通行证条目；
2. 从管理请求队列取下一个任务（空则阻塞等待）；
3. 按 command 走子流程：
   - "SYN?"：唯一允许 source bid = 0 的场景（分配/预订/内定，见 5 节）；
   - "ACK!"：无状态 token 校验，通过后创建记录；
   - 其余系统指令：先来源检查（socket 查表 → 无记录按连接未确认；不匹配按伪造丢弃）；再附加校验（HMAC，失败即丢弃）；再**离线分流**（记录 offline == true 且 command 不属于 "FIN?"/"NOOP" → 静默丢弃、不更新 last_time）；再更新 last_time，再指令集过滤（未知指令丢弃），最后按 command 执行；
4. 周期任务：应用密钥重载（见 6.4）。

> last_time 仅在**来源检查、附加校验与离线分流全部通过后**更新；任何校验失败或离线期间被丢弃的包不得刷新活跃时间。

---

## 5. Bridge ID 管理

### 5.1 生成规则

bid 为 32 位无符号整数，**全随机**生成：在 `0x00010000 ~ 0x7FFFFFFF` 取均匀随机整数（高 16 位 H = 1 ~ 32767，低 16 位 L = 0 ~ 65535 全组合）。冲突则重新随机，重试 `bid_allocation_retries`（16）次仍冲突 → 回复 "FAIL"。

- 下限 0x00010000：保证不落入 0 ~ 65535 的内定保留区间；
- 上限 0x7FFFFFFF：保证不自动分配 H ≥ 32768 预留区间（该区间仅可能由客户端预订产生）；
- 可用空间约 21.47 亿，碰撞概率不足万分之一。

### 5.2 内定

来源 IP 为环回地址（127.0.0.0/8、::1/128）且 source bid = 0 的客户端，直接以端口 port 作为 bid（H=0 保留区间）。

### 5.3 预订

客户端在 "SYN?" 预设 source bid（非 0）即走预订：

- 预订 bid 必须大于 65535（不能预订内定区间）；
- H ≥ 32768 属于预留区间但服务器校验不拒绝；
- 预订被占用/非法 → 回复 "FAIL"；
- 预订成功 → "SYN!" 的 target 为预订 bid。

### 5.4 冲突判定

| 情况 | 处理 |
|------|------|
| 预订 bid 已在表中 | "FAIL" |
| 随机分配与已有记录冲突 | 重试（上限 16 次） |
| 内定 bid 被占用 | "FAIL" |
| 新建记录达 max_records 上限 | "FAIL" |

### 5.5 记录复用

"SYN?" 先按来源 socket 查询分配表，记录存在即复用（无论在线/离线）：bid 与 secret 均取原记录值（"SYN!" 下发原值），"ACK!" 幂等分支恢复在线；复用不新建记录，不受 `max_records` 上限影响。

---

## 6. 记录生命周期

### 6.1 分配表与索引

内存表 + 两套索引（bid → record、socket key → record），一一对应：一个 bid 只分配给一个 socket；一个 socket 最多一条记录。

### 6.2 创建与更新

- 记录在 "ACK!" 验证通过后创建（无状态握手，创建即确认）；
- 每收到有效包更新 last_time（管理/转发线程）；
- offline 标志由 "FIN?" 置位（`noop_immunity_window` 内不置位，见安全文档）、"ACK!" 复用或 "NOOP" 清除；offline == true 期间仅 "SYN?"/"ACK!"/"FIN?"/"NOOP" 放行，其余指令（含 "PING"、数据包）一律静默丢弃、不更新 last_time。

### 6.3 回收（purge）

```python
    def _purge(self, now: float):
        # 0. 取配置中的 record_expires（默认 24 小时）
        expires = self._config.record_expires
        min_expires = self._config.record_active_timeout
        max_records = self._config.max_records * 0.8
        # 当前记录总数
        count = self._count_of_records()
        while True:
            # 1. 从记录分配表中获取超时记录
            expired_records = self._select_expired_records(expires=expires)
            # 2. 逐条回收：先反向清理通行证，再删除记录
            for record in expired_records:
                with self._lock:
                    # 2.1. 删除通行证（反向清理）：
                    #      读本记录 allowlist，按其中 bid 反向定位对方记录删条目
                    self._remove_permits(record=record)
                    # 2.2. 删除记录（同时清理索引）
                    self._remove_record(record=record)
            # 3. 检查余量
            count -= len(expired_records)
            if count < max_records:
                # 剩余空间充足，清理结束
                return True
            # 记录数仍超过最大容量的 80%，剩余空间紧张
            # 紧急自救：缩短超时时间继续下一轮清理
            expires /= 2.0
            if expires <= min_expires:
                break
        # 记录超时时间已缩至极限，服务器仍高负荷运行
        return False
```

- 周期触发：管理线程每 `record_recycle_interval`（600s）调用一次（**周期触发**，非仅在空闲时）；
- 正常回收：`last_time` 超过 `record_expires`（86400s = 24h）即回收；
- **紧急自救**：记录数仍 ≥ `max_records × 0.8` 时，回收阈值逐轮减半至 `record_active_timeout`（60s），仍超限则判定高负荷；
- 残留条目清理（见架构文档 8 节）：删除记录前先反向清理——读本记录 allowlist 的键（该记录许可过的对方 bid），按 bid 找到对方记录并删除其中引用本 bid 的条目，再删除记录（同时移除 bid 索引与 socket 索引）——无需维护任何全局索引；
- 锁粒度：收集无锁（记录分配表结构仅管理线程增删），逐条删除持短锁；
- 查询不做惰性过期判断（记录存在即按有效处理），回收统一由 purge 完成。

### 6.4 应用密钥重载

管理线程在回收检查的同时（同一时间间隔 `app_secret_reload_interval`，默认 600s）重读 `app_secret_file`：

- 读取/解析成功 → 整体替换内存映射表（密钥轮换、吊销生效）；
- 映射表为空 → 切换为非加密模式（基础握手）；
- 读取失败/文件消失 → **保留旧表继续运行**（不降级、不中断）。

### 6.5 通行证内存布局（实现）

Record 与 SocketAddress 是按记录数量存在的热对象，实现时建议采用固定实例布局（Python 版用 `__slots__`，Java 版无实例字典开销）；Permit 已槽化为定长槽，**无持久对象实例**。

记录主体采用**单 buffer 定长行**（创建记录时一次分配，随记录回收整体释放）：头部 secret(32) + bid(4) + hash31(4) + ip(16) + port(2) + 保留(1) + offline(1) + last_time(8) + last_noop_time(8) + 保留(2) + cnt(2) = **80 字节**（hash31 为自己 socket 的 31 位身份哈希缓存，供通行证匹配复用；`-` 为保留/未定义字节，共 3 B，字节对齐填充），后随槽区合并存放；**头部字段与槽区 bid/value 均按大端（网络字节序）存储，与协议字段一致**；头部字段按固定偏移 pack/unpack 读写，避免每字段一个对象引用。

allowlist 槽区与头部共用**单 buffer 定长槽**：

- 槽区长度派生自配置：`allowlist_max_entries × 8` 字节（槽 {bid 4, value 4} 统一 8B，IPv4/IPv6 同格式）；槽区随记录创建一次分配（与头部合并为同一 buffer），随记录回收整体释放；
- 每槽为**单向通行证**（Permit._t 的定长化；槽主即所属记录，其 socket 不入持久存储、由所属记录提供）：bid(4) + value(4)；value = 31 位哈希 | valid——身份哈希 `hash31(socket) = SHA-256(socket) 截 32 位 & 0xFFFFFFFE`（高 31 位，bit0 恒 0），写槽 `value = hash31 | valid`，valid 为 bit0（0 = 未确认、1 = 已确认）；读身份（比较）：槽值 & 0xFFFFFFFE 与 record.hash31 比较；读 valid：槽值 & 1；跨侧置位：槽值 |= 1；
- `searchPermit(bid)` 返回**临时可写视图**（槽主 socket + 槽内哈希 + valid，不入池）：match 为 record.socket 等于槽主（完整 socket 精确比较）或 record.hash31 与槽内哈希相等（31 位比较，对称判定防 bid 重用）；视图**持槽引用**（buffer + 槽偏移），`accept(record)` 在 match 命中时置槽内 valid=1 并同步写回（跨侧置位的落点即视图引用的原槽）；`insertPermit` 把视图当前状态（哈希 + valid）拷入新槽；
- 布局：槽整体从头部之后正向按 bid 升序存放（槽 i 位于 `80 + i×8`），查询/插入/删除共用同一套二分 + memmove；剩余空间 = `槽区长度 − cnt×8`，追加前须 ≥ 8——容量 = `allowlist_max_entries`；
- 残余风险：match 基于 31 位哈希快照，同一 bid 新旧持有者定向碰撞概率 2^-31（静默误放行仅理论存在；owner 侧仍为完整 socket 精确比较）；
- **双向确认由跨侧置位实现**：后发 "ACPT" 一方建立自己侧槽的同时（新槽 valid=1），将先发方侧对应槽 valid 置位（单方 "ACPT" 不置位、未生效）；"DENY" 只删自己侧槽；"DENY *" 清空直接置 cnt = 0；
- **通配通行证**（"ACPT *" 触发 `allowAll()`）固定写槽 0，槽内容 {bid:1, value:固定值}（match 恒真，value 无实际用途），并置 cnt=1（清除全部定向授权）；`isAllowAll()` 判定 O(1)：`cnt ≥ 1 且槽 0 的 bid 字段 == 1`。bid=1 属内定保留区间（H=0），不会与真实授权撞车。

#### Record buffer 内存分配格式

记录头部字段顺序可按需调整（按固定偏移存取）；以下为满足字节对齐的调整版：

```
     0                   1                   2                   3
     0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    | (record header starts)                                        |
    |                                                               |
    |                                                               |
    |                         record secret                         |
    |                           (32 Bytes)                          |
    |                                                               |
    |                                                               |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                      record bid (4 Bytes)                     |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                    socket hash31 (4 Bytes)                    |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                                                               |
    |                           socket IP                           |
    |                           (16 Bytes)                          |
    |                                                               |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |     socket port (2 Bytes)     |       -       |    offline    |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                       last active time                        |
    |                           (8 Bytes)                           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                        last noop time                         |
    |                           (8 Bytes)                           |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |               -               |    permits count (2 Bytes)    |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    | (allowlist starts)      bid (4 Bytes)                         |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                 value = hash31|valid (4 Bytes)                |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                         bid (4 Bytes)                         |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                 value = hash31|valid (4 Bytes)                |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    |                              ...                              |
    +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

其中：

1. 不变量：`record bid`、`secret`、`socket hash31`、`IP`、`port` 随记录创建即固定不变；
2. 可变量：`last active time` 由管理线程和转发线程更新，`last noop time`、`offline` 仅由管理线程更新；
3. 通行证：从第 80 字节开始，后面为通行证区，长度由 ```allowlist_max_entries × 8``` 决定，记录数由 `permits count` 字段表示；每条记录 8 字节，前 4 字节为对方记录 bid，后 4 字节中，前 31 bits 为对方记录 socket hash31，最后 1 bit 为通行证有效标志位；槽 i 位于 `80 + i×8`；
4. 线图全称 ↔ 文档字段名：record secret=secret、record bid=bid、socket hash31=hash31、socket IP=ip、socket port=port、offline=offline、last active time=last_time、last noop time=last_noop_time、permits count=cnt；
5. 线图中 `-` 为保留/未定义字节（对齐填充）。

#### 视图与接口实现（代码形态）

槽化后没有持久 Permit 对象：`searchPermit` 返回**临时可写视图**（持槽引用，不入池）。

```dart
/// 槽 = { bid, hash31|valid }
///   槽主 = 所属 record（自己的 socket，不入槽，由记录提供）
///   槽 8 B：bid(4) + value(4)，头部之后正向，槽 i @ 80 + i×8；bid/value 均大端
///   value = hash31 | valid（hash31 = SHA-256(socket) 截 32 位 & 0xFFFFFFFE，bit0 = valid）
///   槽整体按 bid 升序；剩余空间 = 槽区长度 − cnt×8
class PermitView {                     // 临时可写视图，不入池
    final Record owner;                // 槽主（所属记录）
    final int bid;                     // 对方 bid（槽内）
    final int hash31;                  // 对方 socket 的 31 位哈希（槽内快照）
    final Uint8List buffer;            // 所属记录的记录行 buffer（头部 + 槽区，槽引用）
    final int offset;                  // 槽偏移（80 + i×8）
    bool valid;                        // 槽内 valid 位（accept 后写回）

    bool match(Record record) =>
        owner.socket == record.socket || hash31 == record.hash31;

    bool accept(Record record) {
        if (!match(record)) return false;   // 非当事人，拒绝
        valid = true;
        buffer[offset + 7] |= 1;            // 置 value bit0（valid）；大端，value 末字节
        return true;
    }
}
```

接口实现（Record 上，外部经此访问 allowlist）：

```dart
PermitView? searchPermit(int bid) {
    // 槽区二分（槽 i @ 80 + i×8，按 bid 升序）
    // 命中 → 视图（owner/bid/hash31/valid）；未命中 → null
}

bool insertPermit(int bid, PermitView permit) {
    // 剩余空间 = 槽区长度 − cnt×8；< 8 → false
    // 二分定位插入点，memmove 后移
    // 写入 {bid, permit.hash31 | permit.valid}；cnt++
}

void removePermit(int bid) {
    // 二分定位，memmove 覆盖删除；cnt--；不存在幂等
}

List<int> clearPermits() {
    // 收集全部槽 bid → cnt = 0 → 返回列表
}

List<int> allowAll() {
    // 收集全部定向槽 bid → cnt = 0
    // 槽 0 写 {bid:1, value:固定值}，cnt = 1
    // 返回被清除的 bid 列表
}

bool isAllowAll() => cnt >= 1 && 槽 0 的 bid == 1;
```

**双向确认（跨侧置位）**——视图 accept 的唯一合法调用场景：

```dart
// B 后发 "ACPT" A（A 先 ACPT 过 B）：
// 1) B 侧建新槽（后发方新槽 valid=1）
B.record.insertPermit(X, view(B.record, X, A.record.hash31, valid: true));
// 2) A 侧已有槽 {bid:Y, hash31:B.record.hash31, valid:0} 跨侧置位
AView = A.record.searchPermit(Y);
AView.accept(A.record);   // 槽主 A 命中 → value |= 1 写回（或 accept(B.record)，哈希命中亦可）
```

> 视图 accept 只在**跨侧置位**时调用（此时双方均已确认）；单方 "ACPT"（A 先 ACPT B）流程只调 `insertPermit` 建槽（valid=0）、**不调 accept**——permit 未生效。若对单方槽误调 accept(槽主) 会单方生效，实现时须由服务器流程保证调用时机。

---

## 7. 密钥轮换

- **server_secret**：管理线程每 `server_secret_rotate_interval`（600s）轮换，保留最近 2 把用于 token 校验；
- **secret**：客户端密钥，record 生命周期内不变；由握手下发，用于所有消息的 HMAC 校验。

---

## 8. 应答限频（共享计数器）

对"连接未确认"的 "FAIL" 回复做全局限频：

- 每收到来源无记录的请求包，累加共享计数器；
- 按时间分桶（`unconfirmed_reply_buckets`，1024 桶）滑动窗口统计；
- 超过 `reply_rate_limit`（10/s）不再回复 "FAIL"，静默丢弃；
- 已绑定客户端的应答不限频。

---

## 9. 启动与配置

### 9.1 配置表（完整默认值）

| 配置项 | 默认值 | 说明 |
|--------|--------|------|
| host | 0.0.0.0 | 监听地址 |
| port | 9527 | 服务器 UDP 端口 |
| socket_buffer_length | 4194304 | 内核 socket UDP 接收缓冲（字节，4MB；内核可能截断到系统 rmem_max） |
| forwarders | 8 | 转发线程数量（W） |
| forward_limit_per_window | 4096 | 每窗口每线程最大转发任务数 |
| forward_window | 0.1 | 滑动窗口时长（秒） |
| waiting_queue_size | 4096 | 等待处理队列容量（任务数） |
| manager_queue_size | 1024 | 管理请求队列容量（任务数） |
| forwarder_queue_size | 65536 | 每条转发线程的队列容量（任务数；最坏约 64 MiB/线程，按满载荷 1KiB 计） |
| record_expires | 86400.0 | 记录过期时间（秒，24h） |
| record_recycle_interval | 600.0 | purge 最小调用间隔（秒，10 分钟；purge 只回收超 record_expires 的记录，全表扫描罕见且廉价） |
| record_active_timeout | 60.0 | 在线判定窗口 T_active（秒，1 分钟） |
| max_records | 65536 | 内存记录总数上限（比 IPv4 端口空间多 1，单台 IPv4 主机打不满；新建握手将创建记录时已达上限回 "FAIL"，仅内定流程豁免；已存在记录不受影响） |
| handshake_min_payload | 512 | 握手上行包最小载荷（防放大；"SYN!" 应答小于请求） |
| unconfirmed_reply_buckets | 1024 | 共享计数器分桶数（按 hash("ip:port") % U 定位） |
| reply_rate_limit | 10 | 未确认来源 "FAIL" 限频（次/秒/桶） |
| allowlist_max_entries | 256 | 通行证列表上限（条目数；槽区长度 = 值 × 8 字节，IPv4/IPv6 槽同格式；超限条目跳过、回显失败子集） |
| noop_immunity_window | 2.0 | "NOOP" 免疫窗口（秒；窗口内 "FIN?" 应答但不标记 offline） |
| server_secret_rotate_interval | 600.0 | 服务器密钥轮换周期（秒，保留最近 2 把） |
| app_secret_file | （空） | 应用密钥文件路径（示例：`# app_secret_file = /etc/magpie/private/enigma.json`） |
| app_secret_reload_interval | 600.0 | 应用密钥重读周期（秒） |
| handshake_token_timeout | 60.0 | 握手 token 超时（秒；正常握手毫秒级完成，仅防重放与陈旧握手包） |
| bid_allocation_retries | 16 | bid 随机分配冲突重试次数（视为服务器已满） |

**规则说明**：

1. 所有时间值均为**浮点数的秒**（如 0.1 秒），代码内部自行转换为毫秒等内部单位；
2. 容量类参数均为整数：waiting_queue_size、manager_queue_size、forwarder_queue_size 为任务数（任务即数据包与来源 socket 信息的封装），allowlist_max_entries 为条目数，max_records 为记录总数，socket_buffer_length 为字节数；
3. 所有键缺失、段缺失或文件缺失时均回退到代码默认值；
4. `--config` 指定的路径优先于默认路径 `/etc/magpie/config.ini`；配置文件不存在时不报错，直接使用全部默认值。

### 9.2 配置示例

```ini
[magpie-bridge]
host = 0.0.0.0
port = 9527

# UDP receive buffer size of the kernel socket (bytes, default: 4194304 = 4 MB)
socket_buffer_length = 4194304

# threads: forwarder thread count W (default: 8)
forwarders = 8
# forwarder rate limit: max packets processed per window (default: 4096)
forward_limit_per_window = 4096
# forwarder rate limit window (seconds, default: 0.1)
forward_window = 0.1

# record lifecycle
record_expires = 86400.0
record_recycle_interval = 600.0
record_active_timeout = 60.0
max_records = 65536

# security
handshake_min_payload = 512
unconfirmed_reply_buckets = 1024
reply_rate_limit = 10
allowlist_max_entries = 256
noop_immunity_window = 2.0
server_secret_rotate_interval = 600.0
handshake_token_timeout = 60.0
bid_allocation_retries = 16

# app secret (enigma); unset/empty/missing/unparsable/empty enigmas -> non-encrypted mode
# app_secret_file = /etc/magpie/private/enigma.json
app_secret_file =
app_secret_reload_interval = 600.0

# queues (tasks)
waiting_queue_size = 4096
manager_queue_size = 1024
forwarder_queue_size = 65536
```

### 9.3 启动参数与行为

命令行均为命名参数，全部可选：

```
magpie-bridge [--config=<FILE>] [--log-dir=/tmp]          (Python 版)
java -jar magpie-bridge.jar [--config=<FILE>] [--log-dir=/tmp]   (Java 版)
```

- `--config`：配置文件路径（缺省尝试默认路径 `/etc/magpie/config.ini`；两版均支持）；
- `--log-dir`：日志目录（默认为空，不写文件；两版均支持）；
- 未知参数会打印用法提示并退出；
- 启动顺序：读取配置 → 绑定 `port` 的 UDP socket → 启动接收/预处理/管理/转发线程 → 读取 `app_secret_file`（若配置）确定握手模式 → 进入运行循环（管理线程处理系统指令 + 周期 purge + 密钥重载）。

### 9.4 工程目录

- **Java 版服务器**：`magpie/server-java/`；
- **Python 版服务器**：`magpie/sdk-py/magpie_bridge/bridge/`（协议定义在 `protocol/`、工具类在 `magpie/`、服务器代码在 `bridge/`）；`pip install magpie-bridge` 后可通过 `magpie-bridge` 命令启动。
