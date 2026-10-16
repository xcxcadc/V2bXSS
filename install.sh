#!/usr/bin/env bash
set -euo pipefail
umask 077

# This entry installs this fork only. It never runs an upstream installer.
repository='https://github.com/xcxcadc/V2bXSS.git'
service='V2bX-audit-test.service'

usage() {
    cat <<'USAGE'
Build this V2bXSS fork and manage only the isolated V2bX-audit-test service.

Install (default is build, verify and print a plan):
  bash install.sh [install] --commit FULL_40_CHARACTER_SHA [--source CLEAN_CHECKOUT]
      [--version VERSION] [--arch amd64|arm64] [--config TEST_CONFIG]
      [--download-deps] [--apply] [--start] [--dry-run]

  --commit          Required exact source commit; branches and short SHAs are rejected.
  --source          Use a clean local checkout at that commit; otherwise fetch this fork.
  --config          Required on first installation; omit it on upgrade to preserve config.
  --download-deps   Explicitly populate the existing Go module cache with verified modules.
  --apply           Install the isolated test service; no other service is managed.
  --start           Start/restart that service only when combined with --apply.

Prerequisites: Git, GNU tools and a preinstalled Go >= the source go.mod minimum
with GOEXPERIMENT=jsonv2 support. The script never installs or replaces Go.
Without --download-deps the full module cache must already be available.
Build/source artifacts are retained in a printed temporary directory, even in dry run.
Actual installation needs Linux root and systemd. No prebuilt Release is assumed.

Management (only V2bX-audit-test.service):
  bash install.sh status
  bash install.sh logs
  bash install.sh start|restart|stop [--apply | --dry-run]
State-changing management commands print a plan unless --apply is explicit.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_command() { command -v "$1" >/dev/null || die "Missing command: $1"; }
need_linux_root() {
    need_command id
    need_command uname
    [[ $(uname -s) == Linux && $(id -u) == 0 ]] || die 'Linux root is required for --apply; existing services were not changed'
}

action=install
if (($#)) && [[ "$1" != -* ]]; then
    action=$1
    shift
fi
case "$action" in
    install|status|logs|start|restart|stop) ;;
    help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

commit=''
local_source=''
version=''
architecture=amd64
new_config=''
apply=false
start_service=false
explicit_dry_run=false
download_deps=false
has_install_option=false
while (($#)); do
    case "$1" in
        --commit) commit="${2:?missing full commit SHA}"; has_install_option=true; shift 2 ;;
        --source) local_source="${2:?missing local checkout}"; has_install_option=true; shift 2 ;;
        --version) version="${2:?missing version}"; has_install_option=true; shift 2 ;;
        --arch) architecture="${2:?missing architecture}"; has_install_option=true; shift 2 ;;
        --config) new_config="${2:?missing test config}"; has_install_option=true; shift 2 ;;
        --download-deps) download_deps=true; has_install_option=true; shift ;;
        --apply) apply=true; shift ;;
        --start) start_service=true; has_install_option=true; shift ;;
        --dry-run) explicit_dry_run=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
$apply && $explicit_dry_run && die '--apply and --dry-run conflict'

if [[ "$action" != install ]]; then
    $has_install_option && die 'Install options cannot be used with a management command'
    case "$action" in
        status)
            $apply && die 'status is read-only; omit --apply'
            need_command systemctl
            systemctl status --no-pager --full "$service"
            ;;
        logs)
            $apply && die 'logs is read-only; omit --apply'
            need_command journalctl
            journalctl --unit "$service" --no-pager --lines 100
            ;;
        start|restart|stop)
            if ! $apply; then
                printf 'DRY RUN: would %s only %s. Add --apply to execute.\n' "$action" "$service"
                exit 0
            fi
            need_linux_root
            need_command systemctl
            systemctl "$action" "$service"
            if [[ "$action" != stop ]]; then systemctl is-active --quiet "$service"; fi
            ;;
    esac
    exit 0
fi

[[ "$commit" =~ ^[a-fA-F0-9]{40}$ ]] || die '--commit requires a full 40-character commit SHA from xcxcadc/V2bXSS'
commit=${commit,,}
[[ "$architecture" == amd64 || "$architecture" == arm64 ]] || die 'Supported targets: amd64 or arm64'
[[ -n "$version" ]] || version="audit-${commit:0:12}"
[[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$ ]] || die 'Invalid version identifier'
export GOTOOLCHAIN=local

# Run these checks before fetching source. No toolchain bootstrap or auto switching.
for required in go git sha256sum realpath install cut mkdir mktemp awk bash; do need_command "$required"; done
if ! go_version=$(GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 GOPROXY=off GOSUMDB=off go env GOVERSION); then
    die 'The preinstalled Go must support GOEXPERIMENT=jsonv2; install a suitable Go toolchain separately. Go was not changed'
fi
[[ "$go_version" =~ ^go([0-9]+)\.([0-9]+)(\.[0-9]+)?([a-z][0-9]+)?$ ]] || die "Cannot validate preinstalled Go version: $go_version"
go_major=${BASH_REMATCH[1]}
go_minor=${BASH_REMATCH[2]}
go_patch=${BASH_REMATCH[3]:-.0}
go_patch=${go_patch#.}
[[ "$go_major" -gt 1 || ( "$go_major" -eq 1 && "$go_minor" -ge 25 ) ]] || die 'Go 1.25 or newer with jsonv2 is required; the system Go was not changed'
if $apply; then need_linux_root; need_command systemctl; fi

if [[ -n "$local_source" ]]; then
    local_source=$(realpath -e -- "$local_source")
    [[ -d "$local_source" ]] || die 'Local checkout not found'
    [[ "$local_source" -ef "$(git -C "$local_source" rev-parse --show-toplevel)" ]] || die '--source must name the checkout root'
    [[ "$(git -C "$local_source" rev-parse --verify HEAD)" == "$commit" ]] || die 'Local checkout HEAD does not match --commit'
    [[ -z "$(git -C "$local_source" status --porcelain --untracked-files=normal)" ]] || die 'Local checkout must be clean; commit/review changes before a reproducible install'
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/v2bxss-install.XXXXXXXX")
printf 'Source/build artifacts retained: %s\n' "$work_dir"
trap 'printf "Install failed. Artifacts retained: %s\n" "$work_dir" >&2' ERR
checkout="$work_dir/source"
git init --quiet "$checkout"
git -C "$checkout" config core.autocrlf false
if [[ -n "$local_source" ]]; then
    # Fetch a commit, never copy local configuration or uncommitted working files.
    git -C "$checkout" -c protocol.file.allow=always -c protocol.ext.allow=never \
        fetch --quiet --no-tags --depth 1 "$local_source" "$commit"
else
    git -C "$checkout" -c protocol.file.allow=never -c protocol.ext.allow=never \
        -c http.sslVerify=true -c http.followRedirects=false \
        fetch --quiet --no-tags --depth 1 "$repository" "$commit"
fi
git -C "$checkout" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
actual_commit=$(git -C "$checkout" rev-parse --verify HEAD)
[[ "$actual_commit" == "$commit" ]] || die 'Fetched commit does not match the requested commit; nothing was installed'
for file in go.mod go.sum main.go tools/packaging/build-local-bundle.sh tools/packaging/install-test-node.sh; do
    [[ -f "$checkout/$file" && ! -L "$checkout/$file" ]] || die "Selected commit lacks a regular required file: $file"
done
minimum_go=$(awk '$1 == "go" {print $2; exit}' "$checkout/go.mod")
[[ "$minimum_go" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]] || die 'Cannot read the Go minimum from source go.mod'
minimum_major=${BASH_REMATCH[1]}
minimum_minor=${BASH_REMATCH[2]}
minimum_patch=${BASH_REMATCH[3]:-.0}
minimum_patch=${minimum_patch#.}
if (( go_major < minimum_major || (go_major == minimum_major && go_minor < minimum_minor) || (go_major == minimum_major && go_minor == minimum_minor && go_patch < minimum_patch) )); then
    die "Selected source requires Go >= $minimum_go; found $go_version. Install Go separately; no automatic replacement is performed"
fi
printf 'Verified source: %s @ %s\nToolchain: %s (local only)\n' "$repository" "$actual_commit" "$go_version"

if $download_deps; then
    echo 'Downloading checksum-verified Go modules into the existing module cache (--download-deps).'
    (
        cd -- "$checkout"
        GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 GOSUMDB=sum.golang.org GONOSUMDB='' GOPRIVATE='' \
            go mod download
    )
fi
(
    cd -- "$checkout"
    GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 go mod verify
)
[[ -z "$(git -C "$checkout" status --porcelain --untracked-files=normal)" ]] || die 'Dependency preparation changed the pinned source; review go.mod/go.sum before installation'

bundle="$work_dir/bundle"
bash "$checkout/tools/packaging/build-local-bundle.sh" --source "$checkout" --output "$bundle" --version "$version" --arch "$architecture"
binary_hash=$(sha256sum "$bundle/V2bX" | cut -d ' ' -f 1)
manifest_hash=$(sha256sum "$bundle/SHA256SUMS" | cut -d ' ' -f 1)
install_args=(--bundle "$bundle" --version "$version" --binary-sha256 "$binary_hash" --manifest-sha256 "$manifest_hash")
if [[ -n "$new_config" ]]; then install_args+=(--config "$new_config"); fi
if $apply; then install_args+=(--apply); fi
if $start_service; then install_args+=(--start); fi
if $explicit_dry_run; then install_args+=(--dry-run); fi
bash "$bundle/install-test-node.sh" "${install_args[@]}"
echo 'A binary replacement takes one explicit service restart. Subsequent supported audit-rule changes sync without restarting this service.'
