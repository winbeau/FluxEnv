#!/bin/bash

set -eu
umask 077

version='__NETUI_RELEASE_VERSION__'
release_base_url='__NETUI_RELEASE_BASE_URL__'

fail() {
    printf 'netui bootstrap: %s\n' "$1" >&2
    exit 1
}

case "$(uname -s)" in
    Linux)
        ;;
    *)
        fail 'only Linux is supported'
        ;;
esac

case "$(uname -m)" in
    x86_64|amd64)
        arch=amd64
        ;;
    aarch64|arm64)
        arch=arm64
        ;;
    *)
        fail "unsupported architecture: $(uname -m)"
        ;;
esac

for command_name in bash curl tar sha256sum mktemp awk grep; do
    command -v "$command_name" >/dev/null 2>&1 || fail "missing dependency: $command_name"
done

if ! bash -c 'test "${BASH_VERSINFO[0]}" -ge 4' >/dev/null 2>&1; then
    fail 'Bash 4 or newer is required'
fi

case "$release_base_url" in
    https://*)
        ;;
    *)
        release_base_url=${NETUI_RELEASE_BASE_URL:-}
        case "$release_base_url" in
            https://*)
                ;;
            *)
                fail 'the fixed release URL is not configured'
                ;;
        esac
        ;;
esac

release_base_url=${release_base_url%/}
archive_name="netui-v${version}-linux-${arch}.tar.gz"
checksums_name=SHA256SUMS
temporary_dir=$(mktemp -d "${TMPDIR:-/tmp}/netui-bootstrap.XXXXXX") || fail 'cannot create a temporary directory'
cleanup() {
    rm -rf -- "$temporary_dir"
}
trap cleanup EXIT HUP INT TERM

curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 \
    --output "$temporary_dir/$archive_name" "$release_base_url/$archive_name" || fail 'release archive download failed'
curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 \
    --output "$temporary_dir/$checksums_name" "$release_base_url/$checksums_name" || fail 'checksum download failed'

checksum_line=$(grep -E "^[0-9a-f]{64}[[:space:]][[:space:]]${archive_name}$" "$temporary_dir/$checksums_name" || true)
checksum_count=$(printf '%s\n' "$checksum_line" | awk 'NF {count++} END {print count + 0}')
[ "$checksum_count" = 1 ] || fail 'checksum file does not contain exactly one expected archive entry'
expected_sha256=$(printf '%s\n' "$checksum_line" | awk '{print $1}')
actual_sha256=$(sha256sum -- "$temporary_dir/$archive_name" | awk '{print $1}')
[ "$actual_sha256" = "$expected_sha256" ] || fail 'release archive checksum mismatch'

tar -tzf "$temporary_dir/$archive_name" > "$temporary_dir/archive.list" || fail 'cannot inspect release archive'
while IFS= read -r member || [ -n "$member" ]; do
    case "$member" in
        /*|../*|*/../*|*/..|..)
            fail 'release archive contains a path traversal member'
            ;;
    esac
done < "$temporary_dir/archive.list"

tar -tvzf "$temporary_dir/$archive_name" > "$temporary_dir/archive.verbose" || fail 'cannot inspect release archive entry types'
while IFS= read -r member_line || [ -n "$member_line" ]; do
    case "$member_line" in
        d*|-*)
            ;;
        *)
            fail 'release archive contains a non-regular entry'
            ;;
    esac
done < "$temporary_dir/archive.verbose"

mkdir -p -- "$temporary_dir/unpack"
tar -xzf "$temporary_dir/$archive_name" -C "$temporary_dir/unpack" \
    --no-same-owner --no-same-permissions --no-overwrite-dir || fail 'cannot unpack release archive'
package_dir="$temporary_dir/unpack/netui-v${version}-linux-${arch}"
[ -d "$package_dir" ] || fail 'release archive has an unexpected top-level directory'
[ -f "$package_dir/install.sh" ] && [ ! -L "$package_dir/install.sh" ] || fail 'release installer is missing or unsafe'

bash "$package_dir/install.sh" --from-release
