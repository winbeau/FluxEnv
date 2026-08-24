# 05｜延迟与 MB/s 测速子系统

## 1. 用户可见语义

`Ctrl+T` 测试当前光标选中的配置，不测试所有配置，也不自动改默认。

表格的两个值定义为：

- **延迟（ms）**：通过该配置建立完整代理链路后，对固定 HTTPS 探测 URL 的 time-to-first-byte。
- **速度（MB/s）**：通过同一代理链路下载固定大小响应体的采样吞吐，使用十进制 `bytes / seconds / 1,000,000`。

这不是 ICMP ping，也不是服务器端口的纯 TCP connect 时间；必须在帮助页写明。

统一使用完整代理链路是为了让 VLESS REALITY、VLESS WS/TLS 和 Hysteria2 得到可比较结果。Hysteria2 是 QUIC/UDP，不能用 TCP connect 冒充协议延迟。

## 2. 模块与接口

新增：

```text
packages/netui/lib/probes.sh
```

建议接口：

```text
probes_start_for_config <path>
probes_poll <run-id>
probes_cancel <run-id>
probes_cancel_all
probes_cache_lookup <config-hash>
probes_cache_store <result-json>
probes_cleanup_run <run-id>
```

TUI 只接收：

```text
state=idle|queued|starting|latency|speed|done|failed|cancelled
latency_ms
speed_mbps_decimal
error_code
started_at
finished_at
cached
```

变量名可使用 `speed_mbps` 容易和 megabits 混淆，建议实际命名 `speed_mb_per_s`。

## 3. 测速目标

建议默认：

```text
latency URL: https://cp.cloudflare.com/generate_204
speed URL:   https://speed.cloudflare.com/__down?bytes=8388608
```

v0.2.0 锁定策略：

- `Ctrl+T` 是用户对本次第三方网络请求的明确触发，不再增加首次使用确认框；帮助页和 footer 测试中状态必须展示目标域名类别。
- 每次测试先做延迟，再做 8 MiB throughput；速度目标失败时保留已成功的延迟结果。
- production `probes_start_for_config` 只使用上述两个写入模块的固定 HTTPS URL，不读取任何 URL override 环境变量或用户配置，避免继承环境静默改变第三方目标。
- 测试不通过 packaged `netctl` 覆盖目标：纯函数直接解析 fixture metrics/header，fake worker 忽略固定 URL 并返回确定结果；本地 HTTPS 行为测试放在 `tests/netui/` 专用 helper，不进入 Release，也不改变 production public API。
- 固定 URL 在实现中仍做无 userinfo、fragment、控制字符的 HTTPS 自校验；不 `source` 配置，不 `eval` URL。
- UI 帮助页说明测试会访问第三方 HTTPS endpoint，并显示 decimal MB/s 定义。
- 离线或目标失败显示 target error，不标记配置 invalid。
- 发布前必须在至少两个网络环境验证默认目标的状态码、redirect、effective URL、Content-Length/实际下载大小和 HTTPS 保持情况；失败即阻断速度功能发布。

## 4. 隔离测试实例

测速不能：

- 停止当前运行实例；
- 改 default；
- 复用固定 NetUI tmux session；
- 让 probe sing-box 继承当前 proxy 环境；
- 使用宽泛 `pkill`。

流程：

1. 在短暂 config lock 内验证并复制选中配置到私有 probe run dir。
2. `config_meta` 确认 primary proxy outbound 和 eligibility。
3. 生成 probe snapshot，仅处理 `config_meta_probe_eligibility` 已确认的简单图：
   - 恰好一个 server/server_port proxy outbound；
   - 不含 selector/urltest、detour、重复 tag 或依赖原 inbound tag 的 route/DNS rule；
   - outbound 无 tag 时只在 snapshot 中赋予 `netui-probe-proxy`；
   - inbounds 全部替换为随机 loopback mixed inbound；
   - route 重建为 `auto_detect_interface + final=<unique-proxy-tag>`；
   - 保留该单一 outbound 和必要 top-level DNS；复杂依赖直接标记 unsupported，不猜测 dependency closure；
   - 日志写入 run dir，级别 warning/error；
   - snapshot 再次通过 sing-box check 后才启动。
4. 释放 config lock。
5. 以清空 proxy/no_proxy 的环境直接启动短生命周期 sing-box 子进程。
6. 记录 PID、`/proc` starttime、core path、run token 和 config path。
7. 有界等待本地端口 ready。
8. 执行 curl 延迟与速度请求。
9. 写脱敏结果 JSON。
10. 终止并验证 probe process，清理临时配置和原始日志。

probe 是 TUI 的短生命周期子进程，不是常驻代理，因此不纳入“持久实例只由 tmux 托管”的限制；退出 TUI 后不得残留。

## 5. 临时端口

不依赖系统级端口预留服务：

- 候选范围建议 20000–45000。
- 在私有 probe lock 下随机选择。
- 启动前检查 `/proc/net/tcp`、`tcp6` 或已有公共 helper。
- 启动后以实际 ready 结果为准。
- bind 冲突时销毁进程并重试，最多 10 次。
- 不使用用户配置里的 10808，避免与当前实例冲突。

端口检查有 race，最终判断必须是 sing-box 启动结果，而不是预检查本身。

## 6. curl 调用

所有 probe curl：

- 使用显式绝对/解析后的 curl path；
- `env -u` 清除大小写 proxy/no_proxy；
- 显式 `--proxy socks5h://127.0.0.1:<port>` 或本地 mixed 支持的 HTTP proxy；
- `--connect-timeout`、`--max-time`；
- `--silent --show-error`；
- 发送 `Accept-Encoding: identity`，避免压缩让字节语义漂移；
- 响应体写 `/dev/null`；
- 固定 `--write-out` 输出 `http_code`、`time_starttransfer`、`time_total`、`size_download`、`speed_download` 和 `url_effective`；
- 用 `--dump-header` 写入 mode `600` 的每次请求临时 header 文件，解析最后一个 response block 的 `Content-Encoding`；仅允许缺失或 `identity`，随后立即删除 header 文件；
- 验证 effective URL 仍是无 userinfo/fragment 的 HTTPS，reject redirect-to-HTTP；
- 不把 URI 凭据放 argv；curl 只看到本地 proxy endpoint 和测试 URL。

### 延迟

- 最大 10 秒。
- 使用 `time_starttransfer`。
- HTTP 状态须为 2xx/204（按目标策略）。
- 结果转换为整数 ms，可保留内部小数。
- sing-box 启动耗时单独记录，不并入表格延迟。

### 速度

- 默认对象 8 MiB。
- 最大 15 秒。
- 至少下载 1 MiB 才允许计算；过小响应标记 target invalid。
- 使用 `size_download` 和 `time_total`。
- 计算 decimal MB/s，显示一位小数；低于 0.05 可显示 `<0.1`。
- HTTP redirect 上限 3，且最终必须 HTTPS。
- 不做上传测速。

## 7. 状态与表格显示

| 状态 | 延迟列 | 速度列 |
|---|---|---|
| 未测试 | `—` | `—` |
| 启动中 | `…` | `…` |
| 延迟完成，速度进行中 | `218 ms` | `…` |
| 成功 | `218 ms` | `2.1 MB/s` |
| 超时 | `timeout` | `—/timeout` |
| 配置不支持 | `N/A` | `N/A` |
| 取消 | `cancel` | `cancel` |
| 失败 | `×` | `×` |

footer 显示更具体但脱敏的错误：

```text
Probe failed: proxy handshake timeout
Probe failed: speed target returned unexpected size
Probe unsupported: multiple proxy outbounds
```

不得把 sing-box/curl 原始输出直接显示。

## 8. 异步 worker 与崩溃恢复

credential-bearing active run 不放在持久 cache 目录：

```text
NETUI_PROBE_ACTIVE_DIR=
  $XDG_RUNTIME_DIR/netui/probes          # 仅当目录绝对、当前 UID 拥有、非 symlink
  或 $NETUI_RUNTIME_DIR/probes-active    # 安全 fallback

$NETUI_PROBE_ACTIVE_DIR/<run-id>/
├── owner.json
├── state.json
├── result.tmp.json
├── probe-config.json    # core ready 后立即 unlink
└── probe.log            # bounded，完成/失败后立即删除

$NETUI_STATE_HOME/probes/cache.json      # 只含脱敏结果
```

权限：目录 `700`，文件 `600`；创建每级目录前拒绝 symlink/non-directory。

父进程记录：

- worker PID；
- probe core PID；
- process starttime；
- core path；
- run token；
- config SHA256。

生命周期：

1. worker 只写原子 JSON：先 `.tmp`，再 `mv -T`。
2. sing-box ready 且已读入配置后立即删除 `probe-config.json`。
3. 完成/失败/取消后删除原始 probe log，只把值无关 error code 写 result/cache。
4. NetUI 每次启动先扫描 direct child run dirs：校验 owner marker/path；匹配仍存活的自有进程才 TERM/KILL；PID 不存在或 starttime 已变化的 verified-dead run 可安全清理。
5. TTL 只适用于 verified-dead run；若 owner marker 损坏或指向无法验证的 live process，既不 kill 也不删除 credential file，NetUI 把它标为安全事件、拒绝启动新 probe，并要求用户检查该私有路径。未知 live process 保护优先于自动清理。
6. 清理函数拒绝 `/`、父目录、symlink 和越界 realpath。

TUI 每 100–250 ms 轮询小文件，不 tail worker stdout。

## 9. 并发

v0.2.0：

- 同时只允许一个 active probe run；
- `Ctrl+T` 再次按下时提示已有任务；
- probe 不锁住 MAIN：可移动光标、切换日志源、切环境模式、刷新、帮助和退出；
- Esc 在无 modal 时取消当前任务；
- 任务绑定启动时的 config hash/basename，结果不得写到后来选中的行；
- 吞吐阶段不与其他 throughput 并发；
- 后续批量测速再增加全局 4 worker 上限。

单任务策略能先保证进程所有权、速度目标公平和 TUI 稳定。

## 10. 取消与清理

取消步骤：

1. state 写 `cancelled`。
2. TERM tracked worker/process group。
3. 验证 probe core PID/starttime/core path/token。
4. 等待短 grace period。
5. 仍存活才 KILL 已验证进程。
6. `wait` 子进程，避免 zombie。
7. 删除 probe config、原始 log 和临时 curl 文件。
8. 可保留无秘密的 cancelled result，不能当缓存命中。
9. 下次 NetUI 启动仍执行 stale active-run cleanup，覆盖 SIGKILL/断电未走 trap 的情况。

触发：

- Esc；
- q/正常退出；
- Ctrl-C；
- HUP/TERM；
- TUI 异常；
- 整体 timeout。

## 11. 缓存

cache key：

```text
config SHA256
probe schema version
latency target identifier
speed target identifier
```

建议 TTL：

- 延迟：5 分钟；
- 速度：15 分钟；
- 失败：30 秒；
- cancelled：不缓存。

存储：

```text
$NETUI_STATE_HOME/probes/cache.json
```

要求：

- mode `600`；
- 不存配置正文、URI、UUID、密码、key；
- basename 仅作 UI 便利，hash 是真实失效依据；
- 文件内容改变自然 cache miss；
- v0.2.0 的 `Ctrl+T` **总是强制刷新**；cache 只用于 TUI 重绘、重启 TUI 后展示最近值和避免结果因 rename 丢失；
- footer 对旧 cache 显示 age，TTL 到期后仍可显示灰色 stale 值，但不得冒充新测试。

## 12. 依赖

测速需要：

- bundled/current sing-box；
- curl；
- jq；
- sha256sum；
- awk；
- 可选 `timeout` 作为外层 guard。

安装器应把 curl/timeout 纳入清晰依赖诊断。缺少 curl 时：

- TUI 仍可管理配置；
- Ctrl+T 显示 `probe dependency missing: curl`；
- 不把配置标为无效。

## 13. 测试

### 纯 fake

- fake sing-box 模拟 ready、crash、hang、bind conflict。
- `NETUI_CURL` 注入 fake curl，输出固定 timing/bytes/status。
- 成功得到预期 ms 和 MB/s。
- timeout/cancel/worker crash。
- speed response 过小。
- HTTP 非 2xx。
- malformed write-out。
- active task 防重入。
- process identity mismatch 时拒绝 kill。
- 退出后无 child/zombie/run dir 泄漏。
- 模拟 worker `SIGKILL`/断电后，下次启动清理 credential snapshot 与 stale run dir。
- symlink run dir、越界 path 和 unknown live process 均不被误删/误杀；unknown live owner 会阻断新 probe 并给出安全事件。
- effective URL redirect-to-HTTP、URL userinfo/fragment 和最终 response `Content-Encoding` 非 identity 被拒绝，header 临时文件随后删除。
- packaged production entrypoint 完全没有 probe URL override；测试只使用不进入 Release 的 helper 和纯 metrics/header fixture。

### 可控本地集成

- 使用受控本地 HTTPS endpoint 和测试 CA，或把 HTTP 仅限 fake-curl 单元测试；真实 proxy-chain 集成保持 HTTPS-only。
- 验证 local proxy request 路径、effective URL 和计时解析。
- 不在常规测试中访问默认公网测速 URL。

### 手工

- 仅在一次性测试机或用户明确提供的本机配置上运行三类真实节点。
- 记录协议、结果状态和耗时，不记录 endpoint/credential。
- 验证测速期间当前受管实例 PID、tmux token 和本地端口不变。

## 14. 验收

- 三类指定协议均能通过完整代理请求得到延迟。
- 速度以十进制 MB/s 显示。
- Ctrl+T 不改 default、不重启、不停止当前实例。
- Esc/退出无残留测试进程。
- 失败状态可理解且不泄密。
- 结果按配置内容失效，不因重命名错误复用旧值。
