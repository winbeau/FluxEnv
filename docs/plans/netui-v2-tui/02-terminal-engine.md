# 02｜终端事件循环与渲染引擎

## 1. 当前差距

现有 `tui.sh` 使用：

```text
render dashboard -> gum/read action -> execute -> Press Enter -> repeat
```

这无法满足：

- 持久配置光标；
- 原地表格更新；
- 实时日志；
- 后台测速；
- Ctrl 组合键；
- Esc 取消 modal；
- resize 后保持状态。

新版需要一个状态驱动、单写者的全屏事件循环。

## 2. 文件与职责

建议：

```text
packages/netui/lib/tui_terminal.sh
packages/netui/lib/tui_render.sh
packages/netui/lib/tui.sh
```

### `tui_terminal.sh`

- 进入/退出 alternate screen；
- 保存/恢复 `stty`；
- 隐藏/显示光标；
- 启用/关闭 bracketed paste；
- 读取并归一化按键；
- 处理 `WINCH`；
- 终端 cell 宽度与控制字符清洗基础函数。

### `tui_render.sh`

- 计算布局；
- 渲染快捷栏、表格、日志、footer 和 modal；
- 截断/补齐列；
- 生成完整 frame 到变量/临时 buffer；
- 单次写到 stdout。

### `tui.sh`

- 维护模型；
- 调用配置/runtime/env/URI/probe 业务函数；
- 事件分发；
- 定时刷新；
- modal 状态；
- fallback。

## 3. TUI 模型

建议使用 Bash 全局变量和索引数组，避免引入数据库：

```text
tui_page
selected_index
scroll_offset
terminal_rows
terminal_cols
needs_redraw
last_log_offset
status_message
status_level
status_deadline
probe_run_id
probe_state
```

每个配置的 session 缓存：

```text
config_paths[index]
config_names[index]
config_hashes[index]
config_types[index]
config_servers[index]
config_ports[index]
config_transports[index]
config_security[index]
config_valid[index]
config_latency[index]
config_speed[index]
config_probe_state[index]
```

原则：

- 渲染函数只能读取模型；
- 渲染时不执行 `jq`、`sing-box check`、tmux 或网络命令；
- 模型刷新负责昂贵操作，并有缓存和 dirty 标记；
- 后台 worker 不直接写 stdout。

## 4. 终端进入与恢复

进入顺序：

1. 验证 stdin/stdout 是 TTY。
2. 保存 `stty -g` 输出。
3. 安装 `EXIT HUP INT TERM WINCH` trap。
4. 进入 alternate screen。
5. 隐藏光标。
6. 启用 bracketed paste。
7. 关闭 canonical mode 和 echo，保留信号处理策略。
8. 首次读取尺寸并渲染。

恢复顺序必须幂等：

1. 取消/等待自有 probe worker。
2. 关闭 bracketed paste。
3. 恢复保存的 `stty`。
4. 显示光标。
5. 退出 alternate screen。
6. 清除 trap。
7. 输出必要的最终错误到正常屏幕。

`restore` 需要防重入标记，避免 `EXIT` 与 `INT` 同时执行两次。

## 5. 按键归一化

`tui_read_key` 返回逻辑 token，而不是原始字节：

```text
UP
DOWN
ENTER
ESC
CTRL_UP
CTRL_DOWN
CTRL_R
CTRL_T
IMPORT
MODE_GLOBAL
MODE_WHITELIST
MODE_OFF
LOG_SOURCE
REFRESH
HELP
QUIT
PASTE_START
PASTE_END
TEXT:<bytes>
UNKNOWN
TICK
```

### 已知控制字节

- Enter：CR 或 LF；
- `Ctrl+R`：`0x12`；
- `Ctrl+T`：`0x14`；
- `Ctrl+O` 若未来启用：`0x0f`；
- Esc：`0x1b`；
- `g/G` -> `MODE_GLOBAL`，`w/W` -> `MODE_WHITELIST`；
- `i/I`、`o/O`、`l/L`、`r/R`、`q/Q` 均归一化为同一动作 token。

### 方向键

普通：

```text
ESC [ A
ESC [ B
ESC O A
ESC O B
```

Ctrl 修饰常见形式：

```text
ESC [ 1 ; 5 A
ESC [ 1 ; 5 B
ESC [ 5 A
ESC [ 5 B
```

实现只接受明确白名单，不把未知 CSI 当 shell 文本执行。

### Esc 歧义

Esc 是独立取消键，也是所有 escape sequence 前缀。

计划：

- 读到 `0x1b` 后进行短超时读取，默认 50 ms；
- 超时无后续字节则返回 `ESC`；
- 有后续字节则继续匹配完整序列；
- 超时可通过测试环境变量调整；
- 不使用无限等待，避免 SSH 下 Esc 卡住。

## 6. Bracketed paste

进入 TUI 时发送启用序列；modal 中识别：

```text
ESC [ 200 ~   # paste start
ESC [ 201 ~   # paste end
```

规则：

- 只有 `IMPORT_INPUT` 接受 paste payload；
- 主界面收到 paste 时忽略并提示 `Press i before pasting`；
- payload 按原始字节累计，不解释按键；
- 最大 16 KiB；
- 拒绝 NUL、CR、LF、控制字符和多链接；
- 完成后只显示字节数和 scheme，不回显秘密；
- 未支持 bracketed paste 的终端仍允许逐字符输入，但同样不回显内容。

## 7. 事件循环

概念顺序：

```text
initialize model
enter terminal
while running:
    now = monotonic-ish clock
    poll probe result files
    poll bounded config-validation worker results
    refresh selected log source tail if deadline reached
    refresh runtime/env state if deadline reached
    redraw if dirty or resize
    key = read with bounded timeout
    dispatch key for current page
restore terminal
```

刷新频率：

- 按键：立即；
- 日志：500–1000 ms；
- runtime/env：1000 ms；
- 配置目录：手动 `r`，动作完成后，以及低频 2–5 s stat 检查；
- JSON metadata 立即计算；`sing-box check` 进入最多 2 个 worker 的有界队列，每项有 timeout，慢检查不能阻塞事件循环；
- probe 状态：100–250 ms；
- 无变化不重绘。

不能使用无上限 busy loop。

## 8. 单写者模型

所有终端输出都由主事件循环发出：

- `runtime_start/stop`、`env_profiles_set_mode` 等现有函数会打印消息；TUI 调用时应捕获 stdout/stderr 到私有临时文件或变量。
- 将结果转换为 `status_message` 和必要的脱敏日志事件。
- config validation worker 与 probe worker 都写原子结果文件，并由主循环转换状态；退出时按各自 PID/token 清理。
- probe worker 只写结果 JSON，不碰 stdout/stderr 主 TTY。
- URI parser 错误只返回错误代码和值无关的错误标识。

这样避免后台消息把表格光标推乱。

## 9. Frame 渲染

每次 redraw：

1. 读取已计算的 terminal rows/cols。
2. 计算各区域高度与列宽。
3. 渲染到私有 frame buffer。
4. 把用户可控字符串先清洗，再裁剪到 cell 宽度。
5. 使用 home/clear-to-end 或等价序列一次性输出 frame。
6. 不逐行 `clear`，减少闪烁。

对日志和配置名必须移除：

- C0/C1 控制字符；
- ESC/CSI/OSC；
- carriage return；
- tab 转固定空格；
- 过长内容。

## 10. 终端宽度

Bash `${#text}` 不是可靠 cell width。

MVP 策略：

- ASCII 表格字段按字节安全裁剪；
- 中文名称允许显示，但使用单独的 `tui_cell_width` helper；
- 优先调用可用的 `wcwidth` 实现仅当它是包内或已明确依赖；
- 不新增 Python 作为 TUI 强依赖；
- 若无法可靠判断，保守把非 ASCII 视作 2 cells；
- 测试覆盖中文、组合字符和 emoji，emoji 可降级为 `?`，核心边框不能错位。

## 11. Resize

`WINCH` trap 只设置 `resize_pending=1`，不直接渲染。

主循环处理：

- 重读 rows/cols；
- 重新计算表格可见行；
- clamp `selected_index`；
- 调整 `scroll_offset`；
- modal 重新居中；
- 标记 redraw。

## 12. 业务动作映射

- Enter：调用 `config_store_set_default selected_path`。
- Ctrl+↑ 或 `g/G`：调用 `env_profiles_set_mode global`。
- Ctrl+↓ 或 `w/W`：调用 `env_profiles_set_mode cn-direct`。
- Ctrl+R：进入确认状态；确认后调用新的安全 helper `runtime_restart_default_safe`：先在旧实例仍运行时重新校验 default、endpoint 和端口，再停止；启动新 default 失败时用已捕获且仍有效的旧运行配置做一次 best-effort rollback。
- Ctrl+T：调用 `probes_start_for_config selected_path`，保持 MAIN 页面可操作；active probe 时再次触发只提示，不覆盖任务。
- `i/I`：进入 URI modal。
- `l/L`：在 core log 与 NetUI event log 间切换，并重置该来源的安全 tail cursor。
- `r/R`：重新 discover、meta 和当前日志源，不启动网络测试。
- `o/O`：环境模式 off。
- `q/Q`：取消自有 worker 后退出；运行实例保持。

安全重启的失败语义：

- default 预检失败：旧实例保持，不调用 stop；
- stop 后新 default 启动失败：尝试以旧 snapshot/path 恢复旧配置；
- rollback 成功：footer 显示“new default failed; previous runtime restored”；
- rollback 失败：明确显示两个失败，不虚假宣称运行；
- 测试覆盖 invalid default 不停旧实例和 post-stop failure rollback。

动作结束后：

- 刷新 default/runtime/env 模型；
- 保持选中 basename；
- 显示 2–4 秒状态消息；
- 失败不得吞掉真实退出码。

## 13. Fallback

继续保留旧的行式界面，但调整文案和动作：

- 配置编号选择；
- 设置默认；
- 重启；
- global/cn-direct/off；
- URI 导入；
- 选中配置测速；
- 最近日志；
- 退出。

fallback 可以调用相同业务模块，不能维护第二套 URI mapping 或 probe 逻辑。

## 14. 测试接口

保留并扩展：

```text
NETUI_TUI_ACTIONS
NETUI_TUI_TEST_KEYS
NETUI_TUI_FIXED_ROWS
NETUI_TUI_FIXED_COLS
NETUI_TUI_DISABLE_ALT_SCREEN
NETUI_TUI_ESC_TIMEOUT_MS
```

其中：

- `NETUI_TUI_ACTIONS` 测业务动作；
- PTY/VHS 测真实按键；
- 固定尺寸和禁用 alternate screen 只用于确定性测试；
- 生产环境默认不能被不安全测试值改变文件根目录或跳过校验。

## 15. 验收

- 所有退出路径恢复终端。
- 长按方向键不会高 CPU 或越界。
- Ctrl+方向键在 xterm、tmux、VHS 和常见 SSH 终端识别。
- 单独 Esc 取消 modal，箭头不会被误判为 Esc。
- 粘贴 URI 时其中字符不会触发主界面动作。
- probe/runtime 输出不会覆盖表格。
- resize 后表格、日志和 footer 仍闭合。
