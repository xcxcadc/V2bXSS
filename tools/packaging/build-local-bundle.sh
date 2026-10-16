#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Build an isolated test-node bundle from local source. No network downloads.
Usage: bash build-local-bundle.sh --source PATH --output NEW_PATH --version VERSION [--arch amd64|arm64]
Prepare a Go toolchain supporting jsonv2 and its dependency cache beforehand.
USAGE
}

source_dir=''
output_dir=''
version=''
architecture=amd64
while (($#)); do
    case "$1" in
        --source) source_dir="${2:?missing source}"; shift 2 ;;
        --output) output_dir="${2:?missing output}"; shift 2 ;;
        --version) version="${2:?missing version}"; shift 2 ;;
        --arch) architecture="${2:?missing architecture}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ -n "$source_dir" && -n "$output_dir" && "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$ ]] || { usage >&2; exit 2; }
[[ "$architecture" == amd64 || "$architecture" == arm64 ]] || { echo 'Unsupported architecture' >&2; exit 2; }
for required in go git sha256sum realpath install cut mkdir; do
    command -v "$required" >/dev/null || { echo "Missing command: $required" >&2; exit 1; }
done
source_dir=$(realpath -e -- "$source_dir")
output_dir=$(realpath -m -- "$output_dir")
[[ -f "$source_dir/go.mod" && -f "$source_dir/main.go" ]] || { echo 'Source is not a V2bX checkout' >&2; exit 1; }
[[ ! -e "$output_dir" && ! -L "$output_dir" ]] || { echo 'Output must be a new directory; existing artifacts will not be overwritten' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source_commit=$(git -C "$source_dir" rev-parse HEAD)
source_tree=$(git -C "$source_dir" status --porcelain --untracked-files=normal | sha256sum | cut -d ' ' -f 1)
source_diff=$(git -C "$source_dir" diff --binary HEAD | sha256sum | cut -d ' ' -f 1)
source_untracked=$(
    cd -- "$source_dir"
    git ls-files --others --exclude-standard -z |
        while IFS= read -r -d '' source_file; do
            [[ -f "$source_file" && ! -L "$source_file" ]] || { echo 'Untracked source must be regular files' >&2; exit 1; }
            sha256sum -- "$source_file"
        done | sha256sum | cut -d ' ' -f 1
)
mkdir -- "$output_dir"
build_tags='sing xray hysteria2 with_quic with_utls with_wireguard with_acme with_gvisor'
(
    cd -- "$source_dir"
    # Fail instead of downloading dependencies or switching toolchains.
    GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOOS=linux GOARCH="$architecture" CGO_ENABLED=0 GOEXPERIMENT=jsonv2 \
        go build -trimpath -tags "$build_tags" \
        -ldflags "-X github.com/InazumaV/V2bX/cmd.version=$version -s -w -buildid=" \
        -o "$output_dir/V2bX" .
)
{
    printf 'version=%s\n' "$version"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'source_status_sha256=%s\n' "$source_tree"
    printf 'tracked_source_diff_sha256=%s\n' "$source_diff"
    printf 'untracked_source_files_sha256=%s\n' "$source_untracked"
    printf 'go_version=%s\n' "$(go version)"
    printf 'goos=linux\ngoarch=%s\n' "$architecture"
    printf 'build_tags=%s\n' "$build_tags"
} > "$output_dir/BUILD-INFO"
install -m 0755 "$script_dir/install-test-node.sh" "$output_dir/install-test-node.sh"
install -m 0755 "$script_dir/rollback-test-node.sh" "$output_dir/rollback-test-node.sh"
install -m 0644 "$script_dir/V2bX-audit-test.service" "$output_dir/V2bX-audit-test.service"
(
    cd -- "$output_dir"
    sha256sum --binary V2bX BUILD-INFO install-test-node.sh rollback-test-node.sh V2bX-audit-test.service > SHA256SUMS
)
printf 'Bundle built: %s\n' "$output_dir"
printf 'Binary SHA256: '
sha256sum "$output_dir/V2bX"
printf 'Manifest SHA256: '
sha256sum "$output_dir/SHA256SUMS"
