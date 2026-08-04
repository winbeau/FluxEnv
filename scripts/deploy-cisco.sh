#!/bin/bash

# deploy-cisco.sh —— 一键部署 ISRC Cisco AnyConnect VPN（openconnect + systemd 服务 + ciscoup 命令）。
#
# 覆盖 `ciscoup` 命令背后的整套资产：
#   /usr/local/sbin/cisco-vpn-run          openconnect 运行脚本（0700 root，密码经 /run 一次性 secret 注入）
#   /etc/systemd/system/cisco-vpn.service  VPN 服务单元（按需启动，默认不随开机自启）
#   ~/bin/ciscoup                          一键连接命令（输 PIN 码+动态码 → 起服务 → 探测隧道）
#
# 脚本自动完成：systemd 前置检查、创建所需目录（/usr/local/sbin、~/bin）、
# apt 安装 openconnect / iproute2（已装则跳过）。
#
# 用法（仓库根目录）：
#   bash scripts/deploy-cisco.sh            # 一键部署（非 root 时自动用 sudo 重执行）
#   bash scripts/deploy-cisco.sh remove     # 卸载（停服务、删文件；*.backup.* 备份保留）
#
# 环境变量（可选）：
#   CISCO_USER=yanmengdie24           VPN 账号
#   CISCO_AUTHGROUP='T-员工'          AnyConnect 认证组
#   CISCO_SERVER=https://link.isrc.ac.cn  服务器
#   CISCO_INTERFACE=ciscovpn0         隧道网卡名
#   CISCO_ROUTE_CHECK=10.20.173.1     连接成功后探测的内网网关
#   CISCO_ENABLE=1                    额外执行 systemctl enable（开机自启，默认关闭）
#
# 部署完成后连接 VPN： ciscoup   → 输入「PIN 码 + 当前动态码」

set -euo pipefail

ACTION="${1:-install}"

USER_VAL="${CISCO_USER:-yanmengdie24}"
AUTHGROUP_VAL="${CISCO_AUTHGROUP:-T-员工}"
SERVER_VAL="${CISCO_SERVER:-https://link.isrc.ac.cn}"
IFACE_VAL="${CISCO_INTERFACE:-ciscovpn0}"
ROUTE_VAL="${CISCO_ROUTE_CHECK:-10.20.173.1}"
ENABLE_SVC="${CISCO_ENABLE:-0}"

SERVICE_UNIT="/etc/systemd/system/cisco-vpn.service"
RUN_SCRIPT="/usr/local/sbin/cisco-vpn-run"
SECRET_FILE="/run/cisco-vpn.secret"

# 安装给「发起 sudo 的用户」；直接 root 会话则装到 /root/bin
INSTALL_USER="${SUDO_USER:-root}"
if [ "$INSTALL_USER" = "root" ]; then
    USER_HOME="/root"
else
    USER_HOME="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
    [ -n "$USER_HOME" ] || USER_HOME="/home/$INSTALL_USER"
fi
CISCOUP_BIN="$USER_HOME/bin/ciscoup"

init_colors() {
    if [ -t 1 ]; then
        GREEN=$(printf '\033[32m'); YELLOW=$(printf '\033[33m')
        RED=$(printf '\033[31m'); BOLD=$(printf '\033[1m'); RESET=$(printf '\033[m')
    else
        GREEN=""; YELLOW=""; RED=""; BOLD=""; RESET=""
    fi
}
stage()    { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$RESET"; }
progress() { printf '  → %s\n' "$*"; }
ok()       { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()     { printf '%s警告: %s%s\n' "$YELLOW" "$*" "$RESET" >&2; }
die()      { printf '%s错误: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "请用 sudo/root 运行（或直接 bash scripts/deploy-cisco.sh 自动提权）"; }

backup_path() {
    local path="$1"
    [ -e "$path" ] || return 0
    cp -a "$path" "${path}.backup.$(date +%Y%m%d_%H%M%S)"
    progress "已备份: $path"
}

install_cisco() {
    need_root

    stage "前置检查与依赖安装"
    [ -d /run/systemd/system ] || die "未检测到 systemd（本方案依赖 systemd 服务）"
    install -d -m 755 /usr/local/sbin
    local miss=()
    command -v openconnect >/dev/null 2>&1 || miss+=(openconnect)
    command -v ip >/dev/null 2>&1 || miss+=(iproute2)
    if [ "${#miss[@]}" -gt 0 ]; then
        progress "apt-get 安装: ${miss[*]}"
        apt-get update -qq
        apt-get install -y -qq "${miss[@]}"
        command -v openconnect >/dev/null 2>&1 || die "openconnect 安装失败"
        ok "依赖安装完成: ${miss[*]}"
    else
        ok "依赖已就绪: openconnect / ip"
    fi

    stage "写入 $RUN_SCRIPT"
    backup_path "$RUN_SCRIPT"
    cat > "$RUN_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SECRET_FILE="/run/cisco-vpn.secret"

if [[ ! -s "$SECRET_FILE" ]]; then
    echo "Please input secret：$SECRET_FILE" >&2
    exit 1
fi

# 先打开文件描述符，再立即删除密码文件
exec 3<"$SECRET_FILE"
rm -f "$SECRET_FILE"

exec /usr/sbin/openconnect \
    --verbose \
    --protocol=anyconnect \
    --user='@CISCO_USER@' \
    --authgroup='@CISCO_AUTHGROUP@' \
    --interface='@CISCO_INTERFACE@' \
    --passwd-on-stdin \
    --no-dtls \
    '@CISCO_SERVER@' <&3
EOF
    sed -i "s|@CISCO_USER@|$USER_VAL|g; s|@CISCO_AUTHGROUP@|$AUTHGROUP_VAL|g; s|@CISCO_INTERFACE@|$IFACE_VAL|g; s|@CISCO_SERVER@|$SERVER_VAL|g" "$RUN_SCRIPT"
    chmod 700 "$RUN_SCRIPT"
    bash -n "$RUN_SCRIPT"
    ok "已安装（0700 root）"

    stage "写入 $SERVICE_UNIT"
    backup_path "$SERVICE_UNIT"
    cat > "$SERVICE_UNIT" <<'EOF'
[Unit]
Description=ISRC Cisco-compatible VPN
Wants=network-online.target
After=network-online.target
Conflicts=shutdown.target

[Service]
Type=simple
ExecStartPre=/usr/bin/test -s /run/cisco-vpn.secret
ExecStart=/usr/local/sbin/cisco-vpn-run
KillSignal=SIGINT
TimeoutStopSec=30
Restart=no
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SERVICE_UNIT"
    systemctl daemon-reload
    if [ "$ENABLE_SVC" = "1" ]; then
        systemctl enable cisco-vpn.service
        ok "已 systemctl enable（开机自启）"
    else
        ok "服务单元已就绪（按需启动，未开机自启；需要时用 CISCO_ENABLE=1）"
    fi

    stage "写入 $CISCOUP_BIN"
    backup_path "$CISCOUP_BIN"
    mkdir -p "$USER_HOME/bin"
    cat > "$CISCOUP_BIN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SERVICE="cisco-vpn.service"
SECRET_FILE="/run/cisco-vpn.secret"
INTERFACE="@CISCO_INTERFACE@"

if systemctl is-active --quiet "$SERVICE"; then
    echo "ISRC VPN 已经连接"
    ip -4 -brief address show "$INTERFACE" 2>/dev/null || true
    exit 0
fi

sudo -v

read -rsp "请输入 VPN 密码（PIN码+当前动态码）: " vpn_password
echo

sudo install -m 600 -o root -g root /dev/null "$SECRET_FILE"
printf '%s\n' "$vpn_password" | sudo tee "$SECRET_FILE" >/dev/null
unset vpn_password

sudo systemctl reset-failed "$SERVICE" 2>/dev/null || true

if ! sudo systemctl start "$SERVICE"; then
    sudo rm -f "$SECRET_FILE"
    sudo journalctl -u "$SERVICE" -n 30 --no-pager
    exit 1
fi

for _ in {1..20}; do
    if [[ -d "/sys/class/net/$INTERFACE" ]]; then
        echo "ISRC VPN 已连接"
        ip -4 -brief address show "$INTERFACE"
        ip route get @CISCO_ROUTE_CHECK@
        exit 0
    fi

    if ! systemctl is-active --quiet "$SERVICE"; then
        echo "VPN 连接失败："
        sudo journalctl -u "$SERVICE" -n 30 --no-pager
        exit 1
    fi

    sleep 1
done

echo "VPN 服务正在运行，但尚未检测到隧道接口"
sudo journalctl -u "$SERVICE" -n 30 --no-pager
exit 1
EOF
    sed -i "s|@CISCO_INTERFACE@|$IFACE_VAL|g; s|@CISCO_ROUTE_CHECK@|$ROUTE_VAL|g" "$CISCOUP_BIN"
    chmod 700 "$CISCOUP_BIN"
    chown "$INSTALL_USER" "$CISCOUP_BIN"
    bash -n "$CISCOUP_BIN"
    ok "已安装 $CISCOUP_BIN（0700 $INSTALL_USER）"

    stage "校验"
    if systemd-analyze verify "$SERVICE_UNIT" >/dev/null 2>&1; then
        ok "systemd 单元语法检查通过"
    else
        warn "systemd-analyze verify 有告警（一般不影响使用）："
        systemd-analyze verify "$SERVICE_UNIT" || true
    fi

    echo
    echo "================ 部署完成 ================"
    echo "  VPN 账号   : $USER_VAL"
    echo "  Authgroup  : $AUTHGROUP_VAL"
    echo "  服务器     : $SERVER_VAL"
    echo "  隧道接口   : $IFACE_VAL"
    echo
    echo "连接 VPN（提示输入 PIN 码 + 当前动态码）:"
    echo "    ciscoup"
    echo "查看状态 / 日志:"
    echo "    systemctl status cisco-vpn.service"
    if ! command -v ciscoup >/dev/null 2>&1; then
        warn "$CISCOUP_BIN 不在 PATH，可执行: export PATH=\"\$HOME/bin:\$PATH\"（或写入 ~/.zshrc）"
    fi
}

remove_cisco() {
    need_root

    stage "卸载 cisco-vpn 服务"
    systemctl stop cisco-vpn.service 2>/dev/null || true
    systemctl disable cisco-vpn.service 2>/dev/null || true
    rm -f "$SERVICE_UNIT" "$RUN_SCRIPT" "$SECRET_FILE"
    systemctl daemon-reload
    ok "已移除 $SERVICE_UNIT / $RUN_SCRIPT"

    if [ -f "$CISCOUP_BIN" ]; then
        rm -f "$CISCOUP_BIN"
        ok "已移除 $CISCOUP_BIN"
    fi
    echo "说明: *.backup.* 备份文件已保留，可直接改名恢复。"
}

init_colors

if [ "$(id -u)" -ne 0 ]; then
    echo "检测到非 root，自动用 sudo 重执行…"
    exec sudo -E bash "$0" "$@"
fi

case "$ACTION" in
    install) install_cisco ;;
    remove)  remove_cisco ;;
    *) die "未知动作: $ACTION（支持 install / remove）" ;;
esac
