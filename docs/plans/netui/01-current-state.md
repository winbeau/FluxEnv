# 01｜h100-server 现状审计与迁移约束

## 1. 审计边界

本次只读检查范围为：

- 目标：SSH target `h100-server`。
- 主目录：`~/sb`。
- 文件结构、权限、版本、配置 schema、配置校验结果。
- tmux/进程/监听状态。
- `.bashrc`、`.zshrc` 中与 `~/sb/env.sh` 有关的接入点。
- 未启动、停止、修改或复制任何远端代理资产。
- 未读取或记录配置中的密码、UUID、Reality key、真实端点值。

## 2. 主机与依赖

| 项目 | 结果 |
|---|---|
| OS | Ubuntu 24.04.1 LTS |
| 架构 | x86_64 |
| 当前用户 | root |
| 默认 shell | zsh |
| `~/.local/bin` | 已在 `PATH` 中 |
| tmux | 3.4 |
| jq | 已安装 |
| curl | 已安装 |
| sha256sum/tar/gzip/flock | 已安装 |
| qrencode | 未安装，与本项目核心无关 |

这说明 h100 可以采用用户态安装，不需要把命令写入 `/usr/local/bin`。

## 3. `~/sb` 文件清单

| 文件 | 作用 | 现状与风险 |
|---|---|---|
| `sing-box` | sing-box 核心 | 版本 1.12.0，约 44 MB；不是从当前 Git 仓库生成，无可靠来源链 |
| `LICENSE` | 上游许可证文本 | GPLv3 文本；不能仅凭此证明二进制来源可信 |
| `sbctl` | 启停脚本 | 用 tmux 会话 `sb` 管理单实例，固定本地端口 10808 |
| `env.sh` | shell helper | 定义代理环境变量函数、aliases、`netup/netdown` function |
| `config.json` | 当前配置 | Hysteria2 outbound |
| `config.json.vless` | 备用配置 | VLESS + REALITY outbound |
| `config.json.hy2` | 备用配置 | 实际也是 VLESS + REALITY，名称与内容不一致 |

`~/sb` 不是 Git 工作树，文件所有权还混有已不存在/不可解析的旧 UID/GID，进一步说明不能把该目录直接打包发布。

## 4. 配置形态

三份配置共同点：

- `inbounds[0].type = mixed`。
- 监听 `127.0.0.1:10808`。
- outbound 服务端口为 443。
- TLS 已启用。
- 均通过 `./sing-box check -c <file>`。

协议分布：

| 文件 | 按内容识别的协议 | REALITY |
|---|---|---|
| `config.json` | Hysteria2 | 否 |
| `config.json.vless` | VLESS | 是 |
| `config.json.hy2` | VLESS | 是 |

迁移器和 TUI 因此必须遵循：

1. 文件名只是用户标签，不是协议真相。
2. 协议、监听和端点摘要从 JSON 内容中读取。
3. 配置是否可用以 `jq empty` 和目标 sing-box 版本的 `check` 结果为准。
4. 不把 JSON 内容写入普通日志。

## 5. 当前生命周期

审计时：

- tmux 会话 `sb` 不存在。
- `127.0.0.1:10808` 未监听。
- 无 sing-box 运行进程。
- `/etc/systemd/system`、cron 和用户 systemd 目录未发现 `~/sb` 自启动引用。

当前 `sbctl` 行为：

- `start`：校验 `~/sb/config.json`，然后在 tmux 中启动。
- `stop`：杀 tmux 会话，并以进程匹配清理残留。
- `status`：检查会话、固定端口和出口 IP。
- `log/attach`：读取或进入 tmux。

新实现应保留“手动启动、单实例、可查看日志”的用户体验，但修复以下问题：

- 不硬编码默认配置为固定路径；由 `default.json` 决定。
- 不通过宽泛 `pkill -f` 误杀其他实例。
- 不把监听端口固定为 10808；从运行配置提取并展示。
- 进程启动参数必须安全传递，不能拼接可注入的配置路径字符串。
- 运行状态必须记录启动时实际解析到的配置，不能只看当前默认 symlink。
- sing-box 继续只在 tmux 中常驻，不引入 systemd、nohup 或其他后端。

## 6. 旧环境变量行为与新约束

旧 `env.sh` 会同时设置大小写 `http_proxy`、`https_proxy`、`all_proxy` 和 `no_proxy`，其中旧 `no_proxy` 包含 loopback、Tailscale CGNAT 与 RFC1918 私网。

新需求明确改变这一模型：

- 全局代理模式的 `no_proxy` 只能保留 `localhost,127.0.0.1,::1`。
- 大陆白名单模式以 `.cn` 覆盖清华 TUNA、中科大、北外、上交等 `.edu.cn` 镜像，再补充华为云、阿里云、腾讯云、npmmirror 和少量常用大陆 `.com/.net` 后缀。
- 白名单需要受控去重，目标小于 512 bytes，不能把数百个 hostname 全部塞进环境变量。
- 退出 TUI 后当前 shell 仍要保留所选模式，因此不能只在 `netui` 子进程中 `export`。
- 新实现使用持久 state + bash/zsh prompt hook，并把有效值镜像到 tmux global environment；tmux 继续负责 sing-box 进程常驻。

详见 [04-environment-profiles.md](./04-environment-profiles.md)。

## 7. shell 命令遮蔽：P0 迁移问题

`.zshrc` 与 `.bashrc` 都包含：

```bash
[ -f ~/sb/env.sh ] && source ~/sb/env.sh
```

旧 `env.sh` 定义：

```bash
netup()   { ~/sb/sbctl start && proxyon; }
netdown() { proxyoff; ~/sb/sbctl stop; }
```

审计结果明确显示：

```text
netup is a shell function from /root/sb/env.sh
netdown is a shell function from /root/sb/env.sh
```

shell function 的优先级高于 `~/.local/bin/netup`。因此仅安装新文件不会完成迁移。

实施要求：

1. 安装器检测 `type -a netup netdown`。
2. 若命中旧 `~/sb/env.sh`，将其视为迁移阻断项并明确提示。
3. 迁移操作先备份 `.bashrc`、`.zshrc`，再只删除或注释精确匹配的旧 source 行；不能重写整个 rc 文件。
4. `curl | sh` 在子 shell 内无法清除父 shell 已加载的 function，安装结束必须提示重新打开登录 shell，或由用户在当前 shell 执行一次：

```bash
unset -f netup netdown 2>/dev/null || true
hash -r 2>/dev/null || true
```

5. 在 zsh 中还需验证 `rehash`/新登录 shell 后的实际解析结果。
6. 验收以 `type -a netup netdown netui` 为准，不能只以文件存在为准。

## 8. 权限与秘密

当前权限：

- `/root`：`700`。
- `~/sb`：`755`。
- 配置 JSON：`644`。
- 二进制/控制脚本：`755`。

虽然 `/root` 的 `700` 暂时限制了其他用户访问，但新包仍必须主动设置：

```text
~/.config/netui                  700
~/.config/netui/configs          700
~/.config/netui/configs/*.json   600
~/.local/state/netui             700
程序脚本/二进制                  755
```

禁止行为：

- 将远端 JSON scp 到开发仓库。
- 将真实字段用于示例、测试 fixture、截图、终端 transcript 或 Release notes。
- 记录完整配置 hash 作为公开标识；如果运行状态需要 hash，应只保存在本机 state 中。
- 将旧二进制视为 Release 输入。

## 9. h100 迁移映射

迁移必须复制而非移动，并保留来源映射：

| 旧资产 | 新位置/处理 |
|---|---|
| `~/sb/config.json` | 复制为 `~/.config/netui/configs/<安全名称>.json`，并设为默认 |
| `~/sb/config.json.vless` | 识别内容后复制为以 `.json` 结尾的唯一名称 |
| `~/sb/config.json.hy2` | 按实际 VLESS 内容标注，提示文件名漂移，不能自动标成 Hysteria2 |
| `~/sb/sing-box` | 不复用；仅保留原目录，安装官方锁定版本 |
| `~/sb/sbctl` | 不复用；由新 `netctl` 替代 |
| `~/sb/env.sh` | 不再自动 source；可保留为回滚材料；旧 proxy function 不迁入 |
| `.bashrc/.zshrc` source 行 | 经用户同意、备份后精确移除/注释，再加入可幂等卸载的新 prompt hook block |
| 旧环境 preference | 首次迁移默认设为 `off`，由用户在 TUI 明确选择全局或大陆白名单，避免无提示改变网络行为 |

名称生成建议：

- 先从原文件名生成候选名称。
- 协议仅作为 TUI 元数据，不强行改写用户标签。
- 所有目标名必须以 `.json` 结尾。
- 冲突时追加 `-2`、`-3`，禁止覆盖。
- 拒绝名称中的 `/`、换行、NUL 和 `..` 路径段。

## 10. 切换前保护条件

真实 h100 迁移前必须重新确认：

- 旧 tmux 会话和旧 sing-box 是否仍为停止状态。
- 10808 或各配置声明的本地端口是否被其他进程占用。
- 三份配置在新锁定版本 sing-box 下仍能通过 `check`。
- 已备份 rc 文件和 `~/sb` 路径清单。
- 新 shell hook 不覆盖原有 Bash `PROMPT_COMMAND` 或 Zsh `precmd_functions`。
- 全局与大陆白名单的 `no_proxy` 值、长度和大小写同步均通过测试。
- 新包在临时 HOME 中完成一次迁移模拟。
- Git 工作树、构建 staging 和 Release 资产均没有远端秘密。

任一条件不满足时，不在 h100 上执行切换。
