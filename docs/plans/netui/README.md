# NetUI sing-box 配置管理包实施总计划

> 状态：**仅完成调研与计划，尚未实现**
> 计划日期：2026-08-24
> 目标仓库：`FluxEnv`
> GitCode 开发远程：`gc -> git@gitcode.com:winbeau/FluxEnv.git`

## 1. 已锁定的产品契约

本计划以后续实现必须保持的用户语义为准：

- `netup`：基础 CLI 命令，只启动“默认 JSON 配置”。
- `netdown`：基础 CLI 命令，停止 NetUI 管理的当前 sing-box 实例。
- `netui`：进入美观的 TUI，发现并展示配置目录下的全部 `*.json`，管理这些配置并设置默认项。
- `netui` 还负责选择持久环境模式：`全局代理`、`大陆白名单直连`、`关闭环境变量`；退出 TUI 回到 shell 后仍需生效。
- `netup` 不接受临时配置参数绕开默认项；要切换配置，先在 `netui` 中设置默认，再执行 `netup` 或在 TUI 中确认重启。
- 默认配置改变时，不静默替换正在运行的配置；TUI 必须同时展示“默认配置”和“当前运行配置”。
- 三个命令是安装到 `PATH` 的真实可执行命令，不再依赖旧 shell function；bash/zsh 只安装轻量 prompt hook，用于把 TUI 持久状态同步回父 shell。
- sing-box 进程只由 tmux 常驻托管，不使用 systemd、systemd-user、nohup 或其他守护方式。
- 支持两种安装入口，但两者必须调用同一套安装核心：
  1. GitCode Release 的版本固定 `curl | sh`；
  2. clone 仓库后运行仓库内安装脚本。

## 2. 调研结论摘要

对 `h100-server:~/sb` 的只读调研确认：

- 主机为 Ubuntu 24.04.1 LTS、`x86_64`，当前使用者为 `root`。
- `~/sb` 不是 Git 工作树，现有二进制没有可验证的仓库来源。
- sing-box 为 `1.12.0`，当前目录同时包含一个 Hysteria2 配置和两个 VLESS + REALITY 配置，三份配置均通过现有二进制的 `sing-box check`。
- 三份配置都提供 `mixed` 入站，监听 `127.0.0.1:10808`；当前没有运行实例、tmux 会话或自启动项。
- 现有 `sbctl` 用 tmux 管理进程；`env.sh` 提供 `netup/netdown` shell function，并由 `.bashrc`、`.zshrc` source。
- 这些旧 function 会优先于 `~/.local/bin/netup`，是迁移时必须处理的 P0 冲突。
- 配置文件含真实凭据，当前 mode 为 `644`，但 `/root` 为 `700`；新包仍应统一收紧为 `600`。
- 文件名不能代表协议：`config.json.hy2` 的实际 outbound 是 VLESS + REALITY，因此新 TUI 必须按 JSON 内容识别，而不是按文件名猜测。

完整盘点见 [01-current-state.md](./01-current-state.md)。计划文档没有记录任何密码、UUID、密钥或真实服务端地址。

## 3. 总体架构决策

### 3.1 组件边界

NetUI 作为 FluxEnv 内可独立发布、可独立安装的子包，不并入 `scripts/fluxenv` 的整机初始化步骤：

```text
packages/netui/
├── bin/netctl                 # 唯一命令核心，按 argv[0] 分派 netup/netdown/netui
├── lib/                       # 路径、配置、运行时、TUI、迁移模块
├── install.sh                 # clone 与解包后的统一安装核心
├── bootstrap.sh               # curl | sh 的薄下载器模板
├── scripts/build-release.sh   # 构建 Release 资产
├── manifest.lock              # sing-box、gum 版本/URL/SHA256/许可证
├── VERSION
├── README.md
└── examples/                  # 仅脱敏模板
```

### 3.2 用户侧布局

采用 XDG 用户态目录，不要求 root：

```text
~/.local/bin/netup
~/.local/bin/netdown
~/.local/bin/netui
~/.local/share/netui/releases/<version>/
~/.local/share/netui/current -> releases/<version>
~/.config/netui/configs/*.json
~/.config/netui/default.json -> configs/<name>.json
~/.config/netui/env-mode
~/.local/state/netui/runtime/env-generation
~/.local/state/netui/logs/
~/.local/state/netui/runtime/
~/.local/state/netui/backups/
```

配置、运行状态和程序版本分离，升级程序不得覆盖用户 JSON。

### 3.3 技术选择

- 核心与 `netup/netdown`：Bash 4+。
- 生命周期后端：MVP 只使用 tmux，保持与 h100 现状一致；明确不使用 systemd/nohup。
- TUI：发布包内固定版本的 `gum` 作为主界面，广泛使用有层级的圆角矩形；纯 Bash/ANSI 编号菜单作为降级路径并保留圆角框字符。
- 环境持久化：TUI 写入固定枚举的 mode/state，bash/zsh prompt hook 在返回提示符时加载，tmux global environment 供未来 pane/window 继承。
- 环境 profile：全局模式的 `no_proxy` 仅含 loopback；大陆白名单模式使用受控、去重且不超过 512 bytes 的域名后缀列表。
- 视觉 E2E：使用已安装的 VHS v0.11.0 脚本化驱动按键和固定 viewport，ffmpeg 提取 PNG，ImageMagick compare 执行 baseline/dimension/AE 视觉门禁。
- JSON 摘要：`jq`。
- sing-box：从官方固定版本资产获取并校验，绝不直接发布 h100 上复制来的二进制。
- 默认配置：受限、原子更新的 `default.json` 符号链接；配置目录本身是唯一事实来源，不引入数据库。
- 单实例：每个 Unix 用户一个 NetUI tmux 会话；通过 `flock` 串行化启动、停止、默认项切换和升级。
- 自启动：MVP 不默认开启，也不在首次迁移时改变 h100 当前“手动启动”的行为。

## 4. 计划索引

1. [现状审计与迁移约束](./01-current-state.md)
2. [命令契约、目录模型与运行时](./02-command-runtime.md)
3. [TUI 与 JSON 配置管理](./03-tui-config-management.md)
4. [持久代理环境模式与 shell/tmux 同步](./04-environment-profiles.md)
5. [安装、升级、卸载与旧目录迁移](./05-install-migration.md)
6. [GitCode Release 与供应链](./06-release-gitcode.md)
7. [验证、发布门禁与下一对话交接](./07-verification-handoff.md)

## 5. 实施里程碑

### M0：建立包骨架与锁定清单

- 新建 `packages/netui/`，确定版本、目录常量和 manifest 格式。
- 锁定官方 sing-box 与 gum 的 Linux `amd64`/`arm64` 资产及 SHA256。
- 建立一个内部 `netctl`，安装时用三个命令名调用同一核心。
- 先完成 `--help`、`--version`、路径解析和依赖诊断。

### M1：完成默认配置与基础 CLI

- 枚举 `~/.config/netui/configs/*.json`。
- 原子设置、读取和校验 `default.json`。
- 实现 tmux 单实例、锁、日志与运行快照。
- 完成 `netup` 和 `netdown`；保证 `netup` 只启动默认配置。

### M2：完成 netui TUI 与环境模式

- 展示所有 JSON、默认标记、运行标记、协议、监听端口、校验状态和修改时间。
- 支持设置默认、校验、启动、停止、重启、日志、刷新和安全详情查看。
- 支持全局代理、大陆白名单直连和关闭环境变量；展示持久选择与当前有效状态。
- 外层、状态卡、配置列表、详情、footer 和 modal 使用圆角矩形，并提供宽/窄终端布局。
- 增加导入、重命名、归档等配置管理动作；危险动作需确认并可恢复。
- gum 不可用或非完整终端时进入功能等价的降级菜单。

### M3：完成安装与 h100 迁移

- clone 安装和 Release 解包安装复用 `packages/netui/install.sh`。
- 版本目录 + `current` symlink 原子安装，支持升级和回滚。
- 从旧 `~/sb` 复制而非移动配置，按内容识别协议并将旧 `config.json` 映射为默认配置。
- 处理 `.bashrc`/`.zshrc` 对 `~/sb/env.sh` 的 source，避免旧 function 遮蔽新命令。
- 安装幂等的 bash/zsh prompt hook，使模式切换在 TUI 退出后的当前 shell 及新 shell 中持续生效。
- 保留原目录，不复用来源不明的旧 sing-box 二进制。

### M4：构建 GitCode Release

- 为 `amd64`、`arm64` 构建带 sing-box/gum 的架构包。
- 产出 `SHA256SUMS`、版本固定 bootstrap、许可证与来源说明。
- 做秘密扫描、归档内容检查、干净环境解包安装检查。
- 推送 `main` 与 tag 到 `gc`，在 GitCode 创建 Release 并上传资产。
- 在真正发布安装命令前，实测 GitCode 的公开永久下载 URL、重定向和无登录下载行为。

### M5：测试机验证与 h100 切换

- 先在一次性 Ubuntu 24.04 测试环境完成 clone、Release、升级、回滚、卸载测试。
- 运行 VHS Tape 覆盖主屏、配置切换、环境模式、窄屏和 fallback；将代表性 PNG 复制到 `/mnt/c/Users/genev/Desktop/`。
- 再在 h100 使用临时 HOME 或 dry-run 做无侵入演练。
- 只有备份、配置校验和命令遮蔽处理全部通过后，才执行真实迁移和启动。

## 6. 第一版范围

### 必须交付

- `netup`、`netdown`、`netui` 三个命令。
- 目录中所有 `*.json` 自动发现。
- 默认配置设置与持久化。
- 默认配置和运行配置差异可见。
- sing-box 配置校验。
- tmux 单实例启停、日志和失败诊断；不创建 systemd/nohup 后端。
- 两套代理环境 profile：全局 loopback-only `no_proxy` 与 `<=512` bytes 的大陆白名单 `no_proxy`，另有关闭状态。
- TUI 退出后当前 bash/zsh 继续保持所选环境，新 shell 和新 tmux pane 可继承。
- 圆角主界面与 modal 的 VHS 自动化视觉测试、PNG 截图和 Windows Desktop 交付。
- h100 旧 `~/sb` 安全迁移。
- clone 安装、版本固定 Release 安装、checksum 校验。
- amd64；若上游资产和测试条件齐备，同一首发同时提供 arm64。

### 明确不做

- Web 面板、远程 API、数据库或订阅转换平台。
- 透明代理、TUN、路由、防火墙自动管理。
- 多实例并行运行多个配置。
- systemd、systemd-user、nohup、screen 等额外生命周期后端。
- 在 TUI 中展示密码、UUID、Reality key 或完整分享链接。
- 将 h100 的真实配置、日志或旧二进制提交到仓库/Release。
- 将 GitCode remote `gc` 写入用户运行时逻辑。

## 7. 完成定义

只有同时满足以下条件，第一版才算完成：

1. `netui` 能看到迁移后的三份 JSON，并准确按内容显示一个 Hysteria2、两个 VLESS + REALITY。
2. 任意配置可设为默认，`default.json` 更新是原子的，坏链接会被拒绝。
3. `netup` 只使用默认配置，启动前必做校验；重复执行不产生第二个实例。
4. 默认配置在运行中被修改时，当前实例不被静默替换，TUI 明确提示需重启。
5. `netdown` 只停止 NetUI 自己的实例，不误杀其他 sing-box 进程。
6. clone 安装与 Release 安装得到相同文件布局和命令行为。
7. 真实配置权限为 `600`，Release 和 Git 历史秘密扫描无命中。
8. 旧 `netup/netdown` shell function 不再遮蔽新命令；新 shell 中 `type -a netup netdown netui` 指向安装路径。
9. TUI 可在全局、大陆白名单、关闭三种状态间切换；退出后当前 shell 的大小写 proxy/no_proxy 正确，白名单长度不超过 512 bytes。
10. `netdown` 撤销当前有效的 NetUI 代理变量但保留模式 preference，下一次 `netup` 自动恢复；sing-box 自身不继承 proxy 环境。
11. VHS 自动走完主屏、配置切换、环境模式、窄屏和 fallback，ImageMagick 视觉基线门禁通过，圆角边框无错位，PNG 已复制到 `/mnt/c/Users/genev/Desktop/`。
12. 在一次性 Ubuntu 环境完成端到端验证后，才允许切换 h100。

## 8. 下一次对话的起点

下一次实现应从 [07-verification-handoff.md](./07-verification-handoff.md) 的“实施顺序”开始，先建包骨架、可测试的默认配置模型和环境状态模型，再做 TUI；不要先做 Release 页面或直接修改 h100。
