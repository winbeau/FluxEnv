#!/bin/bash

set -euo pipefail

script_path=$(realpath -e -- "$0") || {
    printf 'netui install: cannot resolve installer path\n' >&2
    exit 1
}
package_root=$(cd -P -- "${script_path%/*}" && pwd -P) || exit 1

# shellcheck source=lib/install_core.sh
source "$package_root/lib/install_core.sh"

usage() {
    cat <<'EOF'
Usage:
  bash packages/netui/install.sh [--asset-dir PATH]
  bash packages/netui/install.sh --from-release
  bash packages/netui/install.sh --uninstall [--purge --yes]

Options:
  --asset-dir PATH       Use exact locked upstream archives from PATH.
  --from-release         Install the already verified release directory.
  --uninstall            Remove NetUI programs but keep config and state.
  --purge                With --uninstall, also remove config and state.
  --yes                  Confirm --purge without an interactive prompt.
  --help                 Show this help.
EOF
}

asset_dir=''
from_release=0
uninstall=0
purge=0
confirm_yes=0
migrate_legacy=0

while (($# > 0)); do
    case "$1" in
        --asset-dir)
            (($# >= 2)) || {
                install_core_error '--asset-dir requires a path'
                exit 2
            }
            asset_dir=$2
            shift 2
            ;;
        --from-release)
            from_release=1
            shift
            ;;
        --uninstall)
            uninstall=1
            shift
            ;;
        --purge)
            purge=1
            shift
            ;;
        --yes)
            confirm_yes=1
            shift
            ;;
        --migrate-legacy)
            migrate_legacy=1
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

if ((migrate_legacy)); then
    install_core_error 'legacy migration is not included in this release installer yet; no files were changed'
    exit 2
fi

if ((purge && !uninstall)); then
    install_core_error '--purge requires --uninstall'
    exit 2
fi

if ((uninstall)); then
    install_core_uninstall "$purge" "$confirm_yes"
    exit $?
fi

if ((from_release)) && [[ -n "$asset_dir" ]]; then
    install_core_error '--asset-dir cannot be combined with --from-release'
    exit 2
fi

install_core_require_base_dependencies

if ((from_release)); then
    install_core_install_from_release "$package_root" "$package_root"
    exit $?
fi

install_core_validate_source_tree "$package_root"
arch=$(install_core_detect_arch)
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/netui-install.XXXXXX")
cleanup() {
    rm -rf -- "$work_dir"
}
trap cleanup EXIT

install_core_build_release_tree "$package_root" "$work_dir" "$arch" "$asset_dir" "$work_dir/work"
release_root="$work_dir/netui-v$(install_core_read_version "$package_root")-linux-$arch"
install_core_install_from_release "$release_root" "$package_root"
