#!/bin/bash

set -euo pipefail

script_path=$(realpath -e -- "$0") || exit 1
package_root=$(cd -P -- "${script_path%/*}/.." && pwd -P) || exit 1
repo_root=$(cd -P -- "$package_root/../.." && pwd -P) || exit 1

# shellcheck source=../lib/install_core.sh
source "$package_root/lib/install_core.sh"

allow_dirty=0
preview=0
asset_dir=''
output_dir="$repo_root/artifacts/netui/release"
release_base_url=''
skip_smoke=0
skip_visual=0

usage() {
    cat <<'EOF'
Usage:
  bash packages/netui/scripts/build-release.sh [options]

Options:
  --asset-dir PATH           Use exact locked upstream archives from PATH.
  --output-dir PATH          Write release assets to PATH.
  --release-base-url URL     Verified HTTPS directory containing release assets.
  --allow-dirty              Permit a local preview from a dirty worktree.
  --preview                  Allow an unconfigured bootstrap for local preview.
  --skip-smoke               Skip local install smoke tests (preview only).
  --skip-visual              Skip VHS visual smoke (preview only).
  --help                     Show this help.
EOF
}

while (($# > 0)); do
    case "$1" in
        --asset-dir)
            (($# >= 2)) || { install_core_error '--asset-dir requires a path'; exit 2; }
            asset_dir=$2
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || { install_core_error '--output-dir requires a path'; exit 2; }
            output_dir=$2
            shift 2
            ;;
        --release-base-url)
            (($# >= 2)) || { install_core_error '--release-base-url requires a URL'; exit 2; }
            release_base_url=$2
            shift 2
            ;;
        --allow-dirty)
            allow_dirty=1
            shift
            ;;
        --preview)
            preview=1
            shift
            ;;
        --skip-smoke)
            skip_smoke=1
            shift
            ;;
        --skip-visual)
            skip_visual=1
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            install_core_error "unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
done

version=$(install_core_read_version "$package_root") || {
    install_core_error 'VERSION is missing or invalid'
    exit 1
}
install_core_validate_source_tree "$package_root"

if ((allow_dirty == 0)) && [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=all)" ]]; then
    install_core_error 'Git worktree is dirty; use --allow-dirty only for local preview'
    exit 1
fi
if ((allow_dirty && preview == 0)); then
    install_core_error '--allow-dirty requires --preview'
    exit 2
fi
if ((skip_smoke && preview == 0)); then
    install_core_error '--skip-smoke is only allowed for preview'
    exit 2
fi
if ((skip_visual && preview == 0)); then
    install_core_error '--skip-visual is only allowed for preview'
    exit 2
fi

if [[ -z "$release_base_url" ]]; then
    if ((preview)); then
        release_base_url='__NETUI_RELEASE_BASE_URL__'
    else
        install_core_error 'a verified --release-base-url is required for a publishable build'
        exit 1
    fi
fi
if [[ "$release_base_url" == '__NETUI_RELEASE_BASE_URL__' ]]; then
    ((preview)) || {
        install_core_error 'a verified HTTPS release base URL is required'
        exit 1
    }
elif [[ "$release_base_url" != https://* || "$release_base_url" == *[[:space:]]* ]]; then
    install_core_error 'release base URL must be an HTTPS URL without whitespace'
    exit 1
fi

validate_manifest() {
    local row_count=0
    local name=''
    local asset_version=''
    local os_name=''
    local arch=''
    local url=''
    local sha256=''
    local license_name=''
    local note=''
    local key=''
    declare -A seen=()

    while IFS=$'\t' read -r name asset_version os_name arch url sha256 license_name note; do
        [[ -n "$name" && "$name" != \#* ]] || continue
        row_count=$((row_count + 1))
        [[ "$name" == sing-box || "$name" == gum ]] || {
            install_core_error "unexpected manifest asset: $name"
            return 1
        }
        [[ "$asset_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || return 1
        [[ "$os_name" == linux && ("$arch" == amd64 || "$arch" == arm64) ]] || return 1
        [[ "$url" == https://* && "$url" != *latest* && "$url" != *HEAD* ]] || return 1
        [[ "$sha256" =~ ^[0-9a-f]{64}$ && "$sha256" != - ]] || return 1
        [[ -n "$license_name" && "$license_name" != - && -n "$note" ]] || return 1
        key="$name/$arch"
        [[ -z "${seen[$key]+set}" ]] || {
            install_core_error "duplicate manifest row: $key"
            return 1
        }
        seen[$key]=1
    done < "$package_root/manifest.lock"

    [[ "$row_count" == 4 ]] || {
        install_core_error "manifest must contain exactly four locked Linux assets, got $row_count"
        return 1
    }
    for key in sing-box/amd64 sing-box/arm64 gum/amd64 gum/arm64; do
        [[ -n "${seen[$key]+set}" ]] || {
            install_core_error "manifest is missing $key"
            return 1
        }
    done
}

secret_scan() {
    local scan_root=$1
    local matches=''

    matches=$(grep -RInE --exclude='*.sha256' --exclude='build-release.sh' \
        'vless://|hy2://|hysteria2://|reality-share\.txt|-----BEGIN [A-Z ]*PRIVATE KEY-----|"(password|uuid|privateKey|private_key|publicKey|public_key)"' \
        "$scan_root" 2>/dev/null || true)
    [[ -z "$matches" ]] || {
        install_core_error "secret scan matched release content under $scan_root"
        printf '%s\n' "$matches" >&2
        return 1
    }
}

run_syntax_checks() {
    local script=''

    while IFS= read -r -d '' script; do
        bash -n "$script"
    done < <(find "$package_root" -type f -name '*.sh' -print0)
    dash -n "$package_root/bootstrap.sh"
}

validate_manifest
run_syntax_checks
secret_scan "$package_root"

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/netui-release.XXXXXX")
cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT HUP INT TERM

prepare_output_dir() {
    local output_file=''
    local home_dir=${HOME:-}

    if [[ "$output_dir" != /* ]]; then
        output_dir="$repo_root/$output_dir"
    fi
    output_dir=$(realpath -m -- "$output_dir") || {
        install_core_error "cannot resolve output directory: $output_dir"
        return 1
    }
    case "$output_dir" in
        /|"$repo_root"|"$home_dir")
            install_core_error "refusing unsafe output directory: $output_dir"
            return 1
            ;;
    esac
    [[ ! -L "$output_dir" ]] || {
        install_core_error "refusing symlink output directory: $output_dir"
        return 1
    }
    mkdir -p -- "$output_dir"
    [[ -d "$output_dir" && ! -L "$output_dir" ]] || {
        install_core_error "output path is not a regular directory: $output_dir"
        return 1
    }

    for output_file in \
        "$output_dir/netui-v$version-linux-amd64.tar.gz" \
        "$output_dir/netui-v$version-linux-arm64.tar.gz" \
        "$output_dir/install-v$version.sh" \
        "$output_dir/SHA256SUMS" \
        "$output_dir/RELEASE-MANIFEST.json" \
        "$output_dir/THIRD_PARTY_NOTICES.md" \
        "$output_dir/SOURCE-CODE-OFFER.md"; do
        if [[ -L "$output_file" || ( -e "$output_file" && ! -f "$output_file" ) ]]; then
            install_core_error "refusing unsafe generated output path: $output_file"
            return 1
        fi
        rm -f -- "$output_file"
    done
}

prepare_output_dir

for arch in amd64 arm64; do
    install_core_build_release_tree "$package_root" "$work_dir" "$arch" "$asset_dir" "$work_dir/$arch"
done

for arch in amd64 arm64; do
    package_dir="$work_dir/netui-v$version-linux-$arch"
    archive_name="netui-v$version-linux-$arch.tar.gz"
    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
        -C "$work_dir" -cf - "netui-v$version-linux-$arch" | gzip -n > "$output_dir/$archive_name"
    chmod 644 -- "$output_dir/$archive_name"
    secret_scan "$package_dir"
    tar -tzf "$output_dir/$archive_name" > "$work_dir/$archive_name.list"
    while IFS= read -r member || [[ -n "$member" ]]; do
        case "$member" in
            /*|../*|*/../*|*/..|..)
                install_core_error "unsafe member in generated archive: $member"
                exit 1
                ;;
        esac
    done < "$work_dir/$archive_name.list"
done

install_script_name="install-v$version.sh"
if [[ "$release_base_url" == '__NETUI_RELEASE_BASE_URL__' ]]; then
    sed -e "s|__NETUI_RELEASE_VERSION__|$version|g" \
        -e 's|__NETUI_RELEASE_BASE_URL__|__NETUI_RELEASE_BASE_URL__|g' \
        "$package_root/bootstrap.sh" > "$output_dir/$install_script_name"
else
    sed -e "s|__NETUI_RELEASE_VERSION__|$version|g" \
        -e "s|__NETUI_RELEASE_BASE_URL__|$release_base_url|g" \
        "$package_root/bootstrap.sh" > "$output_dir/$install_script_name"
fi
chmod 755 -- "$output_dir/$install_script_name"

install -D -m 644 -- "$package_root/THIRD_PARTY_NOTICES.md" "$output_dir/THIRD_PARTY_NOTICES.md"
install -D -m 644 -- "$package_root/SOURCE-CODE-OFFER.md" "$output_dir/SOURCE-CODE-OFFER.md"

amd64_archive="netui-v$version-linux-amd64.tar.gz"
arm64_archive="netui-v$version-linux-arm64.tar.gz"
amd64_sha=$(sha256sum -- "$output_dir/$amd64_archive" | awk '{print $1}')
arm64_sha=$(sha256sum -- "$output_dir/$arm64_archive" | awk '{print $1}')
installer_sha=$(sha256sum -- "$output_dir/$install_script_name" | awk '{print $1}')
notices_sha=$(sha256sum -- "$output_dir/THIRD_PARTY_NOTICES.md" | awk '{print $1}')
source_offer_sha=$(sha256sum -- "$output_dir/SOURCE-CODE-OFFER.md" | awk '{print $1}')

jq -n \
    --arg project netui \
    --arg version "$version" \
    --arg amd64_name "$amd64_archive" --arg amd64_sha "$amd64_sha" \
    --arg arm64_name "$arm64_archive" --arg arm64_sha "$arm64_sha" \
    --arg installer_name "$install_script_name" --arg installer_sha "$installer_sha" \
    --arg notices_name THIRD_PARTY_NOTICES.md --arg notices_sha "$notices_sha" \
    --arg source_offer_name SOURCE-CODE-OFFER.md --arg source_offer_sha "$source_offer_sha" \
    '{schema:1,project:$project,version:$version,assets:[
        {name:$amd64_name,sha256:$amd64_sha,arch:"amd64"},
        {name:$arm64_name,sha256:$arm64_sha,arch:"arm64"},
        {name:$installer_name,sha256:$installer_sha,kind:"bootstrap"},
        {name:$notices_name,sha256:$notices_sha,kind:"notices"},
        {name:$source_offer_name,sha256:$source_offer_sha,kind:"source-offer"}
    ]}' > "$output_dir/RELEASE-MANIFEST.json"
chmod 644 -- "$output_dir/RELEASE-MANIFEST.json"

manifest_sha=$(sha256sum -- "$output_dir/RELEASE-MANIFEST.json" | awk '{print $1}')
cat > "$output_dir/SHA256SUMS" <<EOF
$amd64_sha  $amd64_archive
$arm64_sha  $arm64_archive
$installer_sha  $install_script_name
$manifest_sha  RELEASE-MANIFEST.json
$notices_sha  THIRD_PARTY_NOTICES.md
$source_offer_sha  SOURCE-CODE-OFFER.md
EOF
chmod 644 -- "$output_dir/SHA256SUMS"

secret_scan "$output_dir"

expected_assets=$(printf '%s\n' "$amd64_archive" "$arm64_archive" "$install_script_name" RELEASE-MANIFEST.json THIRD_PARTY_NOTICES.md SOURCE-CODE-OFFER.md)
actual_assets=$(awk '{print $2}' "$output_dir/SHA256SUMS")
[[ "$actual_assets" == "$expected_assets" ]] || {
    install_core_error 'SHA256SUMS asset names do not exactly match the expected release assets'
    exit 1
}

if ((skip_smoke == 0)); then
    smoke_home="$work_dir/smoke-home"
    mkdir -p -- "$smoke_home"
    smoke_root="$smoke_home/release"
    tar -xzf "$output_dir/$amd64_archive" -C "$smoke_home"
    extracted_root="$smoke_home/netui-v$version-linux-amd64"
    HOME="$smoke_home/home" XDG_CONFIG_HOME="$smoke_home/home/.config" \
        XDG_DATA_HOME="$smoke_home/home/.local/share" XDG_STATE_HOME="$smoke_home/home/.local/state" \
        bash "$extracted_root/install.sh" --from-release
    HOME="$smoke_home/home" XDG_CONFIG_HOME="$smoke_home/home/.config" \
        XDG_DATA_HOME="$smoke_home/home/.local/share" XDG_STATE_HOME="$smoke_home/home/.local/state" \
        "$smoke_home/home/.local/bin/netui" --version >/dev/null
    HOME="$smoke_home/home" XDG_CONFIG_HOME="$smoke_home/home/.config" \
        XDG_DATA_HOME="$smoke_home/home/.local/share" XDG_STATE_HOME="$smoke_home/home/.local/state" \
        bash "$smoke_home/home/.local/share/netui/current/install.sh" --uninstall --yes
fi

if ((skip_visual == 0)); then
    visual_runner="$repo_root/tests/netui/visual/run.sh"
    if [[ -x "$visual_runner" ]]; then
        "$visual_runner"
    else
        install_core_error 'VHS visual runner is not present; use --skip-visual only for preview'
        exit 1
    fi
fi

install_core_info "built NetUI $version release assets under $output_dir"
