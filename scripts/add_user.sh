#!/bin/bash

# add_user.sh —— 用 FluxEnv 仓库模板一键创建新用户（zsh + Starship + sudo/docker 组 + SSH 目录）。
#
# 泛化自原始手工脚本：不再从 /home/winbeau 复制个人配置，全部改取仓库资产：
#   zshrc.txt                              → ~/.zshrc（zsh 模板，含 starship init 与插件加载）
#   内嵌 bare-metal Starship 模板          → ~/.config/starship.toml（与 lib/steps/user_shell.sh 生成内容一致）
#   offline_resources/starship-*.tar.gz    → starship 二进制（按架构离线优先，缺失才在线装）
#   offline_resources/zsh-autosuggestions、zsh-syntax-highlighting → ~/.zsh/plugins/
#
# 用法（在仓库内运行，非 root 自动用 sudo 重执行）：
#   bash scripts/add_user.sh                # 交互输入用户名和密码
#   bash scripts/add_user.sh alice          # 用户名用参数，密码交互输入
#
# 行为：
#   - 安装 sudo / zsh / curl / ca-certificates（已装则跳过），starship 二进制缺失时安装
#   - 建 docker 组（不装 Docker 本体），用户加入 sudo,docker 组
#   - 用户已存在则复用，仅更新权限/Shell/配置（旧配置先备份 *.backup.*）
#   - 密码交互输入两次；留空则跳过（账户保持锁定，需自行 passwd）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLUXENV_ROOT="$(dirname "$SCRIPT_DIR")"
ZSHRC_TEMPLATE="$FLUXENV_ROOT/zshrc.txt"
OFFLINE_DIR="$FLUXENV_ROOT/offline_resources"

NEW_USER="${1:-}"
NEW_HOME=""
PRIMARY_GROUP=""

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

need_root() { [ "$(id -u)" -eq 0 ] || die "请用 sudo/root 运行（或直接 bash scripts/add_user.sh 自动提权）"; }

backup_path() {
    local path="$1"
    [ -e "$path" ] || return 0
    cp -a "$path" "${path}.backup.$(date +%Y%m%d_%H%M%S)"
    progress "已备份: $path"
}

prompt_username() {
    local candidate="$1"
    while true; do
        if [ -z "$candidate" ]; then
            read -r -p "请输入新用户名: " candidate
        fi
        if [[ "$candidate" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            NEW_USER="$candidate"
            return 0
        fi
        warn "用户名不合法（小写字母/数字/下划线/中划线，字母或下划线开头），请重试"
        candidate=""
    done
}

prompt_password() {
    local pass1="" pass2=""
    while true; do
        read -r -s -p "请输入 ${NEW_USER} 的登录密码（留空则跳过）: " pass1
        echo
        [ -z "$pass1" ] && return 1
        read -r -s -p "请再次输入确认: " pass2
        echo
        if [ "$pass1" = "$pass2" ]; then
            printf '%s:%s\n' "$NEW_USER" "$pass1" | chpasswd
            return 0
        fi
        warn "两次输入不一致，请重试"
    done
}

install_packages() {
    local miss=()
    for c in sudo zsh curl; do
        command -v "$c" >/dev/null 2>&1 || miss+=("$c")
    done
    if [ "${#miss[@]}" -gt 0 ]; then
        progress "apt-get 安装: ${miss[*]}"
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${miss[@]}" ca-certificates
    fi
}

install_starship_binary() {
    if command -v starship >/dev/null 2>&1; then
        ok "starship 已安装: $(starship --version | head -1)"
        return 0
    fi

    local arch_name="$(uname -m)"
    local archive_path=""
    case "$arch_name" in
        x86_64|amd64)        archive_path="$OFFLINE_DIR/starship-x86_64-unknown-linux-gnu.tar.gz" ;;
        aarch64|arm64)       archive_path="$OFFLINE_DIR/starship-aarch64-unknown-linux-gnu.tar.gz" ;;
        armv7l|armv7)        archive_path="$OFFLINE_DIR/starship-armv7-unknown-linux-gnueabihf.tar.gz" ;;
    esac

    if [ -n "$archive_path" ] && [ -f "$archive_path" ]; then
        progress "从离线包安装 starship（$arch_name）…"
        tmpdir="$(mktemp -d)"
        tar -xzf "$archive_path" -C "$tmpdir"
        install -m 0755 "$tmpdir/starship" /usr/local/bin/starship
        rm -rf "$tmpdir"
        ok "starship 离线安装完成"
        return 0
    fi

    warn "当前架构 ${arch_name} 无离线包，尝试在线安装…"
    curl -sS https://starship.rs/install.sh | sh -s -- -y -b /usr/local/bin
    command -v starship >/dev/null 2>&1 || warn "starship 安装失败（不影响其余配置）"
}

install_plugins() {
    local user_home="$1"
    local target_dir="$user_home/.zsh/plugins"
    mkdir -p "$target_dir"

    for plugin in zsh-autosuggestions zsh-syntax-highlighting; do
        if [ -d "$OFFLINE_DIR/$plugin" ] && [ -n "$(ls -A "$OFFLINE_DIR/$plugin" 2>/dev/null)" ]; then
            backup_path "$target_dir/$plugin"
            rm -rf "$target_dir/$plugin"
            cp -a "$OFFLINE_DIR/$plugin" "$target_dir/$plugin"
            ok "插件 $plugin 已就位"
        else
            warn "离线插件 $plugin 缺失，跳过（zshrc 中对应 source 会静默忽略）"
        fi
    done

    chown -R "$NEW_USER:$PRIMARY_GROUP" "$user_home/.zsh"
}

write_configs() {
    local user_home="$1"

    [ -f "$ZSHRC_TEMPLATE" ] || die "找不到仓库模板: $ZSHRC_TEMPLATE（请在 FluxEnv 仓库内运行）"

    progress "复制 $ZSHRC_TEMPLATE → $user_home/.zshrc"
    backup_path "$user_home/.zshrc"
    install -o "$NEW_USER" -g "$PRIMARY_GROUP" -m 644 "$ZSHRC_TEMPLATE" "$user_home/.zshrc"

    progress "写入 $user_home/.config/starship.toml（仓库 bare-metal 模板）"
    backup_path "$user_home/.config/starship.toml"
    install -d -o "$NEW_USER" -g "$PRIMARY_GROUP" -m 755 "$user_home/.config"
    cat > "$user_home/.config/starship.toml" <<'EOF'
# ~/.config/starship.toml

# 1. 配置用户名 (User)
[username]
style_user = "yellow bold"
style_root = "red bold"
format = "[$user]($style)"
show_always = true

# 2. 配置主机名 (Hostname)
[hostname]
ssh_only = false
format = "@[$hostname]($style) "
trim_at = "."
style = "cyan"

# 3. 禁用编程语言环境显示
[python]
disabled = false
symbol = " "

[java]
symbol = " "
style = "yellow"

[nodejs]
disabled = true

[golang]
disabled = true

# =======================
# 2. 路径 (视觉焦点)
# =======================
[directory]
style = "yellow"
truncation_length = 4
truncation_symbol = "…/"
format = "[$path]($style)[$read_only]($read_only_style) "

# =======================
# 3. Git 状态 (优雅点缀)
# =======================
[git_branch]
symbol = ""
style = "purple bold"
format = "[$symbol$branch]($style)"

[git_status]
disabled = false
format = ' ([$all_status$ahead_behind]($style) )'
style = "red bold"
staged = "[+](green) "
modified = "[!](red) "
untracked = "[?](yellow) "
deleted = "[✘](red) "
renamed = "[»](yellow) "
conflicted = "[=](red bold) "
stashed = "[$](cyan) "
ahead = "⇡"
behind = "⇣"
diverged = "⇕"
up_to_date = ""

# =======================
# 4. Conda 环境 (重写标识)
# =======================
[conda]
disabled = false
ignore_base = false
style = "#78E08F bold"
symbol = ""
format = '[\($symbol$environment\)]($style) '

# =======================
# 5. 提示符 (灵动指针)
# =======================
[character]
success_symbol = "[❯](white bold)"
error_symbol = "[❯](red bold)"
vimcmd_symbol = "[❮](green bold)"
EOF
    chown "$NEW_USER:$PRIMARY_GROUP" "$user_home/.config/starship.toml"

    progress "创建 $user_home/.ssh/authorized_keys（空占位）"
    install -d -o "$NEW_USER" -g "$PRIMARY_GROUP" -m 700 "$user_home/.ssh"
    install -o "$NEW_USER" -g "$PRIMARY_GROUP" -m 600 /dev/null "$user_home/.ssh/authorized_keys"

    grep -qF 'starship init zsh' "$user_home/.zshrc" || \
        printf '\n# Starship prompt\neval "$(starship init zsh)"\n' >> "$user_home/.zshrc"
}

create_user() {
    stage "准备用户 ${NEW_USER}"
    groupadd -f docker

    if id "$NEW_USER" >/dev/null 2>&1; then
        ok "用户已存在，更新权限和 Shell"
    else
        useradd -m -U -s /usr/bin/zsh "$NEW_USER"
        ok "已创建用户（家目录 + 主组 + zsh）"
    fi

    usermod -aG sudo,docker "$NEW_USER"
    usermod -s /usr/bin/zsh "$NEW_USER"

    PRIMARY_GROUP="$(id -gn "$NEW_USER")"
    if [ "$NEW_USER" = "root" ]; then
        NEW_HOME="/root"
    else
        NEW_HOME="$(getent passwd "$NEW_USER" | cut -d: -f6)"
        [ -n "$NEW_HOME" ] || NEW_HOME="/home/$NEW_USER"
    fi
}

main() {
    init_colors
    [ -f "$ZSHRC_TEMPLATE" ] || die "找不到仓库模板: $ZSHRC_TEMPLATE（请在 FluxEnv 仓库内运行）"

    if [ "$(id -u)" -ne 0 ]; then
        echo "检测到非 root，自动用 sudo 重执行…"
        exec sudo -E bash "$0" "$@"
    fi

    need_root
    prompt_username "$NEW_USER"

    stage "安装依赖"
    install_packages
    install_starship_binary

    create_user

    stage "写入配置（来自仓库模板）"
    write_configs "$NEW_HOME"
    install_plugins "$NEW_HOME"

    stage "设置登录密码"
    if prompt_password; then
        ok "密码已设置"
    else
        warn "未设置密码，账户 ${NEW_USER} 保持锁定（可稍后执行: sudo passwd ${NEW_USER}）"
    fi

    echo
    echo "================ 创建完成 ================"
    id "$NEW_USER"
    echo "Shell   : $(getent passwd "$NEW_USER" | cut -d: -f7)"
    echo "Starship: $(command -v starship || echo '未安装')"
    echo
    echo "登录测试: su - ${NEW_USER}"
}

main "$@"
