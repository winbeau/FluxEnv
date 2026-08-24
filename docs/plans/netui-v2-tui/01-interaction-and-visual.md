# 01｜交互、布局与视觉规格

## 1. 参考图观察

本次参考图呈现四个清晰层级：

1. 顶部操作区：常用动作可直接触发。
2. 中部节点表格：高密度、整行选中、关键指标同屏。
3. 下部日志区：持续刷新，可快速确认路由和连接活动。
4. 最底部状态栏：本地入口、路由模式、当前节点和最近延迟。

NetUI 的终端版保留这四层，但把鼠标按钮改成快捷键提示，把 Windows 表格改成 ANSI 表格，把系统代理/TUN 等未实现能力删除。

参考图文件中存在真实 IP、域名和访问日志，因此：

- 只做本地视觉分析；
- 不移动到 `docs/`；
- 不纳入 Git；
- 不作为 VHS baseline；
- 最终测试截图使用 `192.0.2.0/24`、`198.51.100.0/24`、`203.0.113.0/24` 和 `.invalid` 合成数据。

## 2. 信息架构

### 2.1 顶部快捷键栏

顶部固定两行，替代当前 `Actions:` 文本和 gum 菜单：

```text
↑↓ 选择  Enter 默认  Ctrl↑ 全局  Ctrl↓ 白名单  CtrlR 重启  CtrlT 测速
i 导入  r 刷新  o 关闭环境  l 日志源  ? 帮助  q 退出
```

字母快捷键接受大小写两种输入，文档统一用小写展示；Ctrl 组合键按控制字节处理，不引入大写 `T` 等冲突语义。

规则：

- 键名使用高亮/反色，动作使用普通色。
- 终端无颜色时仍有文字分隔。
- 宽度不足时按优先级隐藏第二行低频动作，不能截断控制序列名。
- 主快捷栏不显示导入源、配置凭据或完整路径。
- `Ctrl+R` 必须经过确认，避免误触导致断网。

### 2.2 配置表格

宽屏列顺序：

| 列 | 内容 | 最小宽度 | 降级规则 |
|---|---|---:|---|
| `S` | 光标/默认/运行/错误符号 | 4 | 永不隐藏 |
| `TYPE` | `VLESS`、`Hysteria2` 等 | 10 | 窄屏并入协议列 |
| `NAME` | basename 去掉 `.json` | 18 | 中间省略 |
| `ADDRESS` | primary outbound `server` | 20 | 窄屏隐藏；footer 显示选中项 |
| `PORT` | `server_port` | 5 | 永不隐藏 |
| `TRANSPORT` | `tcp`、`ws`、`quic` | 9 | 紧凑模式缩写 |
| `SECURITY` | `reality`、`tls`、`quic-tls` | 10 | 紧凑模式缩写 |
| `LATENCY` | `218 ms`、`…`、`timeout` | 9 | 永不隐藏 |
| `SPEED` | `2.1 MB/s`、`…`、`failed` | 10 | 极窄屏移入 footer |

表格行为：

- 光标整行高亮，不能只改变首字符。
- 默认、运行、选中是独立状态，可同时出现。
- Enter 设置默认后光标位置保持不变。
- 配置刷新时优先按 basename 保持选中项；目标消失才夹紧到最近行。
- 表格行数超过可见高度时维护 `scroll_offset`，光标始终在 viewport 内。
- 默认稳定排序为 `LC_ALL=C` basename；不自动按延迟重新排序。
- 地址按用户要求在本机主表显示，但任何提交的测试或截图只能使用合成地址。

### 2.3 日志面板

日志面板固定在表格下方：

- 默认占可用内容区 30%–35%。
- 默认读取 `NETUI_LOG_FILE`（core log）；按 `l` 在 core log 与 `NETUI_NETUI_LOG_FILE`（NetUI event log）之间切换，面板标题始终标明来源。
- 不合并两个文件，避免时间排序、重复和轮转语义不清；probe/import 事件显示在 footer/status，并写 NetUI event log。
- 每 500 ms–1 s 刷新一次，配置为较慢刷新以减少 SSH 闪烁。
- 默认自动滚动到末尾。
- 只显示可见行，不把整个日志读入内存。
- 记录当前 inode、size 和 offset；inode 改变或 size 小于 offset 时视为轮转/截断，从安全尾部重新建立窗口。
- 保留 partial line buffer，直到换行或达到单行上限；单行上限建议 4 KiB。
- 每行先剥离 ANSI/OSC/控制字符，再做宽度裁剪。
- 日志无内容时显示 `No runtime log yet`，不是空白框。
- 不把测速子进程原始 stderr 直接混进任一日志面板。

第一版不做日志搜索、复制和删除按钮；这些属于后续增强。

### 2.4 Footer

footer 固定两行：

```text
Default: office  Running: hk-ws  Selected: hk-ws  ⚠ restart required
Latency: 500 ms  Speed: 0.8 MB/s  Mode: CN whitelist  Local: mixed://127.0.0.1:10808
```

必须显示：

- 选中配置；
- 默认配置；
- 当前运行配置；
- 默认/运行是否一致；
- 选中配置最近延迟与速度；
- `global` / `cn-direct` / `off`；
- 当前有效状态 on/off；
- 本地 endpoint（若运行）。

footer 信息由模型计算，不在渲染函数内重复调用 tmux、jq 或网络命令。

## 3. 页面状态机

主状态：

```text
MAIN
IMPORT_INPUT
IMPORT_PREVIEW
IMPORT_COMMITTING
RESTART_CONFIRM
HELP
ERROR_MODAL
```

probe 不是页面，而是与 `tui_page` 正交的后台状态：`idle|starting|latency|speed|done|failed|cancelled`。测速时仍停留 MAIN，允许移动光标、看日志、切模式、刷新、帮助和退出；只禁止启动第二个 probe。结果始终写回启动时记录的 config hash/basename，而不是当前光标行。

转换规则：

- `MAIN + i -> IMPORT_INPUT`
- `IMPORT_INPUT + Enter -> parse -> IMPORT_PREVIEW | ERROR_MODAL`
- `IMPORT_INPUT + Esc -> MAIN`
- `IMPORT_PREVIEW + Enter -> IMPORT_COMMITTING -> atomic import -> MAIN`
- `IMPORT_PREVIEW + Esc -> MAIN`
- `IMPORT_COMMITTING + Esc -> cancel only before final rename`; rename 成功后提交已完成，不回滚成半状态
- `MAIN + Ctrl+R -> RESTART_CONFIRM`
- `RESTART_CONFIRM + Enter -> preflight/restart -> MAIN`
- `RESTART_CONFIRM + Esc -> MAIN`
- `MAIN + Ctrl+T -> start background probe and remain MAIN`
- `MAIN + Esc`：有 active probe 时取消 probe；否则清除临时提示
- `MAIN + ? -> HELP`
- `HELP + Esc/q/? -> MAIN`
- `MAIN + q -> cancel owned workers -> restore terminal -> exit`

任何 modal 打开时，主表快捷键不得穿透执行。

## 4. URI 输入框体验

`i` 打开的 modal 采用圆角覆盖层：

```text
╭─ Import share link ───────────────────────────────────────────╮
│ Paste one VLESS or Hysteria2 link, then press Enter.          │
│ Input: [pasted 286 bytes · credentials hidden]                │
│                                                              │
│ Enter parse/import                                      Esc cancel │
╰───────────────────────────────────────────────────────────────╯
```

要求：

- 启用 bracketed paste，整段粘贴作为一次输入事件处理。
- 不逐字符回显 UUID、密码、Reality public key 或完整 URI。
- 粘贴后显示 scheme、字节数和“credentials hidden”。
- 解析后预览只展示名称、地址、端口、协议、传输、安全模式和风险提示。
- Hysteria2 `insecure=1` 必须显示黄色/文字警告，但仍按用户要求支持导入。
- 输入上限默认 16 KiB；超限立即拒绝。
- 只接受一条单行链接；多行/多链接是后续功能。

## 5. 模式快捷键

直接语义：

- `Ctrl+↑`：`env_profiles_set_mode global`
- `Ctrl+↓`：`env_profiles_set_mode cn-direct`
- `o`：`env_profiles_set_mode off`

若目标模式已选中：

- 幂等成功；
- footer 短暂显示 `Mode already global`；
- 不重复写无意义 generation，除非现有业务函数明确要求。

兼容备用键：

- `g`/`G` 等价于全局；
- `w`/`W` 等价于大陆白名单；
- 仅在终端不能传递 Ctrl+方向键时使用；
- 顶部紧凑栏和 `?` 帮助都展示备用键；
- PTY、tmux 和 fallback 测试必须分别覆盖这些映射。

## 6. 响应式布局

### `>=120` 列

- 完整快捷栏；
- 完整表格列；
- 日志 30% 高度；
- footer 两行。

### `90–119` 列

- 隐藏 `TYPE` 或把其合并到 `PROTOCOL`；
- 地址列缩短；
- 速度仍保留；
- 快捷栏分两行。

### `70–89` 列

- 表格列：状态、名称、协议、端口、延迟；
- 地址和速度在 footer 展示；
- 日志保留至少 5 行；
- modal 占满内宽。

### `<70` 列或 `<20` 行

- 显示明确的紧凑模式；
- 列表仍支持上下移动、Enter、环境模式、重启、导入和退出；
- 日志可折叠为最后 2–3 行；
- 若低于绝对最小尺寸，提示调整终端而不是画破损边框。

### `TERM=dumb` / raw mode 失败

保留现有行式菜单 fallback：

- 功能完整但不实时刷新；
- 可选择配置、设默认、切模式、重启、导入和查看日志；
- 不假装支持 Ctrl+方向键。

## 7. 颜色与可访问性

推荐配色：

- 选中行：青色/蓝色反色；
- 默认：绿色 `★`；
- 运行：青色 `●`；
- 警告：黄色 `⚠`；
- 失败：红色 `×`；
- 测试中：黄色 `…`；
- footer：低对比背景但保持可读。

颜色只是增强：

- 每个状态必须同时有符号或文字；
- `NO_COLOR=1` 时全部功能和语义保留；
- 不依赖 emoji 宽度对齐，核心状态优先使用单宽 ASCII/Box Drawing 字符。

## 8. 视觉验收

- 顶部不再出现旧式 `Actions:` 菜单。
- 表头、选中行、日志分隔和 footer 与参考图的信息层级一致。
- 120、100、80、70 列均无边框断裂和列覆盖。
- 中文配置名、ASCII 名称、IPv4、域名和 IPv6 显示安全。
- 选中、默认、运行、失败和测速中可同时辨认。
- modal 不把底层主表误当成可操作焦点。
- 所有视觉 fixture 不含真实 URI、UUID、密码、公钥或用户提供地址。
