# 02｜命令契约、目录模型与运行时

## 1. 公共命令面

第一版只对用户承诺三个命令：

```bash
netup
netdown
netui
```

内部可以存在 `netctl`，但它不是必须宣传的公共入口。安装器将三个命令名链接到同一个核心，通过 `basename "$0"` 分派，避免复制三套逻辑。

### `netup`

语义固定：

1. 获取生命周期锁。
2. 解析默认配置 symlink。
3. 验证目标必须位于配置目录内、是普通文件、以 `.json` 结尾。
4. 执行 `jq empty` 和 `sing-box check`。
5. 检查 NetUI 会话是否已运行。
6. 检查配置声明的本地监听端口是否冲突。
7. 在显式清除 proxy/no_proxy 变量的环境中，通过 tmux 启动 sing-box，并写入本地日志，防止核心自代理循环。
8. 等待进程/监听健康信号。
9. 保存“本次实际运行配置”和可用本地代理 endpoint 快照。
10. 更新环境 generation，并把所选环境模式同步到 tmux global environment；当前父 shell 在命令返回后的 prompt hook 中生效。
11. 输出简短结果，不输出秘密。

`netup` 不支持 `netup other.json`。临时绕过默认项会破坏用户已确认的产品语义。

### `netdown`

语义固定：

1. 获取生命周期锁。
2. 检查 NetUI tmux 会话；若不存在，只跳过终止动作，仍继续清理 stale runtime state、tmux environment 并更新 generation，最后幂等返回“未运行”。
3. 若会话存在，先验证 NetUI 管理 token、pane ID/PID、进程启动时间和核心路径；任一不匹配则拒绝停止，不关闭同名会话。
4. 只向验证通过的受管进程发送终止，不使用宽泛的 `pkill -f sing-box`。
5. 有界等待退出，必要时再终止已验证属于 NetUI 的 pane/会话。
6. 清理运行 endpoint/快照，保留日志、默认配置和用户选择的环境 preference。
7. 更新环境 generation；shell hook 在下一个 prompt 撤销当前有效的 NetUI proxy 变量，避免指向已关闭端口。

`netdown` 停止“当前受管实例”；它不会因为默认配置后来变化而寻找另一个配置进程。

### `netui`

- 要求交互式 TTY；非 TTY 时输出清晰错误和可用 CLI 提示。
- 展示全部配置、默认项、当前运行项、健康状态、持久环境模式与当前有效状态。
- 管理 `global`、`cn-direct`、`off` 三种环境状态，并同步 shell/tmux。
- 所有启动操作最终调用与 `netup` 相同的 runtime 函数。
- 所有停止操作最终调用与 `netdown` 相同的 runtime 函数。
- TUI 不复制业务逻辑。

## 2. 退出码

建议统一：

| code | 含义 |
|---:|---|
| 0 | 成功或幂等目标已满足 |
| 1 | 一般运行失败 |
| 2 | 参数/命令使用错误 |
| 3 | 未安装或依赖缺失 |
| 4 | 没有默认配置 |
| 5 | 配置无效 |
| 6 | 已有异常/冲突实例或端口占用 |
| 7 | 安装、checksum 或版本验证失败 |
| 8 | 并发锁超时 |

TUI 可把这些错误转成可读提示，但不能吞掉真实非零结果。

## 3. XDG 路径模型

默认变量：

```text
NETUI_BIN_DIR       = ${XDG_BIN_HOME:-$HOME/.local/bin}
NETUI_DATA_HOME     = ${XDG_DATA_HOME:-$HOME/.local/share}/netui
NETUI_CONFIG_HOME   = ${XDG_CONFIG_HOME:-$HOME/.config}/netui
NETUI_STATE_HOME    = ${XDG_STATE_HOME:-$HOME/.local/state}/netui
NETUI_CONFIG_DIR    = $NETUI_CONFIG_HOME/configs
NETUI_DEFAULT_LINK  = $NETUI_CONFIG_HOME/default.json
NETUI_ENV_MODE_FILE = $NETUI_CONFIG_HOME/env-mode
NETUI_RELEASES_DIR  = $NETUI_DATA_HOME/releases
NETUI_CURRENT_LINK  = $NETUI_DATA_HOME/current
NETUI_LOG_DIR       = $NETUI_STATE_HOME/logs
NETUI_RUNTIME_DIR   = $NETUI_STATE_HOME/runtime
NETUI_ENV_GENERATION= $NETUI_RUNTIME_DIR/env-generation
NETUI_PROXY_ENDPOINT= $NETUI_RUNTIME_DIR/proxy-endpoint
NETUI_BACKUP_DIR    = $NETUI_STATE_HOME/backups
```

实现允许环境变量覆盖，以便测试使用临时 HOME；正常用户无需设置。

## 4. 默认配置模型

### 4.1 数据结构

```text
~/.config/netui/
├── configs/
│   ├── office.json
│   ├── gpu-hy2.json
│   └── reality-backup.json
└── default.json -> configs/gpu-hy2.json
```

配置目录是唯一配置清单，不建立 registry 数据库。把新 `*.json` 放入目录，`netui` 刷新后即可发现。

### 4.2 原子设置默认

设置流程：

1. 对选中配置做路径规范化和完整校验。
2. 在 `NETUI_CONFIG_HOME` 内创建临时相对 symlink。
3. 使用同文件系统的 `mv -T`/等价原子替换更新 `default.json`。
4. 重新解析并确认目标未逃逸配置目录。
5. 写入不含秘密的审计信息：时间、旧 basename、新 basename。

禁止：

- 将默认项指向配置目录外。
- 指向目录、FIFO、设备或不存在路径。
- 用用户输入直接拼接 `ln -s` 命令字符串。
- 通过复制配置内容生成第二份“默认配置”，避免两份配置漂移。

### 4.3 默认与运行状态分离

启动时记录：

```text
running_config_basename
running_config_resolved_path
running_config_mtime
running_config_sha256
sing_box_version
started_at
local_inbound_summary
```

这些数据只保存在本机 `700` 的 state 目录。TUI 用它区分：

- 默认 = A，运行 = A：正常一致。
- 默认 = B，运行 = A：显示黄色“默认已更改，重启后生效”。
- 默认无效，运行仍在：显示错误，但不主动杀掉现有实例。
- 会话不存在但 state 存在：标记 stale 并提供清理动作。

## 5. 配置发现与校验

### 5.1 发现规则

MVP 使用扁平目录：

- 只扫描 `NETUI_CONFIG_DIR` 第一层的普通 `*.json` 文件。
- 排序规则为 `LC_ALL=C` 的文件名排序，TUI 可将默认项置顶显示。
- 允许空格和常见 Unicode，但拒绝换行、控制字符、`/` 和路径穿越。
- 不跟随配置目录中的任意外部 symlink；导入时复制为普通文件。

扁平目录能避免重名、递归和 symlink 逃逸复杂度，足以覆盖当前三份配置。

### 5.2 两级校验

1. `jq empty <config>`：保证 JSON 语法成立。
2. `sing-box check -c <config>`：保证与当前核心版本兼容。

校验错误只显示 sing-box 的必要尾部诊断，并过滤/避免回显 JSON 字段值。

### 5.3 摘要提取

TUI 可安全显示：

- 文件名。
- outbound 协议类型。
- inbound 类型、listen、listen_port。
- TLS/REALITY 是否启用。
- 修改时间。
- 校验状态。

默认不显示：

- password。
- UUID。
- private/public key。
- short ID。
- 完整分享链接。

服务端 hostname/IP 可在本机“详情”页按需显示，但不得写入公开日志、测试 fixture 或 Release 记录。

## 6. tmux 运行时

### 6.1 会话

- 每个 Unix 用户只维护一个会话，例如 `netui`。
- tmux 本身按用户隔离；无需在会话名嵌入可泄漏的 hostname，但固定名字本身不能作为所有权证明。
- 启动时生成随机 runtime token，写入 mode `600` 的 state，并设置 tmux session 自定义 option（如 `@netui_token`、`@netui_core`）。
- state 同时记录 pane ID、pane PID、`/proc/<pid>/stat` starttime 和核心绝对路径；停止/attach/log 前都交叉验证，防止同名用户会话、命令替换和 PID 复用。
- 同名会话存在但 marker/token 不匹配时，`netup`/`netdown` 拒绝操作并给出诊断，绝不杀该会话。
- 启动命令使用参数数组或安全 wrapper，配置路径作为独立参数传入。
- stdout/stderr 追加到 `NETUI_LOG_DIR/sing-box.log`，并保留有限轮转。
- 启动 wrapper 必须 `env -u` 清除大小写 proxy/no_proxy，避免 sing-box 继承用户代理环境后回连自身。
- 环境模式变化通过 `tmux set-environment -g` 同步给以后创建的 pane/window；已有 pane 仍由 shell prompt hook 在下一提示符同步。

### 6.2 启动判定

不能只检查 tmux 是否存在。健康状态分层：

1. tmux 会话存在。
2. 会话中目标 pane 命令仍存活。
3. 运行配置预期的本地端口已监听。
4. 可选健康探测通过。

第一版不把访问外网出口 IP 作为启动成功的硬门槛，因为节点、UDP、DNS 或目标网络可能暂时不可用；应将其作为 TUI 的显式“连通性测试”。

### 6.3 端口冲突

- 从 JSON 中提取所有本地 inbound listen_port。
- 启动前检查这些端口。
- 若端口被 NetUI 自己的现有实例使用，返回“已运行”。
- 若被其他进程占用，拒绝启动并展示端口/PID 摘要；不自动杀进程。

### 6.4 并发控制

使用 `flock` 锁住：

- `netup`。
- `netdown`。
- 默认配置切换。
- 环境模式切换与 generation 更新。
- 配置导入/重命名/归档。
- 安装升级与回滚。

锁需有明确超时和错误提示，避免两个 TUI/CLI 同时修改 symlink 或 tmux。

## 7. CLI、环境 preference 与父 shell

安装后的 `netup/netdown/netui` 是外部可执行命令，本身不能直接改写调用它们的父 shell。第一版因此把环境管理设计为正式功能，而不是可选 helper：

- `netup` 的直接职责仍是启动默认 JSON 对应的本地代理进程；成功后更新 runtime endpoint/generation。
- `netdown` 的直接职责仍是停止受管进程；成功后撤销 runtime endpoint 并更新 generation。
- `netui` 原子写入 `global`、`cn-direct` 或 `off` 的持久 preference。
- 安装器在 `.bashrc`/`.zshrc` 中加入轻量、带标记且可卸载的 shell hook；每个 prompt 先检查 generation，变化时在父 shell 内 export/unset。
- 模式变化同步 tmux global environment，供之后创建的 tmux pane/window 继承。
- 旧 `proxyon/proxyoff` 可不再保留；新 hook 不能重新定义或遮蔽 `netup/netdown`。
- 代理未运行时暂时撤销有效 proxy 变量，但保留 preference；下次 `netup` 后自动恢复。
- 复合命令 `netup && curl ...` 中间没有 prompt，环境尚未刷新；文档要求先让 `netup` 返回提示符。

两套 `no_proxy`、shell hook、tmux 同步和所有权规则详见 [04-environment-profiles.md](./04-environment-profiles.md)。

## 8. 日志与诊断

建议：

```text
~/.local/state/netui/logs/sing-box.log
~/.local/state/netui/logs/netui.log
```

规则：

- mode `600`，父目录 `700`。
- 不记录完整配置或敏感字段。
- 记录版本、配置 basename、操作结果、退出码和时间。
- `netui` 日志查看页支持 tail，不默认进入 tmux attach。
- 轮转可采用简单的大小阈值和最近 3 份文件，不引入 logrotate 系统依赖。

## 9. 升级兼容

运行时总是从 `NETUI_CURRENT_LINK` 找到当前程序和 sing-box。升级流程先安装新 release 目录，再切换 `current`：

- 现有实例可以继续运行旧 inode，直到用户显式重启。
- 升级成功不自动改变默认配置。
- 若升级后默认配置 check 失败，不切换 `current` 或立即回滚。
- 至少保留当前和上一个版本，支持显式回滚。
