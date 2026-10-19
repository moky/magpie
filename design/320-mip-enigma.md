# Magpie Improvement Proposal‌ 应用密钥

为了增加服务器对访问应用的管控能力，在安全提案的基础上，再增加一个应用密钥的设计。

## Secrets

与前面设计的**服务器密钥**`server_secret`、**客户端密钥**`secret`都不同，这个**应用密钥**`enigma`不是随机生成的，
而是预先指定，并存放在服务器的安全目录中，然后通过可靠渠道发放给应用：

- 服务器密钥（server_secret，默认 32 字节）由服务器随机数生成，仅保存在服务器内存中，10分钟内有效；
- 客户端密钥（client_secret，简称 secret，默认 32 字节）由服务器随机数生成，并在握手阶段发给客户端，双端均只保存在内存中，有效期与 bid record 生命周期相等；
- 应用密钥（app_secret，别名 enigma，任意长度），由系统管理员设定，并通过可靠渠道分发至服务器与客户端。

|               | 变量名  | 长度        | 用途                     |
|---------------|--------|------------|--------------------------|
| server_secret | -      | 默认 32 字节 | 握手阶段对 token 进行签名  |
| client_secret | secret | 默认 32 字节 | 对所有握手后的消息进行签名  |
| app_secret    | enigma | 任意长度     | 握手阶段对 secret 进行加密 |

应用密钥文件格式：

```json
{
    "enigmas": {
        "123456": "hex,1234567890ABCDEF",
        "ACCEDE": "hex,ACCEDE1234567890",
        "DECADE": "hex,DECADE1234567890",
        "FACADE": "hex,FACADE1234567890",
        "TW9reS": "base64,TW9reSBsb3ZlcyBNYXkgTGVlIGZvcmV2ZXIh"
    }
}
```

> 映射表的值即应用密钥 enigma，前缀 "hex,"/"base64," 标明编码格式，实际密钥为解码后的二进制数据（加密时作为 HKDF 的 ikm）。
> 键由客户端通过 "SYN?" 数组上报，服务器取交集后任选其一；为支持密钥轮换，旧密钥在过渡期内应保留在映射表中，客户端亦应同时上报新旧密钥。

### 第一次握手包 "SYN?" 升级（客户端）

客户端启动时，从本地读取应用密钥 enigmas 映射表（文件格式如上）。

开始握手前，先取出映射表中的所有 keys，放进 "SYN?" 的载荷中发给服务器。

新版 "SYN?" 载荷格式：

```json
{
    "enigmas": [
        "123456",
        "ACCEDE",
        "DECADE",
        "FACADE",
        "TW9reS"
    ],
    "time": 1234567890.123,
    
    "blahblah": "{填充长度 500 字节，确保总长度不少于 512 字节}"
}
```


### 第二次握手包 "SYN!" 升级（服务器）

服务器从配置项 `app_secret_file` 读取应用密钥文件路径；
配置项未设置、文件不存在、文件无法解析、或文件内 `enigmas` 映射表缺失/为空时，服务器按**非加密模式**运行；
否则（映射表非空）切换为**加密模式**，即握手过程强制升级为对 "secret" 进行加密。

运行期间由**管理线程**按配置项 `app_secret_reload_interval`（默认 600 秒，即 10 分钟）周期重读该文件：解析成功则整体替换内存映射表（密钥轮换/吊销据此生效，空表按上述规则切换为非加密模式）；重读失败或文件消失则保留旧表继续运行（不降级、不中断）。

> 加密模式下，"SYN!" 中的 secret 为密文，链路嗅探者无法获得明文——安全提案中"此机制可防止其他攻击者（有嗅探能力的除外）冒充"的"除外"限定不再成立。

在加密模式下，服务器对第一次握手包 "SYN?" 的处理过程如下：

- 服务器在第一次握手包 "SYN?" 中读取 "enigmas" 字段（字符串数组），如果不存在则静默丢弃；
- 将上面得到的数组，与从本地文件中读取到的映射表的 keys 取交集，如果交集为空则静默丢弃；
- 接下来按**原握手流程**获取 bid、客户端密钥 secret；
- 然后从前面得到的应用密钥交集中取出任意一个键值对（如 "123456" 和 "hex,1234567890ABCDEF"）；
- 然后用这个 enigma 值（加密密钥）对前面的 secret 进行加密（HKDF-SHA256 + AES-GCM）得到密文 ciphertext；
- 用密文 ciphertext 替代原来 "SYN!" 载荷中的 "secret" 字段，并按**原握手流程**计算握手令牌 token，其中参与计算的 secret 取该密文（与校验侧一致：始终取载荷中的 "secret" 字段值）；
- 最后附上 enigma 相关的解密信息一起返回给客户端；

新版 "SYN!" 载荷格式：

```json
{
    "enigma": {
        "key": "{enigma 键，通常是 6 字符}",
        "algorithm": "HKDF-SHA256+AES-256-GCM",
        "hkdf": {
            "salt": "{Base64 编码的 16 字节 salt，一次性 CSPRNG}",
            "info": "{Base64 编码的二进制串 b'enigma-v1:bid=' + bid}"
        },
        "nonce": "{Base64 编码的 12 字节 nonce，一次性 CSPRNG}",
        "tag": "{Base64 编码的 16 字节 tag}",
        "aad": ""
    },
    "secret": "{Base64 编码的加密后的 secret，即 ciphertext}",
    "token":  "{Base64 编码的 token}",
    "token_time": {服务器生成此 token 的时间戳，整数秒},
    
    "time": 1234567890.125,
    
    "UDP": "12.34.56.78:90"
}
```

### 第三次握手包 "ACK!" 升级（客户端）

如果收到服务器返回的第二次握手包中包含 "enigma" 字段，则客户端切换为**加密模式**。

在加密模式下，客户端对第二次握手包 "SYN!" 的处理过程如下：

- 读取载荷中的 "enigma" 字段，取出其中的 "key" 字符串（任意长度），并从 enigma 映射表中查找解密密钥，如果不存在则说明当前应用中的 enigmas 没有与服务器支持的匹配，报错退出；
- 从字段 "secret" 读取客户端密钥的密文，然后用 "enigma" 中的参数对其进行解密，得到真实的 secret；
- 保存 secret 进内存以供后续的消息包签名、验签使用，然后将收到的 enigma/secret/token/token_time 等原样放进第三次握手包 "ACK!" 发回给服务器。

新版 "ACK!" 载荷格式：

```json
{
    "enigma": {
        "key": "{enigma 键，通常是 6 字符}",
        "algorithm": "HKDF-SHA256+AES-256-GCM",
        "hkdf": {
            "salt": "{Base64 编码的 16 字节 salt，一次性 CSPRNG}",
            "info": "{Base64 编码的二进制串 b'enigma-v1:bid=' + bid}"
        },
        "nonce": "{Base64 编码的 12 字节 nonce，一次性 CSPRNG}",
        "tag": "{Base64 编码的 16 字节 tag}",
        "aad": ""
    },
    "secret": "{Base64 编码的加密后的 secret，即 ciphertext}",
    "token":  "{Base64 编码的 token}",
    "token_time": {服务器生成此 token 的时间戳，整数秒},
    
    "time": 1234567890.127,
    
    "blahblah": "{填充长度 256 字节，确保总长度不少于 512 字节}"
}
```

另外，由于此前握手阶段的 secret 是明文传送的（无排他性），"ACK!" 上的 attachment 校验码无法证明客户端持钥，只是多余的；
现在 secret 变成加密的了，嗅探者无法获得明文，所以加密模式下 "ACK!" **必须携带** attachment（复用 SDK 中 `ReliablePacket` 的附加校验码机制：HMAC-SHA256、32 字节，见安全提案），
让服务器可以判断客户端是否真的得到了 secret（防止攻击者恶意注册大量僵尸 bid record）。
此要求覆盖安全提案中 "ACK!" 不收附加校验码的例外：仅加密模式生效；基础模式 "ACK!" 仍不携带，"SYN?" 亦不携带（客户端此时尚无 secret）。

### 第三次握手包 "ACK!" 验证升级（服务器）

服务器收到 "ACK!" 包之后，如果当前为**加密模式**，则

- 先检查载荷中的 "enigma" 字段，字段不存在或者其中的 "key" 与本地应用密钥映射表无对应值则静默丢弃；
- 然后按**原握手流程**对 token 进行校验（用服务器密钥组重算比对，见架构文档），其中参与计算的 secret 取**载荷中的 "secret" 字段值**（加密模式下即密文，无需先解密）；校验失败则静默丢弃；
- 再用 "enigma" 中的信息对 "secret" 进行解密，如若解密失败（tag 校验不通过）视为无效握手，静默丢弃；
- 通过前面步骤得到客户端密钥 secret 明文后，再用来对 attachment 进行校验，校验失败则静默丢弃；
- 全部通过后创建/复用 bid record，记录中的 secret 使用解密得到的值。

> 重点：加密模式下放在 UDP 包中传输的 "secret" 永远是加密后的密文，而 "enigma" 中的 "key" 是用来查询应用密钥，结合 "enigma" 其他字段信息可以对 "secret" 进行解密得到真实的 secret。
> 不要在 "secret" 字段中放原来的客户端密钥，也不要在 "enigma" 中存放应用密钥本身。

### 相关算法

```python
# 加密算法
def encrypt(ikm: bytes, salt: bytes, info: bytes,
            plaintext: bytes, aad: bytes = b"") -> Tuple[bytes, bytes, bytes]:
    user_aes_key = hkdf_extract_expand(ikm=ikm, salt=salt, info=info, L=32, hash=sha256)
    nonce = crypto_csprng(12)
    cipher, tag = aes256_gcm_encrypt(key=user_aes_key, nonce=nonce, plain=plaintext, aad=aad)
    return nonce, cipher, tag

# 解密算法
def decrypt(ikm: bytes, salt: bytes, info: bytes,
            nonce: bytes, ciphertext: bytes, tag: bytes, aad: bytes = b"") -> bytes:
    user_aes_key = hkdf_extract_expand(ikm=ikm, salt=salt, info=info, L=32, hash=sha256)
    plain = aes256_gcm_decrypt(key=user_aes_key, nonce=nonce, cipher=ciphertext, aad=aad, tag=tag)
    return plain
```



