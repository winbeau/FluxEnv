#!/bin/bash

set -u

script_dir=$(cd -P -- "${0%/*}" && pwd -P)
repo_root=$(cd -P -- "$script_dir/../.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/netui-config-meta.XXXXXX")
failures=0
checks=0

cleanup() {
    rm -rf -- "$test_root"
}
trap cleanup EXIT HUP INT TERM

# shellcheck source=../../packages/netui/lib/config_meta.sh
source "$repo_root/packages/netui/lib/config_meta.sh"

assert_status() {
    local expected=$1
    local label=$2
    shift 2
    local actual=0

    checks=$((checks + 1))
    "$@"
    actual=$?
    if ((actual != expected)); then
        printf 'FAIL: %s (expected %s, got %s)\n' "$label" "$expected" "$actual" >&2
        failures=$((failures + 1))
    else
        printf 'ok: %s\n' "$label"
    fi
}

assert_true() {
    local label=$1
    shift

    checks=$((checks + 1))
    if "$@"; then
        printf 'ok: %s\n' "$label"
    else
        printf 'FAIL: %s\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

assert_json_query() {
    local label=$1
    local json=$2
    local query=$3

    checks=$((checks + 1))
    if jq -e "$query" <<< "$json" >/dev/null 2>&1; then
        printf 'ok: %s\n' "$label"
    else
        printf 'FAIL: %s\n' "$label" >&2
        failures=$((failures + 1))
    fi
}

config_meta_protocol_label_silent() {
    config_meta_protocol_label "$1" >/dev/null
}

write_reality_fixture() {
    local path=$1
    local server=${2:-192.0.2.10}
    local port=${3:-443}

    cat > "$path" <<EOF
{
    "log": {"level": "info", "timestamp": true},
    "inbounds": [
        {"type": "http", "listen": "127.0.0.1", "listen_port": 18080},
        {"type": "mixed", "listen": "127.0.0.1", "listen_port": 10808}
    ],
    "outbounds": [
        {
            "type": "vless",
            "tag": "synthetic-proxy",
            "server": "$server",
            "server_port": $port,
            "uuid": "00000000-0000-4000-8000-000000000001",
            "flow": "xtls-rprx-vision",
            "tls": {
                "enabled": true,
                "server_name": "reality.example.invalid",
                "utls": {"enabled": true, "fingerprint": "chrome"},
                "reality": {
                    "enabled": true,
                    "public_key": "SYNTHETIC-REALITY-PUBLIC-KEY",
                    "private_key": "SYNTHETIC-REALITY-PRIVATE-KEY",
                    "short_id": "0123456789abcdef"
                }
            }
        },
        {"type": "direct", "tag": "direct"}
    ]
}
EOF
    chmod 600 -- "$path"
}

write_ws_fixture() {
    local path=$1

    cat > "$path" <<'EOF'
{
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 10808}],
    "outbounds": [{
        "type": "vless",
        "server": "ws.example.invalid",
        "server_port": 443,
        "uuid": "00000000-0000-4000-8000-000000000002",
        "tls": {
            "enabled": true,
            "server_name": "proxy.example.invalid",
            "utls": {"enabled": true, "fingerprint": "chrome"}
        },
        "transport": {
            "type": "ws",
            "path": "/synthetic",
            "headers": {"Host": "proxy.example.invalid", "Authorization": "SYNTHETIC-AUTHORIZATION"}
        }
    }]
}
EOF
    chmod 600 -- "$path"
}

write_hysteria_fixture() {
    local path=$1

    cat > "$path" <<'EOF'
{
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 10808}],
    "outbounds": [{
        "type": "hysteria2",
        "server": "hy.example.invalid",
        "server_port": 443,
        "password": "SYNTHETIC-HY2-PASSWORD",
        "tls": {"enabled": true, "server_name": "hy.example.invalid", "insecure": true},
        "obfs": {"type": "salamander", "password": "SYNTHETIC-OBFS-PASSWORD"}
    }]
}
EOF
    chmod 600 -- "$path"
}

reality_path="$test_root/fake-hy2.json"
ws_path="$test_root/vless-ws.json"
hysteria_path="$test_root/reality.json"
invalid_path="$test_root/invalid.json"
selector_path="$test_root/selector.json"
missing_path="$test_root/missing-server.json"
changed_path="$test_root/changed.json"
symlink_path="$test_root/escape.json"

write_reality_fixture "$reality_path"
write_ws_fixture "$ws_path"
write_hysteria_fixture "$hysteria_path"
printf '{not valid json\n' > "$invalid_path"
chmod 600 -- "$invalid_path"
cat > "$selector_path" <<'EOF'
{
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 10808}],
    "outbounds": [
        {"type": "selector", "tag": "select", "outbounds": ["proxy-a", "proxy-b"]},
        {"type": "vless", "tag": "proxy-a", "server": "192.0.2.11", "server_port": 443},
        {"type": "hysteria2", "tag": "proxy-b", "server": "hy.example.invalid", "server_port": 443}
    ]
}
EOF
chmod 600 -- "$selector_path"
cat > "$missing_path" <<'EOF'
{
    "inbounds": [{"type": "mixed", "listen": "127.0.0.1", "listen_port": 10808}],
    "outbounds": [{"type": "hysteria2", "password": "SYNTHETIC-PASSWORD"}]
}
EOF
chmod 600 -- "$missing_path"
ln -s -- "$reality_path" "$symlink_path"

reality_meta=$(config_meta_extract "$reality_path")
ws_meta=$(config_meta_extract "$ws_path")
hysteria_meta=$(config_meta_extract "$hysteria_path")
invalid_meta=$(config_meta_extract "$invalid_path")
selector_meta=$(config_meta_extract "$selector_path")
missing_meta=$(config_meta_extract "$missing_path")

assert_json_query 'filename mismatch still identifies VLESS REALITY' "$reality_meta" '.basename == "fake-hy2.json" and .display_protocol == "VLESS/TCP" and .family == "vless" and .variant == "reality/vision"'
assert_json_query 'VLESS metadata extracts server and port from content' "$reality_meta" '.server == "192.0.2.10" and .server_port == 443 and .security == "reality" and .transport == "tcp"'
assert_json_query 'mixed endpoint wins over lower-priority HTTP endpoint' "$reality_meta" '.local_type == "mixed" and .local_listen == "127.0.0.1" and .local_port == 10808'
assert_json_query 'filename mismatch identifies Hysteria2 from content' "$hysteria_meta" '.basename == "reality.json" and .display_protocol == "Hysteria2" and .family == "hysteria2" and .transport == "quic" and .security == "quic-tls"'
assert_json_query 'VLESS WebSocket TLS metadata is content-derived' "$ws_meta" '.display_protocol == "VLESS/WS" and .transport == "ws" and .security == "tls"'
assert_json_query 'selector graph is not probe eligible' "$selector_meta" '.proxy_outbound_count == 2 and .probe_supported == false and .probe_reason == "selector-graph-unsupported"'
assert_json_query 'missing server metadata stays classified but unsupported' "$missing_meta" '.family == "hysteria2" and .server == null and .server_port == null and .probe_reason == "missing-server-metadata"'
assert_json_query 'invalid JSON returns valid invalid metadata' "$invalid_meta" '.metadata_status == "invalid" and .family == "invalid" and .display_protocol == "invalid" and .primary_outbound == null'
assert_json_query 'invalid metadata output itself is valid JSON' "$invalid_meta" 'type == "object"'
assert_status 0 'protocol label helper succeeds for invalid JSON' config_meta_protocol_label_silent "$invalid_path"
assert_true 'protocol label helper reports invalid without content' test "$(config_meta_protocol_label "$invalid_path")" = invalid

redaction_reality_output=$(
    config_meta_extract "$reality_path"
    config_meta_protocol_label "$reality_path"
    config_meta_primary_outbound_json "$reality_path"
    config_meta_probe_eligibility "$reality_path"
)
redaction_ws_output=$(
    config_meta_extract "$ws_path"
    config_meta_protocol_label "$ws_path"
    config_meta_primary_outbound_json "$ws_path"
    config_meta_probe_eligibility "$ws_path"
)
redaction_hysteria_output=$(
    config_meta_extract "$hysteria_path"
    config_meta_protocol_label "$hysteria_path"
    config_meta_primary_outbound_json "$hysteria_path"
    config_meta_probe_eligibility "$hysteria_path"
)
for marker in \
    SYNTHETIC-REALITY-PUBLIC-KEY \
    SYNTHETIC-REALITY-PRIVATE-KEY \
    0123456789abcdef \
    00000000-0000-4000-8000-000000000001; do
    assert_true "REALITY metadata output omits secret marker $marker" bash -c '! grep -Fq -- "$1" <<< "$2"' -- "$marker" "$redaction_reality_output"
done
for marker in \
    SYNTHETIC-AUTHORIZATION \
    00000000-0000-4000-8000-000000000002; do
    assert_true "WebSocket metadata output omits secret marker $marker" bash -c '! grep -Fq -- "$1" <<< "$2"' -- "$marker" "$redaction_ws_output"
done
for marker in SYNTHETIC-HY2-PASSWORD SYNTHETIC-OBFS-PASSWORD; do
    assert_true "Hysteria2 metadata output omits secret marker $marker" bash -c '! grep -Fq -- "$1" <<< "$2"' -- "$marker" "$redaction_hysteria_output"
done

before_mtime=$(stat -c '%Y:%s' -- "$reality_path")
reality_projection=$(config_meta_primary_outbound_json "$reality_path")
after_mtime=$(stat -c '%Y:%s' -- "$reality_path")
assert_true 'primary outbound helper returns a redacted projection' bash -c '[[ "$1" == *"VLESS"* || "$1" == *"vless"* ]] && [[ "$1" != *"SYNTHETIC-REALITY"* ]]' -- "$reality_projection"
assert_true 'metadata extraction does not modify source file' test "$before_mtime" = "$after_mtime"
assert_status 5 'metadata rejects symlink input' config_meta_extract "$symlink_path"

write_reality_fixture "$changed_path" 198.51.100.12 8443
changed_meta=$(config_meta_extract "$changed_path")
assert_json_query 'metadata reflects changed content on the next read' "$changed_meta" '.server == "198.51.100.12" and .server_port == 8443'

if ((failures > 0)); then
    printf '\n%s of %s config metadata checks failed\n' "$failures" "$checks" >&2
    exit 1
fi

printf '\nAll %s config metadata checks passed\n' "$checks"
