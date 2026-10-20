# Magpie Bridge Architecture （用户信息记录）

这里定义了服务器架构设计中需要用到的 bid record 和许可证 Permit 结构。

## 服务器（内存）记录分配表

Record 属性：

- bid       (**门牌号**)
- key       (**客户端索引** "{ip}:{port}")
- socket    (**客户端信息** ip, port；类型 SocketAddress，见附 2)
- secret    (**客户端密钥**)
- last_time (最后活跃时间)
- offline   (主动下线标志)
- allowlist (通行证列表)

注：

1. 其中 bid、key、socket 和 secret 均为**不变量**，记录一经创建永不改变（socket 与记录绑定后不可迁移至其他 socket，来源 socket 不匹配一律按冲突/伪造处理）；
2. 每次收到有效数据包时都需要更新 last_time；
3. 离线标志 offline 由 "FIN?" 设置（`noop_immunity_window` 内不设置，见安全提案），由 "ACK!" 幂等分支（重新握手走完第三次握手）或 "NOOP" 清除；offline == true 期间仅 "SYN?"/"ACK!"/"FIN?"/"NOOP" 放行，其余指令（含 "PING"、数据包）一律静默丢弃，不更新 last_time；
4. 通行证列表 allowlist 由 ACPT/DENY 指令维护，通过"通行证"小节的封装接口访问（不得直接读写字段）；条目上限为 `allowlist_max_entries`（默认 256 个，具体实现见服务器文档）。
5. 内存记录总数设有上限 `max_records`（默认 65536，见服务器文档配置表）：新建 bid record 时若已达上限则回复 "FAIL" 指令包、不创建记录（"SYN?" 分配阶段提前检查、"ACK!" 创建前兜底检查；仅 loopback 内定流程豁免）；已存在的记录不受影响（复用/重握手正常）。


### 通行证

Record 对通行证提供以下封装接口，外部一律通过接口访问（不得直接读写 allowlist 字段）：

- `searchPermit(bid, addressFamily?)`：按 bid 查找通行证，未命中返回 null；传入对方地址族时只查对应段（调用方持有对方 record 时即可提供，见"通行权检查"），未传则两段都查；
- `insertPermit(bid, permit)`：写入一条通行证，空间不足返回 null（见"添加通行证"）；
- `removePermit(bid, addressFamily?)`：删除一条通行证，不存在时幂等返回；地址族传参与 `searchPermit` 相同（未传则两段都查）；
- `clearPermits()`：清空全部通行证，返回被清除的 bid 列表（见"清空通行证"）；
- `allowAll()`：进入通配授权状态（清空现有全部定向通行证并建立通配通行证），返回被清除的 bid 列表（见"通配授权"）；
- `isAllowAll()`：是否处于通配授权状态。

槽化实现下（见服务器文档），通行证槽按**对方 socket 的地址族**分存两段（IPv4 段/ IPv6 段）。`searchPermit`/`removePermit` 传入对方地址族则只查对应段，未传则两段都查：

- 通行权检查与添加流程均先经分配表取得对方 record（添加流程对不存在的 bid 按状态类错误跳过），对方 socket 地址族已知，可只查对应段；
- "DENY" 时目标记录可能不存在（幂等视为删除成功），地址族未知，须两段都查；
- 传地址族还消除跨段歧义：原持有者以 IPv4 留下残留槽、新持有者换 IPv6 抢注同一 bid 时，两段可能并存同 bid 槽——只查当前持有者地址族对应段不会命中陈旧槽（残留仍由双 socket 匹配兜底拒绝）。

当客户端 A 准备 ACPT 多个 bid 时，先逐个查询 bid record 分配表，按错误类型分类处理：

- **格式类错误**（bid 为负数、0、或等于发起方自身 bid）——客户端编码错误，整体拒绝（不处理任何 bid），回复 "FAIL" 并丢弃此指令退出；
- **状态类错误**（bid 记录不存在、allowlist 空间不足）——逐条跳过，仅该条不执行，继续处理其余 bid，最后在应答中回显失败子集。

对通过的 bid 逐个执行以下**添加流程**：先修改 Permit（B 侧共享引用立即生效），再经 insertPermit 检查空间并写入 A 侧（空间不足返回 null，见下）。全部处理完后：

- 存在失败条目 → 回复 "FAIL"，载荷 sources 回显**未成功的 bid 子集**（部分成功时不另发 "DONE"——成功条目由客户端以请求列表减去失败子集得知，或直接忽略、仅重试失败子集）；
- 全部成功 → 回复 "DONE"，载荷 sources 回显**实际写入的 bid 列表**。

> 将"修改 Permit"放在"写入 A 侧 allowlist"之前，是有意为之：
> Permit 的 accept 修改的是双方共享的对象（B 侧引用立即生效）；
> 若 A 被攻击（allowlist 已满），写入 A 侧会失败，但 B 侧 permit 已生效，
> 只要 B 侧存在共享 permit（B 曾 ACPT 过 A），A 仍可通过 B 侧的有效通行证与 B 正常通讯；
> 空间不足时该条跳过（A 侧不写入），但 B 侧已生效的修改保留——客户端收到 "FAIL" 后仅需对失败子集重试（幂等）。

#### 添加通行证

当客户端 A 需要为 B 添加通行证时，
假设他们的 bid 分别是 X 和 Y，即 A 的记录为 X.record； B 的记录为 Y.record：

```dart
    // 先在 A 的记录中查找属于 B 的通行证
    var permit = X.record.searchPermit(Y);
    if (permit != null && permit.match(Y.record)) {
        // 通行证已存在且目标未变（此通行证必含对 B 的授权）
        // 无需更新，直接返回
        return permit;
    } else {
        // 本地通行证不存在或已陈旧（目标 bid 换持有者/持有者换网）
        // 清理陈旧条目后按下方流程处理
        X.record.removePermit(Y);
    }
    // 本地通行证不存在，则在 B 的记录中查找属于 A 的通行证
    permit = Y.record.searchPermit(X);
    if (permit == null) {
        // 如果仍然不存在（正常情况下是因为 A 先发起 ACPT）
        // 则新建一个属于 B 的通行证（含对 B 授权）
        permit = Permit(Y.record);
    } else if (permit.match(X.record)) {
        // 如果存在（通常是因为 B 先发起 ACPT，此时已含对 A 的授权）
        // 则添加对 B 的授权
        permit.accept(Y.record);
        // （注意：此时 B 侧共享引用立即生效）
    } else {
        // 陈旧通行证（发起方 bid 换持有者 / 持有者换网）
        // 清理后重建
        Y.record.removePermit(X);
        permit = Permit(Y.record);
    }
    // 空间足够时写入 A 的记录表（空间不足由 insertPermit 返回 null 表示失败）
    if (X.record.insertPermit(Y, permit) == null) {
        // A 的记录表空间不足，无法写入
        return null;
    }
    // 写入成功，返回此通行证
    return permit;
```

一个通行证应该包含双方 socket 信息。
当双方均确认后，通行证即生效，所以 valid 状态只需要判断 t != null 即可。

#### 删除通行证

服务器收到 "DENY" 指令时，先判断载荷是否为清空标记（见下），命中则走清空流程；
否则进入删除流程，先检查 bid 合法性：

- 必须符合 bid 取值范围规定（0 <= bid <= 4294967295），不能是负数（负数仅出现在“清空通行证”）；
- 不能为 0（服务器保留），不能等于发送者自身的 bid（不能添加自身自然也不需要删除自身）；

如果不符合上述规定（格式类错误），则返回 "FAIL" 并带上**格式非法的 bid 子集**通知发送者（整体拒绝，不处理任何 bid）；
否则逐个在客户端 A（bid=X）的记录中删除映射即可：

```dart
    X.record.removePermit(Y);
```

如果 B 的记录不存在，也当作删除成功（幂等）。

全部处理完（无格式类错误）后回复 "DONE"，载荷 sources 回显**实际删除的 bid 列表**（见载荷格式规范）。

通行证为双向同意关系：单方 "DENY" 仅在发起方记录中删除映射，
对方记录中的有效通行证仍在，通信不受影响（防伪造删除，见安全提案）；
彻底解除需双方均 "DENY"；单方拒收（拉黑）由应用层处理。
一方记录被回收后，引用其 bid 的通行证条目由 purge 一并清理（含对方记录中的残留条目），服务器因取不到目标记录不再转发，关系彻底失效。

#### 清空通行证（"DENY *"）

出于状态重置的目的（应用重新运行后丢失原通行证信息、或列表被恶意填充打满时，
应用无法得知现有条目，只能整体清空后重建），这里设计了一个特殊的 DENY 指令：

```json
{
    "sources": [-1, -2, -3],
    "time": 1234567890
}
```

当服务器收到 DENY 指令时，先判断 sources 长度，如果刚好为 3 且内部元素依次为 -1, -2, -3（严格按序，客户端必须按此顺序编码），
则执行 ```sources = X.record.clearPermits()``` 清空列表（返回被清除的 bid 列表，见通行证访问接口）。

> 选用三个有序负值是为防止客户端误操作：单个负值（如 -1）常作为哨兵/错误码出现，空列表更易因未填充误触发；
> 实现时不得简化为单值或乱序匹配。

应答指令 "DONE" 时把 sources 返回给客户端。

#### 通配授权（"ACPT *"）

与清空通行证对称，这里为 "ACPT" 设计了一个特殊的通配标记，用于"允许所有"（适用于对所有人开放服务的 bot 等场景）：

```json
{
    "sources": [-1, -2, -3],
    "time": 1234567890
}
```

服务器收到 "ACPT" 指令时，先判断 sources 长度，如果刚好为 3 且内部元素依次为 -1, -2, -3（严格按序，客户端必须按此顺序编码），命中则走通配流程，否则才进入添加流程（先做 bid 合法性检查）：

- 通配授权为**原子操作**：执行 ```X.record.allowAll()```（清空现有全部定向通行证并建立**通配通行证**，对任意 bid 有效、match 恒真），应答 "DONE" 并回显**被清除的定向 bid 列表**（客户端据此得知状态已重置）；
- 通配生效期间，定向 "ACPT"/"DENY" 一律回复 "FAIL"（通配已覆盖一切，定向操作无意义；客户端须先 "DENY *" 退出通配）；
- 清空通行证（"DENY *"）会连同通配通行证一并清除，记录回到默认拒绝状态。

> 选用三个负值是为防止客户端误操作（与清空通行证一致，见上）；通配通行证随记录回收/重启一并失效，无需单独处理。

#### 通行权检查

通行证一旦双方都确认之后就生效，如果只有一方发 DENY 另一方不发，
也只是删除 X.record 中对应 Y 的条目，而 Y.record 中对应 X 的条目仍然存在，

所以服务器在检查 A 是否有权给 B 发送消息时，会先后在双方的 allowlist 中查找通行证，
任何一边查到有效的通行证均会放行（防止一方被攻击者强行删掉通行证的情况，见安全提案）；
命中后还需校验来源与目标双方的 socket 均与本通行证匹配（Permit.match，双方均须为本通行证当事人；bid 回收重分配产生的残留条目因目标不匹配而拒绝）。
若任一侧 allowlist 中存在**通配通行证**（见"通配授权"），视为命中并直接放行——通配通行证对任意 bid 有效（match 恒真），无需校验 socket。

```dart
    permit = X.record.searchPermit(Y);
    permit ??= Y.record.searchPermit(X);
    ok = permit != null && permit.valid && permit.match(X.record) && permit.match(Y.record);
    ok ||= X.record.isAllowAll();
    ok ||= Y.record.isAllowAll();
```

#### 附 1： Permit

通行证的第二个 socket 信息只有赋值操作，没有清空操作，
所以只要双方确认过即生效，直到双方都已删除为止。

```dart
class Permit {
    Permit(Record record) : _s = record.socket;
    
    final SocketAddress _s;
    SocketAddress? _t;
    
    bool get valid => _t != null;
    
    bool match(Record record) => _s == record.socket || _t == record.socket;
    
    bool accept(Record record) {
        if (_s == record.socket) {
            return true;         // 创建方确认（幂等，不改变生效状态）
        } else if (_t == null) {
            _t = record.socket;  // 首次接纳对方：记录对方 socket，生效
            return true;
        }
        return _t == record.socket;   // 已有接纳方：仅其本人再次确认，第三方拒绝
    }
}
```

> 概念层共享对象模型；实现层槽化后（见 220 服务器设计的"内存优化建议"）"首次接纳/确认"由跨侧置位完成，_t 对应槽内快照、valid 对应槽内 valid 位——概念层 accept 承担引入接纳方的职责，与实现层视图 accept（match 命中即置位）语义不同，不可混用。

#### 附 2： SocketAddress

```dart
abstract class SocketAddress {
    
    static SocketAddress create(String host, int port) {
        if (port < 0 || port > 65535) {
            throw ArgumentError('port must between 0 and 65535');
        }
        return InetSocketAddress(InternetAddress(host), port);
    }
    
    /// parse "127.0.0.1:8080" or "[::1]:8080"
    /// return null if format invalid
    static SocketAddress? parse(String address) {
        InternetAddress inet;
        int port = -1;
        try {
            String host;
            String pStr;
            if (address.startsWith('[')) {
                // IPv6 [::1]:port
                final pos = address.indexOf(']:');
                if (pos < 0) {
                    return null;
                }
                host = address.substring(1, pos);
                pStr = address.substring(pos + 2);
            } else {
                // IPv4 host:port
                final parts = address.split(':');
                if (parts.length != 2) {
                    return null;
                }
                host = parts[0];
                pStr = parts[1];
            }
            inet = InternetAddress(host);
            port = int.parse(pStr);
        } on FormatException {
            return null;
        } on ArgumentError {
            return null;
        }
        if (port < 0 || port > 65535) {
            return null;
        }
        return InetSocketAddress(inet, port);
    }
}

final class InetSocketAddress implements SocketAddress {
    InetSocketAddress(this._address, this._port) {
        assert(0 <= _port && _port < 65536, 'port must between 0 and 65535');
    }
    
    final InternetAddress _address;
    final int _port;
    
    String get host => _address.address;
    int get port => _port;
    
    @override
    bool operator ==(Object other) {
        if (identical(this, other)) {
            return true;
        }
        return other is InetSocketAddress &&
               other._port == _port &&
               other._address == _address;
    }
    
    @override
    int get hashCode => Object.hash(_address, _port);
    
    @override
    String toString() {
        /// Serialized string, IPv6 will wrap with []
        if (_address.type == InternetAddressType.IPv6) {
            return '[$host]:$port';
        }
        return '$host:$port';
    }
}
```
