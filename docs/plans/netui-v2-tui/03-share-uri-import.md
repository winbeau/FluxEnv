# 03｜分享 URI 导入与 sing-box JSON 生成

## 1. 范围

首版必须支持以下结构，而不是把用户给出的真实链接写进仓库：

1. VLESS + TCP + REALITY + `xtls-rprx-vision`。
2. VLESS + WebSocket + TLS。
3. Hysteria2，支持 `hysteria2` 和 `hy2` scheme。

用户提供的三条真实链接只用于定义兼容目标：

- 不复制到计划正文；
- 不进入 tests、commit、日志、终端 transcript 或 Release；
- 实施完成后只在用户本机做一次手工粘贴验收；
- 自动化使用全合成 UUID、密码、公钥、域名和 IP。

## 2. 模块边界

新增：

```text
packages/netui/lib/share_uri.sh
```

建议公共接口：

```text
share_uri_parse <uri>
share_uri_preview_json
share_uri_generate_config <output-path>
share_uri_import <uri> [requested-name]
share_uri_last_import_path
share_uri_last_error_code
```

原始 URI 仅存在于调用栈内的未导出 shell 变量中，不进入 argv、文件、日志或环境。

## 3. 输入约束

- 最大 16 KiB。
- 必须是一条单行 URI。
- 去掉外层首尾空格后，内部 CR/LF 仍拒绝。
- Bash 无法持有 NUL；解析器仍显式拒绝 `%00`。
- scheme 大小写不敏感；其余字段保持原始大小写。
- query 最多 64 项。
- 单个 key 最多 64 bytes。
- label 最多 128 bytes。
- host/SNI 最多 253 bytes。
- path 最多 2048 bytes。
- credentials 最大 1024 bytes。
- 不进行 DNS 查询。

禁止：

- `eval`、`source`；
- 用用户数据拼 `bash -c`；
- 把用户数据作为 `printf` format；
- unquoted expansion；
- 把 URI 传给后台进程 argv；
- `set -x`。

## 4. 安全 percent decode

必须按组件分别解码：

- userinfo；
- host/authority 的允许部分；
- query key；
- query value；
- path；
- fragment。

不能先解码整条 URI再切分，否则编码后的 `&`、`=`、`?`、`#`、`@`、`/` 会改变结构。

算法：

1. 逐字节扫描。
2. 普通字符原样追加。
3. 遇到 `%` 必须有两个十六进制字符。
4. 转成固定 `%b` 格式下的 octal byte。
5. 拒绝 NUL 和不允许的控制字符。
6. 原始 `+` 保持为加号；空格只从 `%20` 解码。

## 5. URI 结构解析

顺序：

1. 在第一个未编码 `#` 处分离 fragment。
2. 在第一个未编码 `?` 处分离 query。
3. 验证 `scheme://`。
4. 解析 authority：`userinfo@host:port`。
5. 支持 `[IPv6]:port`。
6. query 按 `&` 切项，每项只按第一个 `=` 切 key/value。
7. key ASCII lower-case；重复 singleton key 直接拒绝。
8. 未支持且非空的参数默认拒绝，不能悄悄丢弃影响连接的字段。

错误消息只包含字段名，不回显字段值：

```text
invalid UUID
missing REALITY public key
unsupported VLESS parameter: grpc
invalid Hysteria2 port
```

## 6. 通用地址校验

- port 是十进制 `1..65535`。
- host 必须是 hostname、IPv4 或 bracketed IPv6。
- host 不得含空白、控制字符、`/ ? # @`。
- hostname label 和总长受限。
- UUID 要求 canonical `8-4-4-4-12` hex。
- 布尔参数只接受 `0/1/true/false`。
- 不接受 port range、逗号列表或 service name。
- 不接受重复凭据字段。

## 7. VLESS REALITY/TCP/Vision

### 必需/支持字段

| URI 字段 | 规则 | sing-box 字段 |
|---|---|---|
| userinfo | canonical UUID | `.outbounds[].uuid` |
| host | 必需 | `.server` |
| port | 1..65535 | `.server_port` |
| `encryption` | 缺省或 `none` | 不写/验证 |
| `flow` | 必须 `xtls-rprx-vision` | `.flow` |
| `security` | 必须 `reality` | `.tls.reality.enabled=true` |
| `sni` | 必需 | `.tls.server_name` |
| `fp` | allowlist，首版至少 `chrome` | `.tls.utls.fingerprint` |
| `pbk` | 必需，base64url shape | `.tls.reality.public_key` |
| `sid` | 可选；偶数长度 hex，最多 16 chars | `.tls.reality.short_id` |
| `type` | 必须 `tcp` | 不写 transport 或写标准 TCP 语义 |
| `headerType` | 仅允许 `none` | no-op |

冲突字段（如 ws path/host、`security=tls`）直接拒绝。

目标 outbound：

```json
{
  "type": "vless",
  "tag": "proxy",
  "server": "192.0.2.10",
  "server_port": 443,
  "uuid": "00000000-0000-4000-8000-000000000001",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "reality.example.invalid",
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    },
    "reality": {
      "enabled": true,
      "public_key": "<synthetic-public-key>",
      "short_id": "0123456789abcdef"
    }
  }
}
```

实施时用 `jq -n` 构造，示例不是字符串插值模板。

## 8. VLESS WebSocket/TLS

### 必需/支持字段

| URI 字段 | 规则 | sing-box 字段 |
|---|---|---|
| userinfo | canonical UUID | `.uuid` |
| host/port | 必需 | `.server/.server_port` |
| `encryption` | 缺省或 `none` | 不写/验证 |
| `security` | 必须 `tls` | `.tls.enabled=true` |
| `sni` | hostname；server 为 IP 时必需 | `.tls.server_name` |
| `alpn` | percent decode；首版支持单值/逗号列表 | `.tls.alpn[]` |
| `fp` | allowlist，首版至少 `chrome` | `.tls.utls` |
| `type` | 必须 `ws` | `.transport.type="ws"` |
| `host` | 可选 Host header | `.transport.headers.Host` |
| `path` | 缺省 `/`；必须以 `/` 开头 | `.transport.path` |

REALITY、Vision flow、gRPC、HTTPUpgrade、early-data 等未实现组合拒绝。

目标 outbound：

```json
{
  "type": "vless",
  "tag": "proxy",
  "server": "ws.example.invalid",
  "server_port": 443,
  "uuid": "00000000-0000-4000-8000-000000000002",
  "tls": {
    "enabled": true,
    "server_name": "proxy.example.invalid",
    "alpn": ["http/1.1"],
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  },
  "transport": {
    "type": "ws",
    "path": "/sample",
    "headers": {
      "Host": "proxy.example.invalid"
    }
  }
}
```

## 9. Hysteria2

接受：

```text
hysteria2 scheme
hy2 alias
```

### 字段

| URI 字段 | 规则 | sing-box 字段 |
|---|---|---|
| userinfo | 作为 password；非空 | `.password` |
| host/port | 必需 | `.server/.server_port` |
| `sni` | server 为 IP 时必需 | `.tls.server_name` |
| `insecure` / `allowInsecure` | strict bool | `.tls.insecure` |
| `obfs=salamander` | 可选 | `.obfs.type` |
| `obfs-password` | obfs 开启时必需 | `.obfs.password` |

用户要求的 `insecure=1` 必须可解析并生成：

```json
"tls": {
  "enabled": true,
  "server_name": "hy.example.invalid",
  "insecure": true
}
```

但导入预览必须显示：

```text
Warning: certificate verification is disabled by this link.
```

用户 Enter 确认后才写入；Esc 取消。

首版不支持：

- 端口跳跃/range；
- 多端口；
- 未知 obfs；
- bandwidth hint；
- pinSHA256 等额外厂商参数。

## 10. 完整生成配置

统一 skeleton：

```json
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "mixed",
      "tag": "mixed-in",
      "listen": "127.0.0.1",
      "listen_port": 10808
    }
  ],
  "outbounds": [
    { "type": "<generated proxy>", "tag": "proxy" },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "final": "proxy"
  }
}
```

原则：

- 只监听 loopback；
- 不自动添加 TUN；
- 不自动添加 RFC1918/direct 规则；
- 不猜 DNS 策略；
- 不读取现有配置作为协议模板；
- 本地端口默认优先 10808；若 10808 由经过验证的当前 NetUI 实例占用，可继续选择 10808，因为切换配置前旧实例会停止；
- 若 10808 被无关进程占用，导入预览从 10809–10999 选择第一个当前空闲端口并明确展示；
- 端口选择只是用户体验预检，启动时仍由现有 runtime 重新做冲突检查，避免 race；
- 已有普通 JSON 不因导入器的端口策略被改写。

该 skeleton 的三类合成映射已用本地 sing-box 1.13.18 做过规划阶段 schema smoke，均通过 `sing-box check`；实现后仍需以最终代码重新验证。

## 11. 名称生成

fragment 只作为建议名称：

1. percent decode；
2. 去控制字符和首尾空白；
3. `/`、`\`、路径符号变为 `-`；
4. 连续空格/横线折叠；
5. 不把 UUID/key/password 放进名称；
6. 最多 96 bytes；
7. 添加 `.json`。

无 label fallback：

```text
vless-reality.json
vless-ws.json
hysteria2.json
```

冲突：

```text
name.json
name-2.json
name-3.json
```

冲突分配和最终创建必须在同一个 lifecycle lock 内完成。

## 12. 原子导入

流程：

1. 解析和语义校验 URI。
2. 选择/预览本地 loopback port。
3. 进入预览；用户确认。
4. 进入 `IMPORT_COMMITTING`，获取 NetUI lock。
5. 确定无冲突 basename。
6. 在 `NETUI_CONFIG_DIR` 创建 mode `600` 临时文件。
7. `jq -n` 直接写生成 JSON；不写原始 URI。
8. `jq empty`。
9. `sing-box check -c`。
10. 在最终 rename 前检查 cancel flag；若用户已按 Esc，删除临时文件并返回 MAIN。
11. `mv -nT` 原子提交；rename 成功后提交完成，不再响应“撤销提交”的 Esc，避免半状态。
12. 重新读取并用 `config_meta` 生成脱敏摘要。
13. 释放 lock。
14. 列表刷新并选中新配置。

取消边界：

- `IMPORT_INPUT` 和 `IMPORT_PREVIEW` 随时可 Esc；
- validation/check 可放在可轮询 worker 中，Esc 设置 cancel flag 并终止自有 check worker；
- final `mv -nT` 是不可分割 commit 点；commit 后 Esc 只关闭成功提示，不删除已成功配置。

失败/信号：

- 删除临时文件；
- 不创建目标文件；
- 不改变 default；
- 不改变运行实例；
- 错误信息不得含 URI 或凭据。

## 13. 日志与脱敏

禁止记录：

- 完整 URI；
- UUID；
- Hysteria2 password；
- Reality public/private key；
- short ID；
- obfs password；
- Authorization/Cookie/token。

允许的审计事件：

```text
import succeeded: basename=<safe-name> protocol=vless/ws/tls
import rejected: code=missing-reality-public-key
import cancelled
```

服务端地址只显示于当前本机表格/preview，不写公共测试 transcript。

## 14. 测试

- 三类有效合成 URI。
- `hy2` alias。
- WS 的 percent-encoded path、ALPN 和 Host。
- REALITY `headerType` 大小写 key 归一化。
- Hysteria2 `insecure=1` warning/confirm。
- malformed `%`、`%00`、encoded CR/LF。
- duplicate query key。
- unknown query key。
- shell metacharacters、命令替换文本、引号、反斜杠。
- IPv4、hostname、bracketed IPv6。
- port 0、65536、range。
- collision suffix。
- symlink/FIFO/dir collision。
- check 失败不留临时文件。
- raw URI 不出现在 stdout、stderr、日志、state、argv、environment。
- 协议从生成 JSON 识别，不从建议名称识别。
- 10808 被无关进程占用时选择并预览备用端口。
- Esc during parse/preview/check；final rename 后不产生半文件。
