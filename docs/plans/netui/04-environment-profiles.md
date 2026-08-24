# 04｜持久代理环境模式与 shell/tmux 同步

## 1. 已锁定需求

`netui` 除了管理 JSON，还必须管理当前用户的代理环境模式：

1. **全局代理**：HTTP(S)/ALL_PROXY 指向本地 sing-box；`no_proxy` 只有本地回环。
2. **大陆白名单直连**：仍默认走代理，但精简的中国大陆域名与镜像后缀通过 `no_proxy` 直连。
3. **关闭环境变量**：清除 NetUI 自己设置的代理变量。

前两项是两种代理 profile；第三项是控制状态。模式选择必须持久化，退出 `netui` 后当前 shell 继续生效，新登录 shell 也能恢复。

sing-box 进程仍只由 tmux 托管；不使用 systemd、systemd-user、nohup、screen 或常驻环境守护进程。

## 2. 环境变量集合

生效时统一管理大小写两套变量：

```text
http_proxy
HTTP_PROXY
https_proxy
HTTPS_PROXY
all_proxy
ALL_PROXY
no_proxy
NO_PROXY
```

对于当前 `mixed` inbound `127.0.0.1:10808`，值为：

```text
http_proxy=http://127.0.0.1:10808
https_proxy=http://127.0.0.1:10808
all_proxy=socks5h://127.0.0.1:10808
```

端口不能硬编码；必须从**当前运行配置**的 loopback `mixed`/`http`/`socks` inbound 解析。若只有 socks inbound：

- 设置 `all_proxy/ALL_PROXY`。
- 不伪造不可用的 `http_proxy/https_proxy`。
- TUI 明确显示该模式仅能为支持 SOCKS 的程序生效。

## 3. 两套 `no_proxy`

### 3.1 全局代理模式

按用户要求，仅保留本地回环：

```text
localhost,127.0.0.1,::1
```

固定长度为 23 bytes。不加入 RFC1918、Tailscale 或其他网段，避免“全局”模式产生额外绕过。

### 3.2 大陆白名单直连模式

建议第一版固定为以下紧凑列表：

```text
localhost,127.0.0.1,::1,.cn,.huaweicloud.com,.aliyun.com,.aliyuncs.com,.cloud.tencent.com,.myqcloud.com,.npmmirror.com,.qq.com,.tencent.com,.baidu.com,.bcebos.com,.alicdn.com,.taobao.com,.jd.com,.bilibili.com,.byteimg.com,.douyin.com,.163.com,.weibo.com,.zhihu.com,.gitee.com,.gitcode.com
```

当前经 `LC_ALL=C printf %s "$value" | wc -c` 与 Python UTF-8 双重核对为 288 bytes，并设置实现硬上限 `<= 512 bytes`。TUI 显示值必须运行时计算，不把 `288` 写死在代码里。

覆盖逻辑：

- `.cn` 已覆盖清华 TUNA、中科大、北外、上交等位于 `.edu.cn`/`.cn` 下的镜像，避免重复逐个列出。
- `.huaweicloud.com` 覆盖华为镜像。
- `.aliyun.com`、`.aliyuncs.com` 覆盖阿里云镜像与常见对象存储。
- `.cloud.tencent.com`、`.myqcloud.com` 覆盖腾讯镜像与云服务。
- `.npmmirror.com` 覆盖 npm 国内镜像。
- 其余后缀覆盖常用大陆站点、代码托管与静态资源。

控制原则：

- 不收录上百个具体 hostname。
- 不同时保留 `.cn` 与每个 `.edu.cn` 镜像重复项。
- 不支持通配符展开成巨大列表。
- 第一版不提供任意 TUI 编辑；后续如允许用户追加，额外项总长度也必须受限并去重。
- 每次生成时去空白、去重、拒绝换行和 shell 元字符。

## 4. 为什么不能只靠 `netui` 子进程 export

外部命令不能修改父 shell 环境。`netui` 内执行：

```bash
export http_proxy=...
```

只会影响 TUI 子进程，退出后父 shell 看不到变化。

因此必须采用“持久状态 + shell hook”模型：

1. TUI 原子写入环境模式状态和 generation。
2. TUI 同步 tmux server 的全局 environment，供以后创建的 tmux pane/window 继承。
3. `netui` 退出回到 bash/zsh prompt 时，预先安装的 prompt hook 检测 generation 变化。
4. hook 在**当前父 shell 自身**执行 export/unset，因此退出 TUI 后立即保持变量。
5. 新登录 shell 在 rc 初始化时读取同一状态并恢复。

这不需要守护进程，也不需要 systemd。

## 5. 状态文件

建议：

```text
~/.config/netui/env-mode                 # global | cn-direct | off
~/.local/state/netui/runtime/env-generation
~/.local/state/netui/runtime/proxy-endpoint
~/.local/share/netui/current/share/shell/init.sh
```

规则：

- `env-mode` 只接受三个固定枚举。
- `proxy-endpoint` 只接受严格格式，例如 `mixed|127.0.0.1|10808`。
- generation 在模式切换、netup 成功、netdown 成功、运行状态失效时原子更新。
- shell hook 不 `source` 可变 state 文件，不 `eval` 文件内容；逐行读取并按白名单格式校验。
- mode/state 文件 mode `600`，目录 `700`。

## 6. bash/zsh shell hook

### 6.1 rc 接入

安装器在用户确认后加入一个带边界标记、可幂等移除的 block：

```bash
# >>> netui shell integration >>>
[ -r "$HOME/.local/share/netui/current/share/shell/init.sh" ] && \
    source "$HOME/.local/share/netui/current/share/shell/init.sh"
# <<< netui shell integration <<<
```

必须同时支持 `.bashrc` 和 `.zshrc`，先备份再精确编辑。

### 6.2 Bash

- 初始化 source 时先执行一次 `__netui_apply_env`。
- 通过不覆盖现有内容的方式接入 `PROMPT_COMMAND`。
- 每次 prompt 只先读取很小的 generation 文件；generation 未变化时立即返回。
- 不重复追加 hook。

### 6.3 Zsh

- 使用 `autoload -Uz add-zsh-hook`。
- 通过 `add-zsh-hook precmd __netui_apply_env` 接入。
- 初始化时同样立即执行一次。
- 防止多次 source 后重复注册。

### 6.4 作用范围

- 从 `netui` 返回当前 prompt：立即同步。
- 其他已打开的 bash/zsh：各自在下一次显示 prompt 时同步。
- 新 shell：启动时同步。
- 已经运行的普通进程：Unix 无法回写其环境，不承诺追溯修改。
- `netup && curl ...` 同一条复合命令中间没有 prompt，hook 尚未执行；文档应提示拆成两条命令，或在 shell 中先运行 `netup` 返回提示符。

## 7. tmux 环境同步

模式变化后执行等价的：

```text
tmux set-environment -g http_proxy ...
tmux set-environment -g HTTP_PROXY ...
...
```

关闭模式时使用 `tmux set-environment -gu <name>` 清除 NetUI 管理的项。

边界：

- tmux global environment 只影响之后创建的 pane/window，不会回写已运行 shell。
- 已运行 shell 仍依靠 prompt hook。
- 没有 tmux server 时，写模式状态即可；`netup` 创建 session 后再同步。
- 代理进程常驻由 NetUI tmux 会话负责，不额外创建“环境守护”会话。

## 8. 防止 sing-box 自代理循环

如果当前 shell 已经有 `http_proxy/all_proxy`，直接从该 shell 启动 sing-box 可能让核心继承代理变量并产生自代理/回环风险。

`netup` 在 tmux 中启动 sing-box 时必须显式清除：

```text
http_proxy HTTP_PROXY
https_proxy HTTPS_PROXY
all_proxy ALL_PROXY
no_proxy NO_PROXY
```

只对 sing-box 进程清除；用户 shell 的有效模式不受影响。

## 9. 模式选择与有效状态

TUI 同时展示：

- **选择模式**：持久 preference。
- **有效状态**：当前 shell/运行代理是否可以实际使用。

建议状态机：

| 持久模式 | 代理运行 | shell 有效结果 |
|---|---|---|
| `off` | 任意 | 清除 NetUI-owned 代理变量 |
| `global` | 是 | 应用全局代理变量 |
| `cn-direct` | 是 | 应用大陆白名单直连变量 |
| `global`/`cn-direct` | 否 | 暂时清除变量，保留 preference；下次 netup 后自动恢复 |

这样 `netdown` 后不会把 shell 指向一个已经关闭的本地端口，同时用户下次 `netup` 无需重新选模式。

## 10. TUI 交互

主界面增加：

```text
Env mode: CN direct   Effective: ON   no_proxy: 288 B
```

动作键建议 `[P] 环境模式`，进入三选一：

1. 全局代理（仅回环直连）。
2. 大陆白名单直连（精简 288 B）。
3. 关闭环境变量。

确认页显示：

- 将设置的变量名。
- 本地代理 endpoint。
- `no_proxy` 长度和主要覆盖类别。
- 是否因代理未运行而暂不生效。

切换成功后：

- 原子更新 mode/generation。
- 同步 tmux environment。
- TUI 内部子进程使用新值。
- 退出 TUI 回到 prompt 后，由 hook 更新父 shell。

## 11. 环境变量所有权

避免无条件破坏用户已有手工代理：

- shell hook 设置 `NETUI_ENV_OWNED=1` 作为当前 shell 标记。
- `off` 模式只在该标记存在时 unset NetUI 管理的 proxy/no_proxy 变量。
- 新 shell 在 mode=off 时不主动清除用户自己预设的变量。
- 第一版不尝试跨登录恢复 NetUI 接管前的旧代理值；文档明确“关闭 NetUI 环境模式会清除本次由 NetUI 设置的值”。
- 不把代理变量写进 `/etc/environment`、`/etc/profile` 或其他全局系统文件。

## 12. 与迁移的关系

旧 `~/sb/env.sh`：

- `proxyon` 同时导出大小写 proxy 变量。
- 旧 `no_proxy` 包含 loopback、Tailscale 和 RFC1918 网段。
- 旧 `netup/netdown` function 同时控制进程和环境。

新模型有意拆分：

- `netup/netdown` 是真实 CLI，只管 tmux 受管实例。
- `netui` 管理持久环境 preference。
- shell hook 根据运行状态应用或撤销环境。
- 全局模式的 `no_proxy` 按新要求缩减为仅 loopback。
- 大陆模式使用受控 288-byte 列表。

迁移完成后不再 source 旧 `env.sh`，防止两套逻辑互相覆盖。

## 13. 验收

- 在 TUI 选“全局”，退出后当前 shell 的大小写 proxy/no_proxy 均正确。
- 在 TUI 选“大陆白名单”，退出后 `NO_PROXY` 与 `no_proxy` 相同且 `<=512` bytes。
- `.cn`、清华镜像、华为镜像、阿里/腾讯镜像走直连；GitHub 等未列域名仍走代理。
- 选“关闭”后，当前 shell 在下一个 prompt 清除 NetUI-owned 变量。
- netdown 后自动撤销有效代理变量，但保留模式 preference；下次 netup 后恢复。
- 新 bash/zsh 登录会话读取持久模式。
- 新 tmux pane 继承当前有效模式。
- 已有 tmux pane 在下一个 prompt 同步。
- sing-box 进程环境中不存在 proxy/no_proxy 变量。
- 不存在 systemd unit、nohup 进程或环境守护 daemon。
