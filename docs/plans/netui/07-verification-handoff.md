# 07｜验证、视觉回归、发布门禁与下一对话交接

## 1. 实施顺序

下一次对话按以下顺序工作；不要先碰 h100 或 GitCode Release：

1. 建立 `packages/netui` 骨架、路径常量和 `netctl` 命令分派。
2. 用临时 HOME 实现并测试配置发现、两级校验和默认 symlink 原子切换。
3. 实现 tmux runtime、`netup`、`netdown` 和运行快照。
4. 实现环境 profile、generation、bash/zsh prompt hook 与 tmux environment 同步。
5. 实现大量圆角矩形的 gum TUI 与圆角 ANSI fallback。
6. 建立 VHS 脚本化视觉测试，生成 MP4/PNG 并完成圆角、宽度、环境模式截图验收。
7. 实现 clone installer、版本目录、升级/回滚/卸载。
8. 实现 legacy migration，重点解决旧 shell function/环境逻辑遮蔽。
9. 锁定官方资产并构建本地 Release tarball。
10. 在测试机完成端到端验证。
11. 验证 GitCode Release URL 并发布测试版。
12. 最后才在 h100 做迁移演练和切换。

## 2. 预计新增/修改文件

建议新增：

```text
packages/netui/bin/netctl
packages/netui/lib/common.sh
packages/netui/lib/paths.sh
packages/netui/lib/config_store.sh
packages/netui/lib/runtime_tmux.sh
packages/netui/lib/env_profiles.sh
packages/netui/lib/shell_integration.sh
packages/netui/lib/tui.sh
packages/netui/lib/migrate.sh
packages/netui/lib/install_core.sh
packages/netui/scripts/build-release.sh
packages/netui/examples/config.example.json
packages/netui/install.sh
packages/netui/bootstrap.sh
packages/netui/manifest.lock
packages/netui/VERSION
packages/netui/README.md
packages/netui/THIRD_PARTY_NOTICES.md
docs/NETUI.md
tests/netui/run.sh
tests/netui/vhs/dashboard.tape
tests/netui/vhs/config-switch.tape
tests/netui/vhs/env-modes.tape
tests/netui/vhs/narrow.tape
tests/netui/vhs/fallback.tape
tests/netui/visual/run.sh
tests/netui/visual/baseline/*.png
```

可能修改：

```text
README.md
.gitignore                  # 忽略 artifacts/netui 录屏和截图产物
```

不要把真实配置放进 `tests/`。fixture 应从零编写，使用无效示例端点和占位凭据。

## 3. 静态检查

仓库最低要求：

```bash
bash -n scripts/fluxenv lib/*.sh lib/steps/*.sh scripts/fetch_resources.sh
bash -n packages/netui/bin/netctl packages/netui/install.sh packages/netui/bootstrap.sh packages/netui/lib/*.sh packages/netui/scripts/*.sh
dash -n packages/netui/bootstrap.sh
```

如有 shellcheck：

```bash
shellcheck packages/netui/bin/netctl packages/netui/install.sh packages/netui/lib/*.sh packages/netui/scripts/*.sh
shellcheck -s sh packages/netui/bootstrap.sh
```

补充检查：

- 所有运行脚本使用 `#!/bin/bash`；bootstrap 正文保持 POSIX 子集，以便 shebang 被 pipe 忽略时仍可由 `sh` 执行。
- 4 空格缩进。
- 变量和函数为 lowercase snake_case。
- 所有危险路径删除前验证非空且位于预期根目录。
- 没有 `eval`、未引用变量、宽泛 `pkill`、未校验的 tar 解包。

## 4. 自动化目标测试

`tests/netui/run.sh` 使用临时 HOME 和 fake binary，优先覆盖真正可能回归的行为，不写只复述实现的测试。

### 4.1 配置模型

- 空目录无默认。
- 创建两个有效 fixture 后全部可发现。
- 设置默认生成相对 symlink。
- 默认替换原子且不留下临时链接。
- 外部 symlink/路径穿越被拒绝。
- 坏 JSON 和 sing-box check 失败不能设默认。
- 文件名含空格和中文仍安全。

### 4.2 命令契约

- `netup` 无默认时 exit 4。
- `netup` 永远读取 default，不接受 positional config。
- 重复 `netup` 不创建第二实例。
- `netdown` 未运行时幂等成功。
- `netdown` 不杀 fake 的非 NetUI sing-box 进程。
- 用户自建同名 tmux 会话但无 NetUI token 时，netup/netdown 拒绝操作且会话保持不变。
- state token、tmux option、pane PID/starttime 或核心路径任一不匹配时拒绝停止，覆盖 stale state/PID 复用场景。
- 无 tmux 会话但有 stale endpoint/state 时，netdown 仍清理 state、tmux env、更新 generation 后幂等成功。
- 默认在运行中改变后，运行快照仍指向旧配置。

### 4.3 安装

- 新装创建版本目录和三个 symlink。
- 同版本重装幂等。
- checksum 失败不切换 current。
- 新版本默认配置不兼容时不切换。
- 回滚恢复上一个 current。
- 默认卸载保留 configs。
- purge 需要明确确认。

### 4.4 迁移

- 扫描 `config.json*`，只导入有效普通文件。
- 文件名与协议不一致时按内容展示，不误命名协议。
- 旧 active `config.json` 映射为默认。
- 配置 mode 为 600。
- 旧目录保持原样。
- 精确识别 rc source 行并生成备份。
- 检测旧 `netup/netdown` function 遮蔽并输出新 shell 提示。

### 4.5 环境模式

- 全局模式精确生成 `localhost,127.0.0.1,::1`，大小写变量一致。
- 大陆白名单模式去重、无空白/换行、长度 `<=512` bytes，当前设计值为 288 bytes。
- `.cn` 覆盖清华/中科大/北外/上交镜像，华为/阿里/腾讯/npmmirror 后缀存在。
- mode/generation 原子更新，非法枚举被拒绝。
- netup 后 endpoint 有效，prompt hook 应用；netdown 后 hook 撤销有效变量但保留 preference。
- Bash `PROMPT_COMMAND` 与 Zsh `precmd` 原有 hook 不被覆盖、重复 source 不重复注册。
- mode=off 且 `NETUI_ENV_OWNED` 不存在时，不清除用户自己设置的代理。
- sing-box fake 进程收到的环境中不存在 proxy/no_proxy。
- tmux 新 pane 继承有效模式，已有 pane 在下一 prompt 同步。

## 5. VHS 脚本化 TUI 视觉测试

### 5.1 工具选择与现状

采用 Charmbracelet **VHS** 作为类似 Playwright 的 TUI E2E 驱动：Tape 文件固定 shell、viewport、字体、按键、等待和输出；使用 tmux capture/bash 断言补足 DOM 类状态断言。

当前开发环境已确认：

```text
/usr/bin/vhs      v0.11.0
/usr/bin/ffmpeg   available
/usr/bin/compare  available (ImageMagick)
/mnt/c/Users/genev/Desktop/ exists and writable
```

本轮还用临时 Tape 实测了 Unicode 圆角框 → VHS MP4 → ffmpeg PNG 的完整 smoke pipeline，成功生成 `800x400` PNG；临时产物已清理，没有冒充最终 UI 截图。

因此下一次实现不需要先安装视觉测试工具。若这些工具届时缺失，按环境约束停止并报告，不用任意下载脚本绕过。

### 5.2 Tape 场景

- `dashboard.tape`：120 列主界面，三份配置、默认/运行不一致、环境状态卡。
- `config-switch.tape`：圆角“设为默认”确认框和重启选择。
- `env-modes.tape`：全局/大陆白名单/off 三选一圆角 modal，以及退出后的 shell 环境证明。
- `narrow.tape`：80 列和 70 列布局降级，边框不折断。
- `fallback.tape`：禁用 bundled gum，检查纯 ANSI 圆角界面。

Tape 固定脱敏 fixture、终端尺寸、主题和不含动态时间/PID的测试模式，使截图可比较。

### 5.3 圆角视觉断言

- 外层应用框、三个顶部状态卡、配置列表、详情面板、footer 和 modal 使用 `╭╮╰╯`/gum rounded border。
- 圆角闭合，无多一列/少一列、CJK 字宽错位或边框换行。
- 宽屏双栏、窄屏上下布局均无内容溢出。
- 默认、运行、错误、环境模式不仅靠颜色区分。
- 主屏只显示 `no_proxy` 模式和字节数，不铺满 288-byte 列表。
- 任何截图都不得出现真实 endpoint、password、UUID 或 key。

### 5.4 生成 PNG 与视觉 diff

VHS v0.11 输出 MP4/GIF/WebM，使用 ffmpeg 从稳定帧提取 PNG：

```bash
vhs validate 'tests/netui/vhs/*.tape'
vhs tests/netui/vhs/dashboard.tape
ffmpeg -y -ss 00:00:04 -i artifacts/netui/dashboard.mp4 \
    -frames:v 1 artifacts/netui/netui-dashboard.png
```

ImageMagick 作为实际视觉门禁，而不是只安装不用：

```bash
compare -metric AE \
    tests/netui/visual/baseline/netui-dashboard.png \
    artifacts/netui/netui-dashboard.png \
    artifacts/netui/netui-dashboard-diff.png
```

规则：

- 首次 v0.1.0 由人工审核 Desktop PNG 后，以显式 `UPDATE_VISUAL_BASELINE=1` 建立基线；不得静默接受当前输出。
- 后续运行缺少基线、图片尺寸不同或 AE 超过场景阈值时失败，并保留 diff PNG。
- viewport、字体、主题、fixture、时间和 PID 均固定；阈值记录在测试脚本/场景清单，不用一个宽松全局值掩盖错位。
- 像素 diff 是视觉回归门禁，tmux capture/bash 文本与状态断言仍必须同时通过。

### 5.5 复制到 Windows 桌面

视觉验收通过后，将代表性 PNG 复制到用户指定目录：

```bash
cp -f artifacts/netui/netui-dashboard.png \
    /mnt/c/Users/genev/Desktop/netui-dashboard.png
cp -f artifacts/netui/netui-config-switch.png \
    /mnt/c/Users/genev/Desktop/netui-config-switch.png
cp -f artifacts/netui/netui-env-modes.png \
    /mnt/c/Users/genev/Desktop/netui-env-modes.png
cp -f artifacts/netui/netui-narrow.png \
    /mnt/c/Users/genev/Desktop/netui-narrow.png
```

复制前检查目标目录存在且可写；失败应报告，不能假装截图已交付。MP4、actual PNG 和 diff PNG 放在 gitignored `artifacts/netui/`；只有经过人工批准的 `tests/netui/visual/baseline/*.png` 作为视觉测试 fixture 提交。

## 6. 手工测试矩阵

### 必测平台

| 场景 | 优先级 |
|---|---|
| Ubuntu 24.04 amd64，普通用户 | P0 |
| Ubuntu 24.04 amd64，root HOME | P0，与 h100 对齐 |
| Ubuntu 22.04 或 Debian 12 amd64 | P1 |
| Linux arm64 | P1；若首发 arm64 则升为 P0 |

### 必测安装路径

- clone 仓库后安装。
- 本地 Release tarball 安装。
- GitCode 公开 URL 的真实 `curl | sh`，不是仅用 bash 代测。
- 重复安装。
- 从 v0.1.0 升级到测试 v0.1.1，再回滚。
- 默认卸载和 purge。

### 必测 TUI

- gum 主界面。
- 人为移除 gum 后的 fallback。
- 70 列窄终端。
- SSH/tmux 终端。
- Ctrl-C 后终端光标和输入状态恢复。
- 默认/运行不一致提示。
- 配置导入、重命名、归档与恢复。

## 7. h100 验收脚本场景

仓库指南要求这类脚本只在测试机运行；h100 若为生产/工作机，先做临时 HOME 演练：

```bash
NETUI_TEST_HOME="$(mktemp -d)"
HOME="$NETUI_TEST_HOME" bash packages/netui/install.sh --asset-dir <verified-assets>
```

真实迁移前再做：

1. 确认旧代理停止。
2. 备份 rc 与 `~/sb` 文件清单。
3. 运行 migration dry-run，检查映射，不输出秘密。
4. 真实复制配置并校验。
5. 新登录 shell 后验证命令解析。
6. `netui` 应显示三份配置：一个 Hysteria2、两个 VLESS/REALITY。
7. 默认应对应旧 `~/sb/config.json`。
8. `netup` 启动默认配置，监听配置声明的本地端口。
9. 在 TUI 将另一个配置设为默认，不重启；确认 running/default 差异。
10. 执行重启后确认运行项切换。
11. 在 TUI 依次选择全局与大陆白名单，退出后检查当前 shell 的大小写变量及 no_proxy 长度。
12. `netdown` 后确认 NetUI 会话消失、环境有效值在下一 prompt 撤销、其他进程不受影响。
13. 运行 VHS h100-like 脱敏 fixture tape，截图复制到 Windows Desktop；不对真实配置录屏。

## 8. 端到端验收清单

### CLI

- [ ] `netup`、`netdown`、`netui` 均来自 `~/.local/bin`。
- [ ] 不再被旧 shell function 遮蔽。
- [ ] `netup` 只启动 default。
- [ ] `netdown` 幂等且只停止受管实例。
- [ ] 错误退出码和消息明确。

### 配置

- [ ] 所有 `*.json` 自动出现。
- [ ] 协议按内容识别。
- [ ] 无效配置可见但不可设为默认。
- [ ] 默认 symlink 不可逃逸 config dir。
- [ ] JSON mode 600。
- [ ] 默认与运行配置差异可见。

### 环境

- [ ] 全局模式 no_proxy 仅 loopback。
- [ ] 大陆白名单覆盖指定镜像/站点且不超过 512 bytes。
- [ ] TUI 退出后父 shell、新 shell、新 tmux pane 按规则同步。
- [ ] netdown 撤销有效值但保留 preference，netup 后恢复。
- [ ] sing-box 不继承代理变量。

### TUI

- [ ] gum 界面大量使用有层级的圆角矩形且不显拥挤。
- [ ] fallback 功能完整并保留圆角边框字符。
- [ ] 危险动作需圆角确认 modal。
- [ ] 不显示认证秘密。
- [ ] Ctrl-C/resize 行为正常。
- [ ] VHS Tape 全部通过，tmux/bash 状态断言通过。
- [ ] ImageMagick baseline/dimension/AE 门禁通过并在失败时生成 diff PNG。
- [ ] 代表性 PNG 已复制到 `/mnt/c/Users/genev/Desktop/`。

### 安装与发布

- [ ] clone/Release 安装行为一致。
- [ ] 二进制来自锁定上游资产。
- [ ] checksum 失败安全终止。
- [ ] 升级失败不破坏 current。
- [ ] Release 无真实配置/凭据。
- [ ] GitCode URL 经实际验证。
- [ ] 许可证与第三方说明完整。

## 9. 停止条件

出现以下任一情况，实施应停止而不是猜测或强行继续：

- GitCode Release URL/API 尚未验证，却准备发布 README 安装命令。
- 找不到官方资产 checksum 或来源无法确认。
- Release staging 命中真实配置、分享链接、密码、UUID 或 key。
- legacy 实例正在运行或端口被未知进程占用。
- 新 sing-box 版本无法校验现有默认配置。
- migration 无法唯一识别旧 source 行，可能误改 rc。
- `current`/配置路径解析超出预期 XDG 根目录。
- shell hook 会覆盖既有 PROMPT_COMMAND/precmd，或无法证明环境所有权边界。
- 大陆白名单超过 512 bytes、包含重复/换行，或镜像覆盖测试不通过。
- VHS/ffmpeg 不可用、Tape 失败、圆角错位，或 Desktop 截图复制失败，却准备宣称视觉验收完成。
- h100 未被确认可以作为迁移测试目标。

## 10. 下一次对话可直接使用的任务描述

```text
按 docs/plans/netui/README.md 及 01-07 子计划开始实现 NetUI。先完成 M0-M2：packages/netui 骨架、默认 JSON 原子模型、tmux runtime、netup/netdown、持久环境 profile/shell hook，以及大量圆角矩形的 gum + Bash fallback netui。使用临时 HOME 和脱敏 fixture；用 VHS v0.11.0 + tmux 进行脚本化 TUI E2E，ffmpeg 提取 PNG，并把验收截图复制到 /mnt/c/Users/genev/Desktop/。不修改 h100，不发布 Release。严格保持：netup 只启用默认 JSON，netui 管理所有 *.json、默认项和全局/大陆白名单/off 环境状态。
```

## 11. 本轮交接状态

- 已完成 h100 只读调研。
- 已确认用户最终命令语义。
- 已完成架构与发布安全评审。
- 本轮只新增计划文档，不包含实现代码、远端修改、commit、push、tag 或 Release。
