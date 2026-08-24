# 07｜实施顺序、安装体验与 v0.2.0 发布

## 1. 版本策略

这是明显的交互和功能升级，使用：

```text
NetUI v0.2.0
```

禁止：

- 移动或强制更新已发布 `v0.1.0` annotated tag；
- 静默替换 v0.1.0 Release 资产；
- 在 README 继续让用户误以为 v0.1.0 已包含新 TUI；
- 未验证公开下载前发布 v0.2.0 安装命令。

## 2. 实施顺序

### Phase 1：元数据与纯函数

新增 `config_meta.sh`，先完成内容识别和 table row model。

交付：

- 三类协议分类；
- server/port/transport/security；
- filename mismatch tests；
- 无 UI 改动也可独立测试。

### Phase 2：URI parser 与 JSON builder

新增 `share_uri.sh`，先提供非交互测试 API，再接 TUI。

交付：

- percent decode；
- 三类 mapping；
- atomic import；
- check/cleanup/redaction tests。

### Phase 3：终端引擎和新主屏

拆出 terminal/render 层，完成：

- alternate screen；
- arrows/Ctrl keys/Esc；
- table/log/footer；
- resize/restore；
- bounded background config validation；
- safe restart preflight/rollback；
- fallback。

先接入现有 default/env 动作，并在 runtime owning layer 增加安全重启 helper，不等待 probe 完成。

### Phase 4：URI modal

- blind paste；
- redacted preview；
- insecure warning；
- Enter import/Esc cancel；
- 导入后选中新行。

### Phase 5：Probe worker

- isolated config snapshot；
- latency；
- throughput；
- result polling；
- cancellation/cleanup；
- table/footer integration。

### Phase 6：视觉和安装体验

- VHS v2 scenes；
- installer stage logs；
- dependency summary；
- README/Release docs；
- dual-arch build。

## 3. 预计文件变更

新增：

```text
packages/netui/lib/config_meta.sh
packages/netui/lib/share_uri.sh
packages/netui/lib/probes.sh
packages/netui/lib/tui_terminal.sh
packages/netui/lib/tui_render.sh
```

主要修改：

```text
packages/netui/lib/tui.sh
packages/netui/lib/paths.sh
packages/netui/bin/netctl
packages/netui/install.sh
packages/netui/bootstrap.sh
packages/netui/lib/install_core.sh
packages/netui/README.md
packages/netui/scripts/build-release.sh
tests/netui/run.sh
tests/netui/vhs/*.tape
tests/netui/visual/run.sh
```

新增 private paths：

```text
NETUI_PROBE_CACHE_DIR=$NETUI_STATE_HOME/probes
NETUI_PROBE_CACHE=$NETUI_PROBE_CACHE_DIR/cache.json
NETUI_PROBE_ACTIVE_DIR=$XDG_RUNTIME_DIR/netui/probes
    # XDG_RUNTIME_DIR 不安全/不存在时 fallback 到 $NETUI_RUNTIME_DIR/probes-active
NETUI_PROBE_LOCK=$NETUI_RUNTIME_DIR/probe.lock
```

active dir 可含短暂 credential-bearing snapshot，必须启动时 stale cleanup；persistent cache 只能保存脱敏结果。

## 4. 与 v0.1.0 的兼容

保持不变：

- `netup` 只启动 default。
- `netdown` 只停止受管实例。
- 配置目录和 `default.json` symlink。
- runtime tmux session 名称和所有权校验。
- `global/cn-direct/off` 文件格式。
- shell hook generation 模型。
- 现有用户 JSON 不迁移、不重写。
- install release/current 目录布局。

新增 state 必须可删除重建；v0.1.0 回滚时应忽略 probe cache，不报错。v0.2.0 每次启动必须清理经过 owner marker 校验的 stale probe active dirs，覆盖 SIGKILL/断电。

## 5. 安装过程日志修复

用户已实际遇到：

```text
netui install: missing dependency: tmux
```

现有流程在下载和校验阶段使用 silent curl，且安装核心只报告第一个缺失依赖，容易让用户误以为卡住。

v0.2.0 发布前必须改为清晰阶段日志。

### Bootstrap 期望输出

```text
[1/7] Detecting Linux architecture... amd64
[2/7] Checking bootstrap dependencies... ok
[3/7] Downloading NetUI v0.2.0 archive... 23.6 MiB
[4/7] Downloading checksums... ok
[5/7] Verifying SHA256 and archive safety... ok
[6/7] Unpacking release... ok
[7/7] Installing NetUI into user directories...
```

### 安装核心期望输出

```text
netui install: checking runtime dependencies
netui install: validating release tree and bundled binaries
netui install: preparing ~/.local/share/netui/releases/0.2.0
netui install: validating existing default configuration
netui install: switching current symlink
netui install: installing netup/netdown/netui command links
netui install: completed
```

### 缺依赖

一次检查全部依赖，而不是遇到第一个立即返回：

```text
netui install: missing runtime dependencies: jq tmux curl
netui install: Ubuntu/Debian suggestion:
  sudo apt-get update && sudo apt-get install -y jq tmux curl
netui install: no files were changed
```

规则：

- 安装器只提示，不自动 sudo/apt install。
- 先做依赖检查，再改变 release/current 或命令链接。
- 错误写 stderr，进度写 stdout。
- 非 TTY 管道也持续输出阶段行。
- curl 可以保持安全 flag，但不能完全隐藏长下载；至少显示开始、资产名和完成大小。
- 如启用 progress bar，只在 stderr 为 TTY 时使用；管道模式输出离散阶段日志。

## 6. 新依赖策略

现有基础依赖外，测速需要 `curl`，外层 timeout 最好使用 coreutils `timeout`。

建议：

- `curl` 作为 v0.2 runtime 必需依赖，因为 Ctrl+T 是承诺功能。
- `timeout` 若不存在，可由 curl 原生 timeout + Bash cleanup 兜底；安装器显示 optional degraded capability。
- 不新增 Python、Node、nc、socat 作为运行时必需依赖。
- gum 继续 bundled，但全屏 ANSI 主路径不依赖 gum。

## 7. Secret scan 调整

当前扫描 bare scheme 和 credential 字段名，新增 parser 后会误报合法源代码。

实施要求：

- 扫描真实分享链接形态，而不是 bare `vless://` token。
- 扫描 credential 字段的非 placeholder 值。
- 对 synthetic fixture 使用明确 marker。
- source parser 不能整体排除。
- Release staging 中任何用户链接/真实 JSON 仍为 P0 失败。
- 本地 `v2rayN.png` 不进入 staging。

## 8. 文档更新

`packages/netui/README.md` 增加：

- 新主界面截图（synthetic）；
- 快捷键表；
- 三类 URI 支持矩阵；
- Hysteria2 insecure warning；
- Ctrl+T 指标定义和第三方测速 URL 说明；
- curl/tmux/jq 依赖安装建议；
- v0.1.0 与 v0.2.0 固定安装命令。

根 `README.md` 可增加 NetUI 简短入口，但不放真实链接示例。

## 9. 提交建议

按可审查阶段提交：

```text
feat: add netui config metadata model
feat: import vless and hysteria2 share links
feat: add fullscreen netui keyboard interface
feat: add isolated netui latency and speed probes
test: add netui v2 terminal visual coverage
fix: show netui installer progress and missing dependencies
docs: document netui v0.2 keyboard workflow
```

不要把全部改动压成一个超大 commit。

## 10. 打包集成清单

新增模块不能只在源码树可用。实现时逐一更新：

- `packages/netui/bin/netctl` 的 source 顺序；
- `install_core_validate_source_tree` required files；
- `install_core_validate_release_tree` required files；
- `install_core_build_release_tree` 的复制清单；
- build-release package/archive 清单；
- `tests/netui/install.sh` fake release 复制清单；
- install/uninstall/reinstall smoke。

验收必须从实际构建 tar.gz 解包并安装，再调用 installed `current` 下的 metadata、URI import 和 fake probe 路径，不能只在仓库源码运行。

## 11. 构建和验证

最小检查：

```bash
bash -n packages/netui/bin/netctl packages/netui/install.sh packages/netui/lib/*.sh packages/netui/scripts/*.sh
bash tests/netui/run.sh
bash tests/netui/install.sh
bash tests/netui/visual/run.sh
```

正式构建：

```bash
bash packages/netui/scripts/build-release.sh \
    --asset-dir "$PWD/verified-assets" \
    --output-dir "$PWD/artifacts/netui/v0.2.0" \
    --release-base-url 'https://gitcode.com/winbeau/FluxEnv/releases/download/v0.2.0'
```

构建前：

- version/URL 固定；
- 工作树干净；
- 不使用 preview/allow-dirty；
- 所有 baseline 已经人工批准；
- v0.2.0 tag 尚不存在。

## 12. 发布资产

```text
netui-v0.2.0-linux-amd64.tar.gz
netui-v0.2.0-linux-arm64.tar.gz
install-v0.2.0.sh
SHA256SUMS
RELEASE-MANIFEST.json
THIRD_PARTY_NOTICES.md
SOURCE-CODE-OFFER.md
```

发布后：

- 官方 CLI 下载全部资产；
- SHA256 与本地一致；
- 匿名 Release 页面 HTTP 200；
- amd64 临时 HOME curl pipe 安装；
- arm64 真实/模拟验证按发布门禁完成；
- README 固定命令与资产 URL 一致。

## 13. 回滚

- 程序回滚到 v0.1.0 不删除新导入 JSON。
- v0.1.0 会把新增配置当普通 JSON 使用。
- probe cache 和 UI state 可保留或安全删除。
- URI parser 不修改原始链接来源。
- 新版本启动失败时 install current 应保持/恢复旧版本。
- 当前运行的旧 sing-box 实例不因安装 v0.2.0 自动重启。

## 14. 停止条件

出现任一情况停止发布：

- 三类 URI 任一生成配置无法通过 pinned sing-box check。
- raw URI/credential 出现在日志、state、argv、测试输出或 staging。
- Ctrl-C/Esc 后终端未恢复。
- probe 退出后残留 sing-box/curl child。
- Ctrl+T 中断当前 NetUI runtime。
- probe SIGKILL/断电后 credential snapshot 不能在下次启动被清理。
- invalid default 的 Ctrl+R 会先停止健康旧实例，或新启动失败后没有明确 rollback 结果。
- Ctrl+方向键在 tmux/VHS 无可靠 fallback。
- throughput target 返回不稳定/非预期内容、redirect 到 HTTP 或响应压缩语义不明却仍显示速度。
- visual baseline 通过放宽阈值而不是修复布局。
- installer 长时间无阶段输出。
- 缺 tmux 时已经写入部分安装状态。
- 准备覆盖 v0.1.0 tag/Release。

## 15. 本轮计划交付边界

本轮只新增计划 Markdown：

- 不修改运行代码；
- 不使用用户真实 URI 做自动测试；
- 不修改 v0.1.0 Release；
- 不 push/tag/release；
- 不提交本地参考图。

后续实现从 `config_meta.sh` 开始，不要直接在现有 `tui.sh` 中堆 URI parser 和测速代码。
