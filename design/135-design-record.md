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
3. 离线标志 offline 为客户端主动发送 "FIN?" 的标志；仅由 "ACK!" 幂等分支（重新握手走完第三次握手）或 "NOOP" 清除；"PING" 及数据包转发只更新 last_time，不改变 offline 标志；
4. 通行证列表 allowlist 具体实现时建议采用以 bid 为索引的映射表： Map<int, Permit>，由 ACPT/DENY 指令维护；条目上限为 `allowlist_max_entries`（默认 1000 个）。


### 通行证

当客户端 A 准备 ACPT 多个 bid 时，先逐个查询 bid record 分配表，
任意一个记录不存在即拒绝添加，回复 "FAIL" 并丢弃此指令_退出_（列表中包含发起方自身 bid 亦视为无效，整体拒绝）；
若 A.record.allowlist 条目数已达上限，同样整体拒绝并回复 "FAIL"（口径见安全提案）；
当所有记录都找到之后，再逐个执行以下**添加流程**，完成后回复 "DONE" 通知客户端：

#### 添加通行证

当客户端 A 需要为 B 添加通行证时，
假设他们的 bid 分别是 X 和 Y，即 A 的记录为 X.record； B 的记录为 Y.record：

```dart
    // 先在 A 的记录中查找属于 B 的通行证
    var permit = X.record.allowlist[Y];
    if (permit == null) {
        // 如果通行证不存在，则在 B 的记录中查找属于 A 的通行证
        permit = Y.record.allowlist[X];
        if (permit == null) {
            // 如果仍然不存在，则新建一个属于 B 的通行证
            permit = Permit(Y.record);
        } else {
            // 如果存在，则绑定 B 的信息
            permit.accept(Y.record);
        }
        // 然后添加到 A 的记录中
        X.record.allowlist[Y] = permit;
    }
    // 成功，返回此通行证
```

一个通行证应该包含双方 socket 信息。
当双方均确认后，通行证即生效，所以 valid 状态只需要判断 t != null 即可。

#### 删除通行证

服务器收到 "DENY" 指令时，先判断载荷是否为清空标记（见下），命中则走清空流程；
否则进入删除流程，先检查 bid 合法性：

- 必须符合 bid 取值范围规定（0 <= bid <= 4294967295），不能是负数（负数仅出现在“清空通行证”）；
- 不能为 0（服务器保留），不能等于发送者自身的 bid（不能添加自身自然也不需要删除自身）；

如果不符合上述规定，则返回 "FAIL" 并带上原 "sources" 信息通知发送着；
否则逐个在客户端 A（bid=X）的记录中删除映射即可：

```dart
    X.record.allowlist.remove(Y);
```

如果 B 的记录不存在，也当作删除成功（幂等）。

通行证为双向同意关系：单方 "DENY" 仅在发起方记录中删除映射，
对方记录中的有效通行证仍在，通信不受影响（防伪造删除，见安全提案）；
彻底解除需双方均 "DENY"；单方拒收（拉黑）由应用层处理。
一方记录被回收后（Permit 自然也随其记录消失），服务器因取不到目标记录不再转发，关系自然失效。

#### 清空通行证

出于状态重置的目的（应用重新运行后丢失原通行证信息、或列表被恶意填充打满时，
应用无法得知现有条目，只能整体清空后重建），这里设计了一个特殊的 DENY 指令：

```json
{
    "sources": [-1, -2, -3],
    "time": 1234567890
}
```

当服务器收到 DENY 指令时，先判断 sources 长度，如果刚好为 3 且内部元素依次为 -1, -2, -3（严格按序，客户端必须按此顺序编码），
则执行 ```X.record.allowlist.clear()``` 操作以清空列表。

> 选用三个有序负值是为防止客户端误操作：单个负值（如 -1）常作为哨兵/错误码出现，空列表更易因未填充误触发；
> 实现时不得简化为单值或乱序匹配。

清空之前先取出 bid list：```sources = X.record.allowlist.keys.toList()```
然后在应答指令 "DONE" 中返回给客户端。

#### 通行权检查

通行证一旦双方都确认之后就生效，如果只有一方发 DENY 另一方不发，
也只是在 X.record.allowlist 中删除，而 Y.record.allowlist 中仍然存在，

所以服务器在检查 A 是否有权给 B 发送消息时，会先后在双方的 allowlist 中查找通行证，
任何一边查到有效的通行证均会放行（防止一方被攻击者强行删掉通行证的情况，见安全提案）；
命中后还需校验来源 socket 与本通行证匹配（Permit.match，防止 bid 回收重分配后误放行）。

```dart
    permit = X.record.allowlist[Y];
    permit ??= Y.record.allowlist[X];
    ok = permit != null && permit.valid && permit.match(X.record);
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
            return true;
        } else if (_t == null) {
            _t = record.socket;
            return true;
        }
        return _t == record.socket;
    }
}
```

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
