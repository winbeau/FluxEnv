# 06｜自动化、PTY 与视觉回归

## 1. 验证策略

新版 TUI 同时包含业务逻辑、URI parser、后台进程和真实终端输入，不能只靠 `NETUI_TUI_ACTIONS` 或截图。

验证分五层：

1. Bash 纯函数测试。
2. config/store/runtime/probe 业务测试。
3. PTY/真实按键集成测试。
4. VHS + PNG 视觉回归。
5. 一次性 Linux 环境手工验收。

## 2. 现有测试保留

`tests/netui/run.sh` 已覆盖：

- 安全配置发现；
- 默认 symlink；
- tmux 所有权；
- runtime state；
- 环境 mode/ownership；
- shell hook；
- CRUD 和脱敏。

这些行为不能为了新 UI 重写掉。

现有 TUI 行式断言继续保留为业务 fallback 测试，但不再代表主 UI E2E。

## 3. 新测试文件建议

```text
tests/netui/run.sh
tests/netui/uri_import.sh
tests/netui/config_meta.sh
tests/netui/probes.sh
tests/netui/terminal_keys.sh
tests/netui/vhs/dashboard-v2.tape
tests/netui/vhs/keyboard-default.tape
tests/netui/vhs/env-shortcuts.tape
tests/netui/vhs/import-modal.tape
tests/netui/vhs/probe-results.tape
tests/netui/vhs/narrow-v2.tape
tests/netui/vhs/fallback-v2.tape
tests/netui/visual/baseline-v2/*.png
```

如果仓库希望保持单入口，`tests/netui/run.sh` 调用这些子脚本即可。

## 4. URI fixture 策略

绝不提交用户提供的三条真实 URI。

合成 fixture 使用：

- RFC 5737 reserved IPv4；
- `.invalid` 域名；
- 明确 synthetic UUID/password/key；
- fragment 使用普通测试名称。

由于现有 Release secret scan 对 bare share scheme 和 JSON credential key 过宽，测试字符串建议在运行时拼接：

```text
scheme_part + separator + authority + query
```

同时在 v0.2 实现阶段调整 secret scan：

- 识别真实 credential-bearing share 链接，而不是禁止 parser 源码出现 scheme 名称；
- 区分字段名与非占位字段值；
- 对 fixtures 使用 allowlisted synthetic markers；
- 继续扫描 Release staging、示例和生成资产中的真实秘密模式。

不能简单把整个 `packages/netui` 或 tests 排除扫描。

## 5. URI parser/mapping 测试

必须覆盖用户给出链接的**参数形态**：

### VLESS REALITY

- TCP；
- REALITY；
- Vision flow；
- SNI、fingerprint、public key、short ID；
- `headerType=none` 的 camelCase key；
- 生成后通过 sing-box 1.13.18 check。

### VLESS WS/TLS

- WebSocket；
- TLS；
- SNI；
- fingerprint；
- Host header；
- percent-encoded path；
- percent-encoded `http/1.1` ALPN；
- 生成后通过 check。

### Hysteria2

- password in userinfo；
- SNI；
- `insecure=1`；
- preview warning；
- 生成后通过 check。

### 负面

- malformed scheme/authority/port/UUID。
- duplicate query key。
- unknown security/transport。
- truncated percent escape。
- `%00`、CR/LF、control injection。
- path traversal label。
- shell metacharacters。
- oversized URI。
- collision suffix。
- validation failure cleanup。
- 10808 被无关进程占用时预览/写入备用 loopback port。
- Esc 在 input/preview/check 阶段取消；final rename 后只关闭成功提示，不留下半文件。

## 6. Metadata 测试

- filename 与协议故意矛盾。
- VLESS REALITY / VLESS WS / Hysteria2。
- direct + proxy。
- multiple proxy outbounds。
- selector/urltest。
- IPv4/domain/IPv6。
- missing server/port。
- invalid JSON but still listed。
- no secret fields in summary。
- content change invalidates cache。
- 50 个配置 + 慢 fake sing-box check 时，metadata 先显示且按键/日志继续响应。
- stale validation result 不能覆盖已修改文件的新状态。

## 7. Terminal key 测试

纯 decoder 测试传入 byte sequence：

- `ESC[A`、`ESC[B`。
- application cursor `ESCOA/ESCOB`。
- `ESC[1;5A/B` 和兼容短形式。
- standalone Esc timeout。
- Ctrl+R `0x12`。
- Ctrl+T `0x14`。
- `g/G`、`w/W`、`i/I`、`o/O`、`l/L`、`r/R`、`q/Q` 归一化。
- bracketed paste start/end。
- unknown CSI。
- incomplete sequence。

模型测试：

- 上边界/下边界不越界。
- scroll offset 跟随光标。
- refresh 后按 basename 保持选择。
- Enter 设置 default 但不 restart。
- Ctrl+R 遇到 invalid default 时旧 runtime PID/token 保持；post-stop start failure 执行旧配置 rollback。
- Ctrl+方向键和 g/w fallback mode 映射正确。
- modal 阻止按键穿透。
- resize clamp。

## 8. Probe 测试

通过 `NETUI_CURL`、`NETUI_SING_BOX`、固定时钟/结果注入实现确定性：

- worker states 完整转换。
- latency 秒转 ms。
- bytes/time 转 decimal MB/s。
- 8 MiB 成功。
- 小响应拒绝。
- connect/total timeout。
- speed target 失败。
- bind conflict retry。
- Esc cancel 且 MAIN 仍可移动光标、切日志源和切环境模式。
- q/Ctrl-C cleanup。
- 当前 tmux/runtime PID 不变。
- process identity mismatch 不误杀。
- cache hash/TTL。
- credentials 不进入 process args/env/result/cache。
- worker 被 `SIGKILL` 后下次启动清理 stale active-run snapshot。
- symlink/越界 run dir 和 unknown live process 不被误删/误杀；unknown live owner 阻断新 probe。
- redirect-to-HTTP、effective URL userinfo/fragment、最终 `Content-Encoding` 非 identity 被拒绝，header temp 被删除。
- packaged production entrypoint 不存在 URL override；本地 HTTPS target 只通过不进入 Release 的测试 helper 调用底层 metrics/header parser，不通过 `netctl` 环境注入。

## 9. PTY 与 VHS

VHS 本身提供 PTY，可测试真实按键和布局。Tape 固定：

- shell；
- font；
- viewport；
- color theme；
- synthetic HOME；
- synthetic configs；
- fake probe timing；
- 静态日志内容；
- 不含真实时间/PID。

### 场景

#### `dashboard-v2`

- 6 个合成配置。
- 一个默认、一个运行、一个 invalid。
- 三类协议均出现。
- 日志面板和 footer 可见。

#### `keyboard-default`

- Down 移动两行。
- Enter 设置 default。
- footer 出现 restart required。
- 不重启 runtime。

#### `env-shortcuts`

- Ctrl+↑ -> global。
- Ctrl+↓ -> cn-direct。
- `g`/`w` fallback 分别执行相同模式。
- `o` -> off。
- footer 状态和 generation 断言。

#### `import-modal`

- `i` 打开 modal。
- 粘贴运行时生成的 synthetic WS/TLS link。
- 输入内容被隐藏。
- preview 显示协议/address/port。
- Esc 取消一次。
- 第二次 Enter 导入成功，表格出现新行。

#### `probe-results`

- Ctrl+T 后行显示 `…`。
- fake worker 完成后显示固定 ms/MB/s，并写回发起测试的行而非当前光标行。
- footer 有脱敏完成信息；按 `l` 可在 core/NetUI event log 间切换。

#### `narrow-v2`

- 80 列和 70 列。
- 地址/速度按规则移入 footer。
- 日志至少保留 3–5 行。

#### `fallback-v2`

- `TERM=dumb` 或禁用 raw mode。
- 行式菜单仍支持 default/env/import/probe/log。

## 10. 视觉基线

旧 v0.1.0 baseline 会整体变化，不能使用宽松阈值掩盖。

流程：

1. 先生成 actual PNG。
2. 人工核对视觉结构和秘密扫描。
3. 显式 `UPDATE_VISUAL_BASELINE=1` 更新 v2 baseline。
4. 再运行一次不更新 baseline 的完整 suite。
5. 场景独立阈值；布局场景优先低 AE。
6. cursor 在 Tape 中隐藏，避免非确定差异。
7. diff PNG 保留在 gitignored artifacts。

参考图不作为 pixel baseline，因为：

- 平台不同；
- 包含真实端点；
- Windows 字体/控件不可复现；
- 目标是信息架构而非像素复制。

## 11. 静态检查

```bash
bash -n packages/netui/bin/netctl \
    packages/netui/install.sh \
    packages/netui/lib/*.sh \
    tests/netui/*.sh \
    tests/netui/visual/*.sh

dash -n packages/netui/bootstrap.sh
vhs validate 'tests/netui/vhs/*.tape'
git diff --check
```

若 `shellcheck` 可用：

```bash
shellcheck packages/netui/bin/netctl packages/netui/install.sh packages/netui/lib/*.sh tests/netui/*.sh
shellcheck -s sh packages/netui/bootstrap.sh
```

## 12. 安全断言

对工作树、测试输出和 Release staging 扫描：

- 用户给出的三个 UUID/password/public key/host/IP 不出现。
- 没有 credential-bearing share URI。
- 没有真实配置 JSON。
- 没有 raw import buffer。
- 没有 probe temp config/log。
- screenshots 只含 reserved/synthetic endpoint。
- log/control sequence fixture 不能逃逸 frame。
- core/NetUI log 的 truncate、inode replacement、rotation 和 partial line 不会卡死或重复无限读取。

## 13. 手工测试矩阵

| 环境 | 优先级 |
|---|---|
| Ubuntu 24.04 amd64 普通用户 | P0 |
| Ubuntu 24.04 amd64 root HOME | P0 |
| tmux 内 SSH 终端 | P0 |
| 无 gum / TERM=dumb | P0 |
| Linux arm64 | P0，因 Release 已承诺 arm64 |
| Ubuntu 22.04 / Debian 12 | P1 |

手工必测：

- Ctrl+方向键是否被 terminal/tmux 正确传递。
- Esc 响应速度。
- 粘贴三类真实链接后只显示脱敏摘要。
- 三个生成 JSON 均 check。
- 对三类配置执行 Ctrl+T。
- 测速期间当前运行实例不中断。
- 安装输出持续有阶段日志。

## 14. 发布门禁

- 所有现有 NetUI tests 通过。
- 新 URI/metadata/probe/key tests 通过。
- 实际 build-release 产物中包含所有新增模块；从解包安装后的 `current` 路径实际调用 metadata、URI import 和 probe fake 路径成功。
- VHS 全场景通过。
- actual/baseline/diff 人工核对。
- amd64 真实运行验证。
- arm64 至少做包内 ELF/schema/安装验证；正式承诺功能前应有 arm64 机器运行验证。
- curl 管道新装和重复安装均有进度输出。
- Release secret scan 通过。
- Git 工作树只包含预期计划/实现文件，不包含本地参考图。
