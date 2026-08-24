# NetUI v0.2.0｜v2rayN 风格全屏 TUI 总计划

> 状态：**计划已形成，尚未实现**
> 目标版本：`v0.2.0`
> 计划日期：2026-08-24
> 基线版本：NetUI `v0.1.0`
> 参考图：本地 `v2rayN.png`，仅用于视觉分析；图中包含真实端点，不纳入 Git、测试 fixture、Release 或公开截图。

## 1. 目标

在不破坏现有 `netup`、`netdown`、默认配置原子切换、tmux 所有权校验和持久环境 profile 的前提下，把 `netui` 从“渲染后选择动作”的菜单式界面升级为类似 v2rayN 的常驻全屏配置管理器。

新版界面必须具备：

1. 顶部不再显示传统导航菜单，改为始终可见的快捷键提示栏。
2. 中间以表格展示所有 JSON 配置，方向键移动光标，整行高亮当前选择。
3. 表格至少显示：名称、服务器地址、端口、协议、传输/TLS、安全类型、延迟和速度。
4. 下方固定日志面板，运行时增量刷新，不要求进入单独日志页面。
5. footer 固定显示选中/默认/运行配置、最近延迟与速度、全局/大陆白名单模式及本地代理 endpoint。
6. `i` 打开分享链接导入框；支持粘贴、Enter 提交、Esc 取消，并把分享链接安全解析为 sing-box JSON。
7. 第一版 URI 导入至少覆盖：
   - VLESS + TCP + REALITY + XTLS Vision；
   - VLESS + WebSocket + TLS；
   - Hysteria2；
   - `hy2://` 作为 Hysteria2 别名。
8. `Ctrl+T` 对当前选中配置执行完整代理链路延迟和采样下载速度测试，在表格中显示 `ms` 与十进制 `MB/s`。
9. 协议、地址、端口、传输和安全类型一律从 JSON 内容提取，绝不按文件名猜测。

## 2. 参考图转译原则

参考图提供的是信息架构，不是要在终端里复制 Windows 控件。

保留：

- 高密度节点表格；
- 整行选中态；
- 地址、端口、协议、延迟、速度同屏；
- 下半区实时日志；
- 最底部当前节点和路由模式状态；
- 主要动作靠键盘直接触发。

不照搬：

- Windows 标题栏、图标工具栏和鼠标按钮；
- 订阅分组、系统代理开关、TUN 开关等本期未定义能力；
- 会泄露真实节点的截图内容；
- 依赖颜色才能理解的状态。

## 3. 已锁定快捷键

| 快捷键 | 行为 | 安全语义 |
|---|---|---|
| `↑` / `↓` | 移动 JSON 配置光标 | 到边界后停止，不循环跳转 |
| `Enter` | 将选中配置设为默认 | 先校验；不自动重启当前实例 |
| `Ctrl+↑` | 切换为全局代理模式 | `no_proxy` 仅 loopback |
| `Ctrl+↓` | 切换为大陆白名单直连模式 | 使用现有受控 `cn-direct` profile |
| `Ctrl+R` | 打开“重启默认配置”确认框 | Enter 确认，Esc 取消 |
| `Ctrl+T` | 测试选中配置的延迟和下载速度 | 后台执行，可取消，不中断当前实例 |
| `i` | 打开分享链接导入框 | 单链接、盲粘贴、解析后显示脱敏预览 |
| `Esc` | 取消 modal/输入/测速 | 主界面无 modal 时仅清除临时提示 |
| `o` | 关闭 NetUI 环境变量 | 保留既有 `off` 能力，但不占主快捷栏核心位置 |
| `r` | 重新扫描配置和日志 | 不发起网络请求 |
| `q` | 退出并恢复终端 | 不停止正在运行的 sing-box |
| `?` | 打开完整帮助 | 显示扩展键位和状态符号 |

`Ctrl+↑`、`Ctrl+↓` 使用直接映射而不是三态循环，避免用户无法预测下一状态。`off` 保留为独立 `o` 动作。

## 4. 目标布局

```text
╭─ NetUI 0.2 ───────────────────────────────────────────────────────────────╮
│ ↑↓ 选择  Enter 默认  Ctrl↑ 全局  Ctrl↓ 白名单  CtrlR 重启  CtrlT 测速 │
│ i 导入  r 刷新  o 关闭环境  ? 帮助  q 退出                             │
├─ 配置 ───────────────────────────────────────────────────────────────────┤
│ S  名称               地址                端口  协议       安全  延迟 速度│
│ ★  office-reality     192.0.2.10          443   VLESS/TCP  R    218  2.1 │
│ ▶● hk-ws              ws.example.invalid  443   VLESS/WS   TLS  500  0.8 │
│    backup-hy2         hy.example.invalid  443   Hysteria2 QUIC 198  7.5 │
├─ 日志 ───────────────────────────────────────────────────────────────────┤
│ 12:00:01 accepted connection ...                                         │
│ 12:00:04 route selected ...                                               │
│ 12:00:08 connection closed ...                                            │
├───────────────────────────────────────────────────────────────────────────┤
│ Default: office-reality  Running: hk-ws  Selected: hk-ws                 │
│ Latency: 500 ms  Speed: 0.8 MB/s  Mode: CN whitelist  Local: mixed://127.0.0.1:10808 │
╰───────────────────────────────────────────────────────────────────────────╯
```

状态符号：

- `▶`：光标所在行；
- `★`：默认配置；
- `●`：当前运行配置；
- `!`：JSON 或 sing-box 校验失败；
- `…`：校验或测速进行中；
- `×`：最近测速失败；
- 同一行可组合多个状态，例如 `▶★●`。

## 5. 架构原则

### 5.1 复用现有业务层

继续复用：

- `config_store_discover`、`config_store_validate_config`、`config_store_set_default`；
- `runtime_start`、`runtime_stop`、tmux token/PID/starttime/core 路径校验；
- `env_profiles_get_mode`、`env_profiles_set_mode`；
- XDG 路径、权限、flock 和默认配置 symlink 模型；
- `NETUI_TUI_ACTIONS` 非交互业务测试入口。

TUI 只能调用这些公共业务动作，不能重新实现第二套默认切换、启动、停止或环境模式逻辑。

### 5.2 新增三个独立能力层

建议新增：

```text
packages/netui/lib/config_meta.sh     # 从 JSON 内容提取表格元数据
packages/netui/lib/share_uri.sh       # 分享 URI 解析、校验和 JSON 生成
packages/netui/lib/probes.sh          # 异步延迟/速度测试及缓存
```

TUI 自身再拆为：

```text
packages/netui/lib/tui_terminal.sh    # raw mode、按键解码、终端恢复
packages/netui/lib/tui_render.sh      # 表格、日志、footer、modal 渲染
packages/netui/lib/tui.sh             # 模型、事件循环和动作协调
```

如实现阶段证明拆分过细，可合并 `tui_terminal.sh` 和 `tui_render.sh`，但 URI 与测速必须保持独立模块。

### 5.3 全屏主界面以 ANSI 为核心

新的主界面不再依赖 `gum choose` 驱动页面跳转。原因：

- 需要常驻光标、滚动表格、实时日志和异步测速；
- 需要直接解析方向键、Ctrl 组合键、Esc 和 bracketed paste；
- gum 适合一次性输入/确认，不适合作为完整事件循环。

bundled gum 可继续用于非全屏 fallback 或未来辅助组件，但主屏应由 Bash + ANSI 控制。

## 6. 多文件计划索引

1. [交互、布局与视觉规格](./01-interaction-and-visual.md)
2. [终端事件循环与渲染引擎](./02-terminal-engine.md)
3. [分享 URI 导入与 sing-box JSON 生成](./03-share-uri-import.md)
4. [JSON 内容元数据与协议识别](./04-config-metadata.md)
5. [延迟与 MB/s 测速子系统](./05-probes.md)
6. [自动化、PTY 与视觉回归](./06-verification.md)
7. [实施顺序、安装体验与 v0.2.0 发布](./07-delivery.md)

## 7. 实施里程碑

### M0：冻结交互契约和安全边界

- 确认快捷键、modal、表格列和 footer 字段。
- 把参考图转译为脱敏 ASCII 规格。
- 明确 `Ctrl+T` 只测试选中行；批量测速延后。
- 定义延迟为“完整代理链路 HTTPS TTFB”，速度为“采样下载十进制 MB/s”。
- 定义 URI 输入不写历史、不进入 argv、不写日志。

### M1：统一 JSON 元数据模型

- 新增 `config_meta.sh`。
- 从内容识别 VLESS/REALITY、VLESS/WS/TLS、Hysteria2。
- 提取服务器、端口、传输、安全类型和本地 endpoint。
- 建立基于文件 mtime/size/hash 的缓存。
- 当前 `config.json.hy2` 类错误命名不得影响显示结果。

### M2：全屏终端引擎

- 保存并恢复 `stty`、alternate screen、光标和 bracketed paste。
- 实现方向键、Ctrl 键、Esc 超时解析、滚动和 resize。
- 实现 frame-buffer 式单次刷新，避免后台输出破坏屏幕。
- JSON 摘要先显示，`sing-box check` 通过有界后台队列完成，慢配置不能冻结事件循环。
- 实现日志面板和 footer，并处理日志轮转、截断和 inode 变化。
- 小终端进入紧凑布局，`TERM=dumb` 保留菜单 fallback。

### M3：URI 导入

- 实现安全的组件级 percent decode。
- 支持三类指定分享 URI 参数组合。
- 用 `jq -n --arg/--argjson` 生成 JSON。
- 运行 `jq empty` 与 pinned sing-box `check`。
- 根据现有默认/运行配置选择一致的 loopback mixed 端口；若被无关进程占用，预览并分配安全备用端口。
- 以 mode `600` 原子写入 configs，冲突自动追加 `-2`、`-3`，绝不覆盖。
- 导入成功后刷新列表并把光标移到新配置。

### M4：异步测速

- 对选中配置创建隔离的临时 sing-box 测试实例。
- 通过本地 SOCKS/HTTP endpoint 测量 HTTPS TTFB 和 8 MiB 采样下载。
- 后台 worker 只写私有结果文件，不直接写终端；主表、日志、模式切换和退出在测速期间仍可操作。
- TUI 轮询状态并更新原始目标行，移动光标不会把结果写错行。
- Esc/退出时只终止经过身份验证的测试进程。
- credential-bearing probe snapshot 在 core ready 后立即删除；启动时清理崩溃遗留的 stale run dir。
- 按配置内容 hash 只缓存脱敏结果并设置 TTL。

### M5：测试与视觉验收

- 增加纯函数测试、URI mapping 测试、fake probe 测试和真实 PTY 键位测试。
- VHS 覆盖主屏、上下移动、Enter 默认、模式切换、导入 modal、测速、日志、窄屏和 fallback。
- 参考图不进入 baseline；baseline 使用全部脱敏的合成节点。
- 更新 ImageMagick 视觉门禁，禁止动态时间/PID/真实端点。

### M6：v0.2.0 发布

- 不修改已发布的 `v0.1.0` tag 和资产。
- 修复安装器“长时间静默”和只报第一个依赖的问题。
- 更新依赖诊断、README、Release notes、双架构包和 checksum。
- 在临时 HOME 和一次性 Ubuntu 环境验证 curl 管道安装、TUI、导入和测速。
- 创建新 annotated tag `v0.2.0` 后再发布。

## 8. 第一版范围

### 必须交付

- 全屏、键盘驱动的表格/日志/footer 界面。
- 指定快捷键及安全确认语义。
- 地址、端口、协议、延迟和速度列。
- 指定三类 URI 的导入。
- 内容级协议识别。
- 选中配置的异步延迟与速度测试。
- 日志持续刷新、控制字符清洗和终端恢复。
- 宽屏、窄屏和无 gum fallback。
- 安装阶段可见日志和完整缺失依赖列表。

### 后续再做

- 订阅 URL 和订阅分组。
- 多链接批量粘贴。
- 批量并发测试所有节点。
- 自动按延迟排序或自动选择最快节点。
- TUN、透明代理、系统代理 GUI 开关。
- 鼠标操作。
- 多实例同时运行不同 JSON。
- 在线订阅转换服务。

## 9. 完成定义

只有同时满足下列条件才算完成：

1. `↑/↓` 在配置表内稳定移动，滚动后选中项不丢失。
2. Enter 只把选中项设为默认，不偷偷重启；默认与运行不一致时 footer 明确提示。
3. `Ctrl+↑` 和 `Ctrl+↓` 分别切换 global/cn-direct，退出 TUI 后 shell hook 仍按现有规则生效。
4. `Ctrl+R` 在停止前重新校验新默认配置并做端口预检；预检失败保留健康旧实例，停后启动失败则尝试恢复旧运行配置。
5. `Ctrl+T` 不打断当前运行实例，测速期间主界面仍可操作，最终在发起测试的行显示 `ms` 和 `MB/s` 或明确错误状态。
6. `i` modal 可粘贴三类要求中的任意一条合成测试链接；Esc 可取消输入和预览，commit 开始后遵守原子边界：rename 前可取消，rename 后视为已成功提交且不产生半文件。
7. 生成的三个配置均通过 sing-box 1.13.18 `check`。
8. 协议和服务器摘要来自 JSON；把 VLESS 配置命名为 `anything-hy2.json` 仍显示 VLESS。
9. 日志面板持续刷新且不能通过 ANSI 控制符改变 TUI 光标或颜色状态。
10. Ctrl-C、TERM、异常返回和测速取消后终端 echo、光标、alternate screen 全部恢复。
11. 测试、截图、日志、进程参数、环境变量和 Git 历史中没有用户提供的 UUID、密码、Reality key 或真实节点地址。
12. v0.2.0 安装器逐阶段输出进度，缺少 tmux 时给出完整依赖说明和可执行的系统安装建议，不表现为“卡住”。

## 10. 预计工作量

预计新增/重构约 1,500–2,500 行 Bash、测试和文档，主要不确定性集中在：

- Ctrl+方向键在不同 terminal/tmux 下的序列兼容；
- bracketed paste 与 Esc 区分；
- 异步测速进程清理；
- 多字节字符的终端单元格宽度；
- 外部测速目标的稳定性。

按 M0–M6 顺序实施，预计 24–40 小时；若只做指定三类链接、选中行测速和 ANSI 主路径，可控制在下限附近。
