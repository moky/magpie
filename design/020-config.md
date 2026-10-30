# Magpie Bridge Configuration

项目根目录：
    magpie/

## 设计文档

文档目录：
    magpie/docs/

## SDK

SDK 包括 Java、Python、Dart 等多个语言版本。

### Java SDK

依赖版本：
> Java 8

工程根目录：
    magpie/sdk-java/

工程配置参数：

    name = 'Magpie'
    group = 'io.github.moky'

### Dart SDK

依赖版本：
> sdk: '>=3.0.0 <4.0.0'

工程根目录：
    magpie/sdk-dart/

工程配置参数：

    name: magpie-bridge

### Python SDK

依赖版本：
> Python: >= 3.6

工程根目录：
    magpie/sdk-py/

代码目录：

    magpie/sdk-py/magpie_bridge/protocol/
    magpie/sdk-py/magpie_bridge/magpie/

> 协议定义放在 protocol/ 目录下，
> 工具类代码放在 magpie/ 下，
> 服务器代码放在 bridge/ 下。

工程配置参数：

    name='magpie-bridge'

## 服务器

> 其中 Python 服务器与 Python SDK 共用一个库 'magpie-bridge'。

### Java 服务器

工程根目录：
    magpie/server-java/

#### 启动参数

```
java -jar magpie-bridge.jar [--host=<ADDR>] [--port=<NUM>] [--config=<FILE>] [--log-dir=<DIR>]
```

（参数含义见下文）

### Python 服务器

服务器代码：
    magpie/sdk-py/magpie_bridge/bridge/

工程配置参数：

```
    'console_scripts': [
        'magpie-bridge=magpie_bridge.bridge.run:main'
    ]
```

> pip install magpie-bridge

执行此命令安装之后，即可通过命令 ```magpie-bridge [参数]``` 启动服务器。

#### 启动参数

命令行均为命名参数，全部可选：

```
magpie-bridge [--host=<ADDR>] [--port=<NUM>] [--config=<FILE>] [--log-dir=<DIR>]
```

- --host       监听地址（缺省用配置文件 host，默认 0.0.0.0；两版均支持）
- --port       UDP 监听端口（缺省用配置文件 port，默认 9527；两版均支持）
- --config     配置文件路径（缺省尝试默认路径，见下；两版均支持）
- --log-dir    日志目录（默认为空，不写文件；两版均支持）

未知参数会打印用法提示并退出。

## 配置文件

默认路径：
    /etc/magpie/config.ini

> 未通过 --config 指定时尝试读取默认路径；文件不存在、段或键缺失时，一律回退到代码默认值。

### 默认配置

```
# -*- coding: utf-8 -*-
#
#   Configuration for Magpie Bridge
#

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
# max in-memory bid records: new handshakes that would create a
# record are rejected with FAIL once the count reaches this limit;
# existing records are unaffected (default: 65536; one more than the
# IPv4 port space 0..65535, so a single IPv4 host cannot fill it)
max_records = 65536
# handshake flood guard: minimum payload length of the handshake
# packets "SYN?" and "ACK!" (bytes, default: 512; keeps the "SYN!"
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
# allowlist; an "ACPT" that would exceed this limit has the overflowing
# entries skipped (the rest still apply) and is answered with "FAIL"
# carrying the failed bid subset, bounding the memory a forged ACPT
# flood can occupy (entries, default: 256; the allowlist slot area
# length is derived as this value * 8 bytes, IPv4/IPv6 slots share
# the same 8-byte format, see the memory optimization section)
allowlist_max_entries = 256
# NOOP immunity window: after a "NOOP" that cancels a forged "FIN!" the
# record's last_noop_time is refreshed; a later "FIN?" within this
# window is answered with "FIN!" but does not mark offline, so a forged
# "FIN?" flood cannot keep the victim offline (seconds, default: 2.0)
noop_immunity_window = 2.0
# server secret rotation: a new server secret is generated and becomes
# the newest when it has been longer than this since the last rotation;
# at most the latest 2 secrets are kept for token verification
# (seconds, default: 600.0 = 10 minutes)
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
# this is silently dropped (no reply, no record) (seconds, default:
# 60.0; a normal handshake completes in milliseconds, this only
# guards against replay and stale handshake packets)
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
2. 容量类参数均为整数：waiting_queue_size、manager_queue_size、forwarder_queue_size 为任务数（任务即数据包与来源 socket 信息的封装，见架构文档），allowlist_max_entries、max_records 为条目数，socket_buffer_length 为字节数；
3. 所有键缺失、段缺失或文件缺失时均回退到代码默认值（host 默认 0.0.0.0、port 默认 9527、forwarders 默认 8，与其余键行为一致）；
4. 命令行 --config 指定的路径优先于默认路径；--host/--port 指定时覆盖配置文件中的同名键（优先级：命令行 > 配置文件 > 代码默认值）；配置文件不存在时不报错，直接使用全部默认值。
