# 06｜GitCode Release、curl 安装与供应链计划

## 1. 发布原则

- GitCode remote `gc` 只用于开发者推送与打 tag。
- 最终用户通过 HTTPS clone 或公开 Release 下载，不依赖 SSH key。
- 每次安装必须对应不可变版本，不以 `main` 或未经验证的 `latest` 作为稳定安装源。
- h100 的真实配置、旧二进制和终端日志永不进入 Release staging。
- 所有第三方二进制固定版本、来源、架构、SHA256 和许可证。

## 2. 未决的 GitCode 平台事实

本次尝试检索 GitCode Release 文档时，环境的 web search provider 未配置，因此没有验证：

- Release asset 的永久 URL 形式。
- `latest` 重定向语义。
- 上传附件的 API/CLI。
- 无登录下载、重定向域名和 Content-Disposition 行为。

实施阶段的硬性要求：

1. 先创建测试 tag/草稿 Release。
2. 用浏览器或 GitCode 官方文档确认上传方式。
3. 对公开下载 URL 实测 HTTP 状态、重定向链、文件长度和 SHA256。
4. 在未登录干净环境中下载一次。
5. 只有验证完成后，才把真实 `curl | sh` 命令写入 README。

不得根据 GitHub/GitLab URL 规则猜测 GitCode 地址。

## 3. 锁定清单 `manifest.lock`

建议字段：

```text
name<TAB>version<TAB>os<TAB>arch<TAB>url<TAB>sha256<TAB>license<TAB>note
```

至少锁定：

- sing-box Linux amd64。
- sing-box Linux arm64。
- gum Linux amd64。
- gum Linux arm64。
- 对应 LICENSE/NOTICE 来源。

规则：

- 版本不得使用 `latest`、`HEAD` 或浮动分支。
- SHA256 不得为 `-`。
- 下载失败或 checksum 不匹配立即停止构建。
- h100 的 sing-box 1.12.0 仅是现状参考，不自动成为要发布的版本。
- 升级上游版本必须单独 commit，并在 PR/commit notes 中说明兼容验证。

## 4. Release 资产

以 `v0.1.0` 为例：

```text
netui-v0.1.0-linux-amd64.tar.gz
netui-v0.1.0-linux-arm64.tar.gz
install-v0.1.0.sh
SHA256SUMS
RELEASE-MANIFEST.json
THIRD_PARTY_NOTICES.md
```

可选稳定版增强：

```text
SHA256SUMS.sig
RELEASE-MANIFEST.json.sig
SBOM.spdx.json
PROVENANCE.txt
```

### 架构包内容

```text
netui-v0.1.0/
├── install.sh
├── VERSION
├── manifest.json
├── bin/netctl
├── bin/sing-box
├── bin/gum
├── lib/*.sh
├── share/shell/init.sh
├── examples/config.example.json
└── licenses/
    ├── NETUI-LICENSE
    ├── sing-box-LICENSE
    └── gum-LICENSE
```

归档中不包含任何用户配置目录。

## 5. 构建脚本

`packages/netui/scripts/build-release.sh` 应：

1. 要求 Git 工作树干净，或显式 `--allow-dirty` 仅用于本地预览。
2. 读取 `VERSION` 与 `manifest.lock`。
3. 下载到临时 staging，校验 SHA256。
4. 只复制白名单文件到归档目录。
5. 设置稳定 mode、排序和时间戳，尽量生成可重复 tarball。
6. 生成每个包的 `manifest.json`。
7. 运行语法、版本和配置模板检查。
8. 扫描秘密与危险文件。
9. 生成 tar.gz 和顶层 `SHA256SUMS`。
10. 在新的临时 HOME 解包并运行 installer smoke test。
11. 运行 VHS 视觉 smoke tape，确认打包后的 TUI 仍能绘制圆角布局和环境模式弹窗。

构建不应从 `offline_resources/` 随意拿未知文件；若复用缓存，也必须按 manifest checksum 验证。

## 6. Bootstrap 设计

### 6.1 固定版本入口

首发文档应优先展示版本固定命令：

```bash
curl -fsSL '<verified-url>/install-v0.1.0.sh' | sh
```

不要先发布：

```bash
curl .../main/bootstrap.sh | sh
curl .../latest/install.sh | sh
```

等 GitCode latest 行为和升级策略验证后，可另加 convenience alias，但固定版本命令必须保留。

### 6.2 Bootstrap 安全要求

- 公开 bootstrap 在 `sh` 下使用 `set -eu`，不得使用不兼容的 `pipefail`；包内 Bash 安装器再使用 `set -euo pipefail`。
- 文件保留 `#!/bin/bash` shebang以符合仓库脚本约定，但正文必须通过 `dash -n` 和真实 `sh` 执行测试。
- `umask 077`。
- 仅支持 Linux 和声明架构。
- `mktemp -d` + trap 清理。
- 下载失败、空文件、checksum 失败均终止。
- checksum 文件必须精确匹配预期资产名。
- 解包前检查 tar listing：拒绝绝对路径、`../`、设备节点和异常 symlink。
- 只执行已校验归档内固定路径的 `install.sh`。
- 不读取当前目录的同名脚本或环境注入路径。
- 不打印下载 URL 中可能出现的 token；公开 Release 本身不应要求 token。

### 6.3 Checksum 与签名

MVP 最低门槛：

- HTTPS。
- 不可变 tag/version。
- 项目生成并公开 `SHA256SUMS`。
- bootstrap 校验 tarball SHA256。

需要准确说明：同源 checksum 主要保证下载完整性，不能完全抵御发布源同时被替换。

稳定版增强：

- 对 `SHA256SUMS` 做 minisign/GPG/OpenSSL detached signature。
- 将公钥指纹固定在仓库和独立文档渠道。
- 安装器先验签 checksum，再验资产。
- 密钥轮换必须单独公告，不允许 Release 静默替换信任根。

为了不阻塞最短可运行版本，签名可作为 v0.2/stable 门禁，但 secrets scan 和 SHA256 不能延后。

## 7. 秘密扫描

Release 前至少扫描：

- Git diff。
- `packages/netui/`。
- 构建 staging。
- tarball 解包内容。
- Release notes。

高风险模式：

```text
vless://
hy2://
hysteria2://
"password"
"uuid"
"privateKey" / "private_key"
"publicKey" / "public_key"
"shortId" / "short_id"
reality-share.txt
config.json（示例白名单除外）
常见私钥 PEM header
```

示例配置必须只含 `CHANGE_ME`、RFC 5737 文档 IP 或明确无效域名，不能复制真实 JSON 后手工删几个字段。

## 8. 许可证和来源

- NetUI 自身选择并声明仓库许可证；若仓库已有整体许可，遵从仓库决策。
- 原样分发 sing-box 官方二进制时随包保留上游 GPLv3 许可证和来源说明。
- gum 随包保留其许可证。
- `THIRD_PARTY_NOTICES.md` 列版本、URL、checksum、是否原样重打包。
- 不声称“可复现构建”，除非确实固定构建环境并完成重复构建验证；首版应称“固定来源、固定 checksum 的重打包资产”。

## 9. Git 与 GitCode 发布步骤

1. 完成实现与测试，确认工作树只含预期变更。
2. 使用 Conventional Commit，例如：

```text
feat: add netui sing-box config manager
```

3. 更新 `VERSION`、manifest、changelog。
4. 构建 Release 并通过门禁。
5. 创建 annotated tag：

```bash
git tag -a v0.1.0 -m 'netui v0.1.0'
```

6. 推送 GitCode remote：

```bash
git push gc main
git push gc v0.1.0
```

7. 在 GitCode 创建对应 Release，上传资产。
8. 从未登录环境重新下载所有资产并校验。
9. 用公开 URL 完成一次 `curl | sh` 安装。
10. 最后才更新 README 中的正式命令。

本计划不要求当前对话执行 commit、push、tag 或 Release。

## 10. Release 门禁

### P0，不可跳过

- [ ] Git tag 与包版本一致。
- [ ] sing-box/gum 版本与 SHA256 全部锁定。
- [ ] 两个架构包内容白名单检查通过。
- [ ] `SHA256SUMS` 可验证。
- [ ] Release staging 无真实配置和秘密。
- [ ] clone 与 tarball 安装行为一致。
- [ ] GitCode 公开下载 URL 已实测，不是猜测。
- [ ] 从干净 Ubuntu 环境完成安装/启动/停止/卸载。
- [ ] LICENSE 与第三方 notice 完整。

### P1，稳定版前

- [ ] checksum 签名与公钥发布。
- [ ] arm64 实机或可信 VM 验证。
- [ ] SBOM/provenance。
- [ ] 自动化构建与秘密扫描 CI。
- [ ] 已验证的 latest/channel 策略。
