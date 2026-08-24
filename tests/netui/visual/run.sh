#!/bin/bash

set -euo pipefail

script_dir=$(cd -P -- "${0%/*}" && pwd -P)
repo_root=$(cd -P -- "$script_dir/../../.." && pwd -P)
package_root=${NETUI_VISUAL_PACKAGE_ROOT:-$repo_root/packages/netui}
artifact_root=${NETUI_VISUAL_ARTIFACT_ROOT:-$repo_root/artifacts/netui/visual}
fixture=$(mktemp -d "${TMPDIR:-/tmp}/netui-visual.XXXXXX")

cleanup() {
    rm -rf -- "$fixture"
}
trap cleanup EXIT HUP INT TERM

for command_name in bash jq vhs ffmpeg compare; do
    command -v "$command_name" >/dev/null 2>&1 || {
        printf 'netui visual: missing dependency: %s\n' "$command_name" >&2
        exit 3
    }
done
[[ -d "$package_root" && ! -L "$package_root" ]] || exit 1

mkdir -p -- "$artifact_root"
export NETUI_VISUAL_PACKAGE_ROOT=$package_root
export NETUI_VISUAL_HOME="$fixture/home"
export HOME="$NETUI_VISUAL_HOME"
export XDG_CONFIG_HOME="$NETUI_VISUAL_HOME/.config"
export XDG_DATA_HOME="$NETUI_VISUAL_HOME/.local/share"
export XDG_STATE_HOME="$NETUI_VISUAL_HOME/.local/state"
export NETUI_VISUAL_ARTIFACT_ROOT="$artifact_root"
export NETUI_SING_BOX="$fixture/fake-sing-box"
export NETUI_TMUX_SOCKET="netui-visual-${BASHPID}-${RANDOM}"
export TERM=xterm-256color
unset NETUI_TUI_ACTIONS NETUI_GUM

mkdir -p -- "$NETUI_VISUAL_HOME"
cat > "$NETUI_SING_BOX" <<'EOF'
#!/bin/bash

case "${1-}" in
    check)
        [[ "${2-}" == -c && -n "${3-}" ]] || exit 2
        jq empty "$3" >/dev/null
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod 700 -- "$NETUI_SING_BOX"

cd -- "$repo_root"
bash "$script_dir/scene.sh" prepare >/dev/null
vhs validate "$repo_root/tests/netui/vhs/*.tape"

for scene in dashboard config-switch env-modes narrow fallback; do
    tape="$repo_root/tests/netui/vhs/$scene.tape"
    movie="$artifact_root/$scene.mp4"
    actual="$artifact_root/$scene.png"
    diff="$artifact_root/$scene-diff.png"
    vhs --quiet --output "$movie" "$tape"
    ffmpeg -loglevel error -y -sseof -0.4 -i "$movie" -frames:v 1 "$actual"
    [[ -s "$actual" ]] || {
        printf 'netui visual: no PNG generated for %s\n' "$scene" >&2
        exit 1
    }

    baseline="$repo_root/tests/netui/visual/baseline/$scene.png"
    if [[ "${UPDATE_VISUAL_BASELINE:-0}" == 1 ]]; then
        mkdir -p -- "${baseline%/*}"
        cp -f -- "$actual" "$baseline"
        continue
    fi
    if [[ ! -f "$baseline" ]]; then
        printf 'netui visual: missing baseline for %s; review PNG and rerun with UPDATE_VISUAL_BASELINE=1\n' "$scene" >&2
        exit 1
    fi

    metric=$(compare -fuzz 5% -metric AE "$baseline" "$actual" "$diff" 2>&1 >/dev/null || true)
    metric=${metric%% *}
    [[ "$metric" =~ ^[0-9]+$ && "$metric" -le 100 ]] || {
        printf 'netui visual: baseline mismatch for %s (AE=%s, threshold=100)\n' "$scene" "$metric" >&2
        exit 1
    }
done

printf 'NetUI visual smoke passed\n'
