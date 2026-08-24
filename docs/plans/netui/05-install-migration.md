# 05｜安装、升级、卸载与旧 `~/sb` 迁移

## 1. 仓库内建议结构

```text
packages/netui/
├── bin/
│   └── netctl
├── lib/
│   ├── common.sh
│   ├── paths.sh
│   ├── config_store.sh
│   ├── runtime_tmux.sh
│   ├── env_profiles.sh
│   ├── shell_integration.sh
│   ├── tui.sh
│   ├── migrate.sh
│   └── install_core.sh
├── scripts/
│   └── build-release.sh
├── examples/
│   └── config.example.json
├── share/shell/
│   └── init.sh
├── install.sh
├── bootstrap.sh
├── manifest.lock
├── VERSION
├── README.md
└── THIRD_PARTY_NOTICES.md
```

原则：

- 子包可从仓库根目录独立打包，不依赖 `lib/core.sh` 等 FluxEnv 初始化运行时。
- `netctl` 和库在 clone 安装与 Release 安装中完全相同。
- `bootstrap.sh` 只是下载器，不能另写一套安装逻辑；为满足公开 `curl | sh`，它保留仓库要求的 `#!/bin/bash` shebang，但正文严格限制在 POSIX `sh` 语法子集，并同时用 bash/dash 验证。

## 2. 用户侧版本化安装

```text
~/.local/share/netui/
├── releases/
│   ├── 0.1.0/
│   │   ├── bin/netctl
│   │   ├── bin/sing-box
│   │   ├── bin/gum
│   │   ├── lib/*.sh
│   │   ├── manifest.json
│   │   └── licenses/
│   └── 0.1.1/
└── current -> releases/0.1.1

~/.local/bin/netup   -> ~/.local/share/netui/current/bin/netctl
~/.local/bin/netdown -> ~/.local/share/netui/current/bin/netctl
~/.local/bin/netui   -> ~/.local/share/netui/current/bin/netctl
```

三个 symlink 的 basename 让同一核心知道应执行哪个入口。

## 3. 安装模式

### 3.1 clone 仓库安装

对最终用户文档使用 HTTPS clone，不要求 GitCode SSH key：

```bash
git clone https://gitcode.com/winbeau/FluxEnv.git
cd FluxEnv
bash packages/netui/install.sh
```

开发者继续使用现有 `gc` remote 推送，但安装器不读取、不修改用户的 Git remote。

clone 模式下：

- 脚本从 `manifest.lock` 下载固定 sing-box/gum 资产。
- 校验上游/项目记录的 SHA256。
- 支持 `--asset-dir <path>` 使用已准备的离线资产。
- 不跟随未固定的 `latest` 或上游 `main`。

### 3.2 GitCode Release 安装

最终命令应使用实现阶段实测通过的版本固定 URL，形式类似：

```bash
curl -fsSL '<verified-gitcode-release-url>/v0.1.0/install.sh' | sh
```

bootstrap 只执行：

1. 用 POSIX `sh` 语法检查 OS、架构、curl、tar、sha256sum，并确认系统存在 Bash 4+。
2. 建立 `umask 077` 的临时目录。
3. 下载对应架构的 Release tarball 与 checksum。
4. 校验 checksum。
5. 检查 tar 路径，拒绝绝对路径和 `..` 穿越。
6. 解包并使用 Bash 调用包内 `install.sh --from-release`。
7. 清理临时目录。

它不直接实现配置迁移、rc 修改、升级或 TUI 安装逻辑。

## 4. 依赖策略

### 包内携带

- 固定版本 sing-box。
- 固定版本 gum。
- 对应许可证、来源与 checksum 元数据。

### 系统依赖

- Bash 4+。
- tmux。
- jq。
- curl 或 wget（bootstrap 以 curl 为公开入口）。
- tar、gzip、sha256sum、install、flock。

安装器行为：

- 先检测并列出缺失项。
- 用户态安装默认不静默执行 apt。
- 若实现 `--install-deps`，必须先明确展示将执行的 apt 命令并要求确认；脚本中的 privileged 操作需遵守仓库安全约定。
- 缺少 gum 不阻断 CLI；Release 理论上总会携带 gum。
- 缺少 jq/tmux 时不能宣称核心安装完成，应失败并给出一条可执行的 Ubuntu/Debian 安装提示。

## 5. 安装事务

1. 解析目标版本与架构。
2. 校验所有输入资产。
3. 在 releases 下创建临时版本目录。
4. 复制脚本/二进制并设置 mode。
5. 执行：

```bash
<new>/bin/sing-box version
<new>/bin/gum --version
bash -n <new>/bin/netctl <new>/lib/*.sh
```

6. 若已有默认配置，用新 sing-box 执行 `check`。
7. 将临时目录原子改名为正式版本目录。
8. 原子更新 `current` symlink。
9. 创建或修复 `~/.local/bin/netup/netdown/netui` symlink。
10. 检查 `~/.local/bin` 是否在 PATH；必要时只添加带标记的幂等 PATH block。
11. 经用户确认，在 `.bashrc`/`.zshrc` 加入独立的 NetUI shell integration block，用于环境 generation/prompt hook；先备份且不得覆盖现有 hooks。
12. 初始化 `env-mode=off`，不在首次安装时无提示接管用户网络。
13. 打印版本、命令解析、配置目录、环境模式和下一步。

任何一步失败都不切换 `current`。

## 6. 首次配置

全新机器安装时：

- 创建空的 `~/.config/netui/configs`。
- 不生成伪造的可运行节点。
- 示例只留在程序目录，不复制成默认配置。
- `netui` 首屏引导用户导入 JSON。
- 环境 preference 初始化为 `off`；用户在 TUI 明确选择全局或大陆白名单。
- `netup` 在无默认配置时返回 exit 4，并提示运行 `netui`。

## 7. 旧 `~/sb` 迁移

### 7.1 触发方式

迁移必须显式：

```bash
bash packages/netui/install.sh --migrate-legacy
```

或首次运行 `netui` 时检测到 `~/sb` 并询问。普通安装不得无提示修改旧目录或 rc 文件。

### 7.2 预检

- `~/sb` 是否为目录。
- 旧 tmux 会话/进程/监听是否仍存在。
- 候选文件是否为普通文件。
- 使用新 sing-box 对候选逐一 check。
- 新配置目录是否已有同名文件。
- `.bashrc`/`.zshrc` 是否 source 旧 `env.sh`。
- 当前 shell 的 `netup/netdown` 是否为 function。

旧实例仍运行时，默认中止迁移；不自动执行旧 `sbctl stop`。

### 7.3 配置导入

候选不仅限于 `*.json`，还应扫描当前已知的 `config.json*`，但只有同时满足以下条件才导入：

- 普通文件。
- `jq empty` 成功。
- 新 sing-box `check` 成功。

处理：

1. 为每个文件生成安全、唯一、以 `.json` 结尾的 basename。
2. mode `600` 复制到临时文件。
3. 原子移动到 configs 目录。
4. 写本地 migration map：旧路径、目标 basename、内容识别协议、时间；不写秘密。
5. 将旧 `~/sb/config.json` 对应的新文件设为默认。
6. 如果旧默认无效，不自动选择另一个配置。

### 7.4 二进制与脚本

- 不复制旧 `sing-box` 进入新 release。
- 不复制旧 `sbctl` 作为命令实现。
- `env.sh` 可留在旧目录用于回滚，但新 rc 不再 source。
- 旧 `proxyon/proxyoff`、旧长 no_proxy 和 `netup/netdown` function 不迁入新 integration。
- 不删除 `~/sb`。

### 7.5 rc 与 function 冲突处理

迁移时显示将处理的精确行并确认：

```text
/root/.zshrc:<line> [ -f ~/sb/env.sh ] && source ~/sb/env.sh
/root/.bashrc:<line> [ -f ~/sb/env.sh ] && source ~/sb/env.sh
```

操作要求：

1. 备份为 `NETUI_BACKUP_DIR/shell/<timestamp>/`。
2. 只注释或删除精确 source 行。
3. 不删除用户的其他代理变量和 alias。
4. 新 integration 只注册 generation-aware prompt hook，不重新定义 `netup/netdown/netui`。
5. 对现有 Bash `PROMPT_COMMAND`、Zsh `precmd_functions` 做追加式接入，重复安装不重复注册。
6. 安装结束明确说明当前 shell 仍可能保留旧 function；新 hook 要在新登录 shell 中初始化。
7. 要求开启新登录 shell，再验证：

```bash
type -a netup netdown netui
```

当前 shell 的一次性清理命令仅作为提示，不能由 curl 子 shell替用户完成。

### 7.6 回滚

迁移回滚不需要恢复配置内容，因为旧 `~/sb` 未改动。只需：

- 停止新 NetUI 实例。
- 恢复备份的 rc 文件或旧 source 行。
- 重新登录 shell。
- 如有需要使用旧 `~/sb/sbctl`。

## 8. 升级与回滚

### 升级

- 下载/校验新版本到新 release 目录。
- 用新核心校验默认配置。
- 原子切换 `current`。
- 不自动重启正在运行的代理；提示用户在合适时间重启。
- TUI 显示“程序已升级，运行实例仍为旧版本”直到重启。

### 回滚

安装器或内部命令支持选择上一个已验证 release：

- 校验目标版本目录与 manifest。
- 用目标 sing-box check 默认配置。
- 原子切换 `current`。
- 不自动改 JSON。
- 是否重启由用户确认。

保留策略：当前版本 + 最近 2 个版本；清理更老版本必须显式执行。

## 9. 卸载

默认卸载：

- 停止 NetUI 实例。
- 删除 `~/.local/bin` 三个由 NetUI 创建的 symlink。
- 删除程序 release/current。
- 从 rc 中只移除 NetUI 自己的带标记 integration block，并保留备份。
- 在当前/新 shell 中撤销 NetUI-owned proxy/no_proxy；tmux global environment 删除同名项。
- 保留 `~/.config/netui`、state 日志和备份。

`--purge` 才删除配置与 state，并需二次确认及列出路径。删除前必须验证路径位于预期 XDG 根目录，禁止对空变量执行 `rm -rf`。

## 10. 安装验收

- 重复安装同版本幂等。
- 安装失败不影响 current。
- clone 与 Release 的目录、版本、命令行为一致。
- root 和普通用户均安装到各自 HOME。
- 配置不被升级覆盖。
- 旧 function 冲突被检测并有清晰迁移路径。
- prompt hook 在 bash/zsh 中幂等，不覆盖原有 hook，TUI 退出后可持久同步环境。
- 全局/大陆白名单/off 初始与卸载行为清晰。
- 卸载默认保留 JSON。
