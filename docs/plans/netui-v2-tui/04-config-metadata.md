# 04｜JSON 内容元数据与协议识别

## 1. 目标

配置表不能通过文件名推断协议。统一建立 `config_meta.sh`，让：

- TUI；
- URI 导入预览；
- probe 引擎；
- detail 页面；
- 测试断言

共享同一份内容解析结果。

## 2. 模块接口

新增：

```text
packages/netui/lib/config_meta.sh
```

建议接口：

```text
config_meta_extract <config-path>
config_meta_protocol_label <config-path>
config_meta_primary_outbound_json <config-path>
config_meta_probe_eligibility <config-path>
```

`config_meta_extract` 输出固定 TSV 或 JSON，不输出 shell assignment 供 `eval`。

建议 JSON shape：

```json
{
  "name": "office-reality",
  "basename": "office-reality.json",
  "family": "vless",
  "variant": "reality/vision",
  "display_protocol": "VLESS/TCP",
  "server": "192.0.2.10",
  "server_port": 443,
  "transport": "tcp",
  "security": "reality",
  "tls": true,
  "reality": true,
  "proxy_outbound_count": 1,
  "local_type": "mixed",
  "local_listen": "127.0.0.1",
  "local_port": 10808,
  "probe_supported": true,
  "probe_reason": ""
}
```

## 3. Primary outbound 规则

显示用 primary 与测速用 eligibility 分开定义。

显示用 primary：从 `.outbounds[]` 中选择第一个满足以下条件的 outbound：

- 有非空 `.type`；
- 排除 `direct`、`block`、`dns`；
- 排除只负责分组而无 server 的 `selector`、`urltest`；
- 优先具有 `.server` 和 `.server_port`；
- 若有多个代理 outbound，表格显示 primary，并标记 `+N`；该选择仅用于摘要，不能证明实际 route 最终使用它。

复杂配置：

- selector/urltest 引用多个 proxy 时，不假设哪一个正在生效；
- 主表可显示 `selector +N` 或 primary `+N`；
- 首版 probe 对无法唯一提取的配置显示 `unsupported`；
- 配置本身仍可设默认和运行，只是测速能力受限。

## 4. 协议分类

### VLESS REALITY Vision

条件：

```text
type == vless
tls.enabled == true
tls.reality.enabled == true
flow == xtls-rprx-vision
transport absent or tcp-compatible
```

输出：

```text
family=vless
variant=reality/vision
display_protocol=VLESS/TCP
transport=tcp
security=reality
```

### VLESS WebSocket TLS

条件：

```text
type == vless
transport.type == ws
tls.enabled == true
reality != true
```

输出：

```text
family=vless
variant=ws/tls
display_protocol=VLESS/WS
transport=ws
security=tls
```

### Hysteria2

条件：

```text
type == hysteria2
```

输出：

```text
family=hysteria2
variant=quic/tls
display_protocol=Hysteria2
transport=quic
security=quic-tls
```

### 其他

- 已知 outbound type：显示 type，未知 variant 留空。
- 无可识别 proxy outbound：`unknown`。
- 无法解析 JSON：`invalid`。
- 不把文件名中的 `hy2`、`vless`、`reality` 用作 fallback。

## 5. 表格名称

不引入配置数据库或 sidecar alias registry：

- `NAME` 默认是 basename 去掉 `.json`。
- URI fragment 经安全清洗后成为导入 basename，因此自然成为显示名。
- 外部 JSON 的名称仍由用户文件名控制。
- 后续若需要独立 alias，再另行设计 sidecar；首版不把未知字段写进 sing-box JSON。

## 6. 服务器和端口

- 地址从 primary proxy outbound 的 `.server` 提取。
- 端口从 `.server_port` 提取。
- 缺失时显示 `—`，不从 SNI、Host header 或 filename 猜测。
- IPv6 主表显示无方括号规范文本；footer 可显示 `[addr]:port`。
- 地址是本机可见敏感元数据：
  - 主 TUI 按用户要求显示；
  - `netui.log` 默认不记录；
  - VHS 和自动化只用 reserved/synthetic 地址。

## 7. 本地 endpoint

从 inbounds 中选择：

1. loopback `mixed`；
2. loopback `http`；
3. loopback `socks`。

逻辑应与 `runtime_write_endpoint` 共用或提取成 shared helper，避免 TUI 与 runtime 对 endpoint 选择不同。

主表不显示本地 endpoint；footer 显示当前运行实例 endpoint。

## 8. 校验状态

状态分开：

```text
JSON syntax
sing-box check
metadata extraction
probe eligibility
```

主表简化为：

- `ok`：JSON + sing-box check 通过；
- `bad`：配置无效；
- `dep`：校验依赖缺失；
- `…`：后台校验中。

响应性要求：

- discovery 与 jq metadata 先完成并立即显示；
- 完整 `sing-box check` 进入最多 2 个 worker 的队列；
- 每项默认 5 秒 timeout，可测试覆盖；
- 结果按 path + mtime + size/hash 关联，过期结果丢弃；
- refresh/退出时只取消 tracked worker；
- 50 个配置且 fake check 每项变慢时，方向键和日志仍可响应。

metadata unknown 不等于配置 invalid。

## 9. 缓存

TUI 会话内 metadata cache key：

```text
resolved path
mtime
size
sha256 when needed
```

策略：

- 首次发现做 `jq` 摘要。
- mtime/size 不变时复用。
- Enter/default/env 模式不使 metadata 失效。
- 文件导入、重命名、归档、手工 `r` 刷新时失效。
- probe cache 使用 SHA256，不只使用 basename。
- metadata 默认不持久化到磁盘，减少服务器地址复制。

## 10. 与当前代码的迁移

替换/下沉：

- `tui_protocol_for_config` -> `config_meta_protocol_label`
- `tui_local_for_config` -> shared endpoint metadata
- detail 页的 Reality 判断 -> metadata 字段
- 新增 server、server_port、transport、security

保留：

- `config_store_discover`
- `config_store_validate_config`
- runtime state 的 running basename/path/hash

## 11. Probe eligibility

允许首版完整测速的配置必须同时满足：

- 排除 direct/block/dns 后，**恰好一个**具有 server/server_port 的 proxy outbound；
- 支持类型为三类要求之一；
- 不存在 selector/urltest；
- proxy outbound 没有 `.detour`，其他 outbound 也不引用它形成链；
- outbound tag 缺失时只在私有 snapshot 中赋予唯一 `netui-probe-proxy`；tag 重复直接 unsupported；
- probe snapshot 保留 top-level DNS，但用新的 loopback mixed inbound 替换全部 inbounds，并把 route 重建为 `auto_detect_interface + final=<unique-proxy-tag>`；
- 原 route rule、rule_set 或 DNS rule 若依赖被移除的 inbound tag，则该配置 unsupported，不猜测改写；
- 没有 TUN、redirect、tproxy 等需要系统权限的 inbound；
- 最终 snapshot 必须再次通过 sing-box check 才能启动。

不支持时返回值无关原因：

```text
multiple proxy outbounds
selector graph unsupported
unsupported outbound type
unsafe inbound type
missing server metadata
```

配置仍能正常显示和运行。

## 12. 测试矩阵

- 文件名 `fake-hy2.json` + VLESS REALITY 内容 -> VLESS。
- 文件名 `reality.json` + Hysteria2 内容 -> Hysteria2。
- VLESS REALITY Vision。
- VLESS WS TLS + ALPN/Host/path。
- Hysteria2 insecure。
- direct + proxy 顺序变化。
- selector/urltest + multiple proxies。
- missing server/port。
- IPv4、域名、IPv6。
- invalid JSON。
- valid unknown protocol。
- metadata cache invalidates after content change。
- table summary never contains UUID/password/key。
