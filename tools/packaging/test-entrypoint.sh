#!/usr/bin/env bash
set -euo pipefail
umask 077

# Entry-point fixtures only: mock Go, remote fetches and service managers.
# Neither a real network request nor a real privileged/service operation is run.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
entrypoint="$script_dir/../../install.sh"
for required in bash git mktemp install realpath sha256sum awk grep cmp; do
    command -v "$required" >/dev/null || { echo "Missing fixture dependency: $required" >&2; exit 1; }
done
real_git=$(command -v git)
real_bash=$(command -v bash)
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/v2bxss-entrypoint-check.XXXXXXXX")
printf 'Entry-point fixture retained: %s\n' "$fixture_dir"
mkdir "$fixture_dir/bin" "$fixture_dir/no-go-bin" "$fixture_dir/source" "$fixture_dir/logs"
fixture_source="$fixture_dir/source"
mkdir -p "$fixture_source/tools/packaging"
cp "$script_dir/build-local-bundle.sh" "$script_dir/rollback-test-node.sh" "$script_dir/V2bX-audit-test.service" "$fixture_source/tools/packaging/"
printf 'module fixture.invalid/v2bxss\n\ngo 1.25\n' > "$fixture_source/go.mod"
printf '// empty fixture checksum file\n' > "$fixture_source/go.sum"
printf 'package main\nfunc main() {}\n' > "$fixture_source/main.go"
cat > "$fixture_source/tools/packaging/install-test-node.sh" <<'INSTALL_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$ENTRY_FIXTURE_LOG/install-args"
echo 'FIXTURE: bundle installer called; no system paths or services changed.'
INSTALL_STUB
"$real_git" init --quiet "$fixture_source"
"$real_git" -C "$fixture_source" config user.name 'Installer fixture'
"$real_git" -C "$fixture_source" config user.email 'fixture@example.invalid'
"$real_git" -C "$fixture_source" config core.autocrlf false
"$real_git" -C "$fixture_source" add .
"$real_git" -C "$fixture_source" -c commit.gpgsign=false commit --quiet -m 'Fixture pinned source'
fixture_commit=$("$real_git" -C "$fixture_source" rev-parse HEAD)
printf 'Alternate fixture commit\n' > "$fixture_source/fixture-marker"
"$real_git" -C "$fixture_source" add fixture-marker
"$real_git" -C "$fixture_source" -c commit.gpgsign=false commit --quiet -m 'Fixture mismatched source'
alternate_commit=$("$real_git" -C "$fixture_source" rev-parse HEAD)
printf 'module fixture.invalid/v2bxss\n\ngo 1.26.6\n' > "$fixture_source/go.mod"
"$real_git" -C "$fixture_source" add go.mod
"$real_git" -C "$fixture_source" -c commit.gpgsign=false commit --quiet -m 'Fixture newer Go minimum'
newer_go_commit=$("$real_git" -C "$fixture_source" rev-parse HEAD)
"$real_git" -C "$fixture_source" -c core.hooksPath=/dev/null checkout --quiet --detach "$fixture_commit"

cat > "$fixture_dir/bin/git" <<'GIT_STUB'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
for value in "${args[@]}"; do
    case "$value" in
        https://github.com/xcxcadc/V2bXSS.git) ;;
        https://*|http://*|ssh://*|git://*) echo 'Fixture blocks unexpected remote Git endpoint' >&2; exit 99 ;;
    esac
done
for ((i=0; i<${#args[@]}; i++)); do
    if [[ "${args[$i]}" == fetch ]]; then
        printf 'fetch\n' >> "$ENTRY_FIXTURE_LOG/git-fetches"
    fi
    if [[ "${args[$i]}" == 'https://github.com/xcxcadc/V2bXSS.git' ]]; then
        printf 'own-fork-remote\n' >> "$ENTRY_FIXTURE_LOG/remote-fetches"
        args[$i]=$ENTRY_FIXTURE_SOURCE
        # This is a local substitute for the fixed HTTPS endpoint, never a network call.
        for ((j=0; j<${#args[@]}; j++)); do
            if [[ "${args[$j]}" == protocol.file.allow=never ]]; then args[$j]=protocol.file.allow=always; fi
        done
        if [[ "${ENTRY_FIXTURE_MISMATCH:-0}" == 1 ]]; then
            args[${#args[@]}-1]=$ENTRY_FIXTURE_ALTERNATE
        fi
        break
    fi
done
exec "$ENTRY_FIXTURE_GIT" "${args[@]}"
GIT_STUB
cat > "$fixture_dir/bin/go" <<'GO_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s | GOTOOLCHAIN=%s GOPROXY=%s GOSUMDB=%s GOEXPERIMENT=%s\n' "$*" "${GOTOOLCHAIN:-}" "${GOPROXY:-}" "${GOSUMDB:-}" "${GOEXPERIMENT:-}" >> "$ENTRY_FIXTURE_LOG/go-calls"
case "$1" in
    env)
        if [[ "${ENTRY_FIXTURE_UNSUPPORTED_GO:-0}" == 1 ]]; then
            echo 'fixture: unknown GOEXPERIMENT jsonv2' >&2
            exit 1
        fi
        [[ "$2" == GOVERSION ]] || exit 91
        printf '%s\n' "${ENTRY_FIXTURE_GO_VERSION:-go1.26.5}"
        ;;
    version) echo 'go version go1.26.5 fixture/amd64' ;;
    mod)
        case "$2" in download|verify) ;; *) exit 92 ;; esac
        if [[ "$2" == download && "${ENTRY_FIXTURE_DIRTY_DEPS:-0}" == 1 ]]; then
            printf '// fixture mutation\n' >> go.sum
        fi
        ;;
    build)
        output=''
        while (($#)); do
            if [[ "$1" == -o ]]; then output=$2; shift 2; else shift; fi
        done
        [[ -n "$output" ]] || exit 93
        printf '#!/bin/sh\nexit 0\n' > "$output"
        ;;
    *) exit 94 ;;
esac
GO_STUB
cat > "$fixture_dir/bin/systemctl" <<'SYSTEMCTL_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'systemctl %s\n' "$*" >> "$ENTRY_FIXTURE_LOG/services"
[[ "${*: -1}" == V2bX-audit-test.service ]] || exit 95
SYSTEMCTL_STUB
cat > "$fixture_dir/bin/journalctl" <<'JOURNALCTL_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'journalctl %s\n' "$*" >> "$ENTRY_FIXTURE_LOG/services"
[[ "$*" == '--unit V2bX-audit-test.service --no-pager --lines 100 --output short-iso' ]] || exit 96
JOURNALCTL_STUB
cat > "$fixture_dir/bin/uname" <<'UNAME_STUB'
#!/usr/bin/env bash
case "$1" in -s) echo Linux ;; -m) echo x86_64 ;; *) exit 97 ;; esac
UNAME_STUB
cat > "$fixture_dir/bin/id" <<'ID_STUB'
#!/usr/bin/env bash
[[ "$1" == -u ]] || exit 98
echo 0
ID_STUB
chmod 0755 "$fixture_dir/bin/"*
export ENTRY_FIXTURE_SOURCE="$fixture_source" ENTRY_FIXTURE_GIT="$real_git"
export ENTRY_FIXTURE_ALTERNATE="$alternate_commit" ENTRY_FIXTURE_LOG="$fixture_dir/logs"
export PATH="$fixture_dir/bin:$PATH"
printf '{}\n' > "$fixture_dir/test-node.json"
base_args=(--source "$fixture_source" --commit "$fixture_commit" --config "$fixture_dir/test-node.json")
passed=0
pass() { passed=$((passed + 1)); printf 'PASS: %s\n' "$1"; }
reject() {
    local label=$1 expected=$2
    shift 2
    if "$@" > "$fixture_dir/rejected-$passed.log" 2>&1; then
        echo "Unexpected success: $label" >&2
        exit 1
    fi
    grep -Fq -- "$expected" "$fixture_dir/rejected-$passed.log"
    pass "$label"
}

bash -n "$entrypoint"
bash -n "$script_dir/test-entrypoint.sh"
pass 'entry point and fixture script parse'
reject 'short commit is rejected before fetching' '--commit requires a full' bash "$entrypoint" --commit main
[[ ! -e "$ENTRY_FIXTURE_LOG/git-fetches" ]]
reject 'conflicting modes are rejected before fetching' '--apply and --dry-run conflict' bash "$entrypoint" "${base_args[@]}" --apply --dry-run
reject 'missing Go is reported without downloading' 'Missing command: go' env PATH="$fixture_dir/no-go-bin" "$real_bash" "$entrypoint" "${base_args[@]}"
reject 'old Go is rejected before fetching' 'Go 1.25 or newer' env ENTRY_FIXTURE_GO_VERSION=go1.24.9 bash "$entrypoint" "${base_args[@]}"
reject 'Go without jsonv2 is rejected before fetching' 'must support GOEXPERIMENT=jsonv2' env ENTRY_FIXTURE_UNSUPPORTED_GO=1 bash "$entrypoint" "${base_args[@]}"
[[ ! -e "$ENTRY_FIXTURE_LOG/git-fetches" ]]
reject 'unsupported target is rejected' 'Supported targets:' bash "$entrypoint" "${base_args[@]}" --arch mips
reject 'local source HEAD mismatch is rejected' 'HEAD does not match' bash "$entrypoint" "${base_args[@]}" --commit "$alternate_commit"
printf '// dirty local fixture\n' >> "$fixture_source/main.go"
reject 'dirty local source is rejected' 'Local checkout must be clean' bash "$entrypoint" "${base_args[@]}"
printf 'package main\nfunc main() {}\n' > "$fixture_source/main.go"

bash "$entrypoint" "${base_args[@]}" > "$fixture_dir/local-default.log"
grep -Fq 'FIXTURE: bundle installer called' "$fixture_dir/local-default.log"
! grep -Fxq -- --apply "$ENTRY_FIXTURE_LOG/install-args"
! grep -q '^mod download ' "$ENTRY_FIXTURE_LOG/go-calls"
grep -q '^mod verify .*GOPROXY=off' "$ENTRY_FIXTURE_LOG/go-calls"
grep -q '^build .*GOTOOLCHAIN=local GOPROXY=off' "$ENTRY_FIXTURE_LOG/go-calls"
pass 'clean local source builds offline and default does not pass apply'
default_work=$(awk -F': ' '/^Source\/build artifacts retained:/ {print $2; exit}' "$fixture_dir/local-default.log")
grep -Fxq "source_commit=$fixture_commit" "$default_work/bundle/BUILD-INFO"
pass 'bundle records the verified source commit'

bash "$entrypoint" "${base_args[@]}" --start > "$fixture_dir/local-start.log"
grep -Fxq -- --start "$ENTRY_FIXTURE_LOG/install-args"
! grep -Fxq -- --apply "$ENTRY_FIXTURE_LOG/install-args"
pass 'start without apply is not promoted to an install'
bash "$entrypoint" "${base_args[@]}" --apply --start --version fixture-apply > "$fixture_dir/local-apply.log"
grep -Fxq -- --apply "$ENTRY_FIXTURE_LOG/install-args"
grep -Fxq -- --start "$ENTRY_FIXTURE_LOG/install-args"
grep -Fxq fixture-apply "$ENTRY_FIXTURE_LOG/install-args"
pass 'explicit apply/start are forwarded only to the isolated bundle installer stub'
bash "$entrypoint" --commit "$fixture_commit" --config "$fixture_dir/test-node.json" > "$fixture_dir/remote-pinned.log"
grep -Fxq own-fork-remote "$ENTRY_FIXTURE_LOG/remote-fetches"
pass 'remote mode targets this fork and verifies the full commit (fetch mocked locally)'
reject 'mismatched fetched commit is rejected before build/install' 'Fetched commit does not match' env ENTRY_FIXTURE_MISMATCH=1 bash "$entrypoint" --commit "$fixture_commit" --config "$fixture_dir/test-node.json"
reject 'source go.mod minimum includes the patch version' 'Selected source requires Go >= 1.26.6' bash "$entrypoint" --commit "$newer_go_commit" --config "$fixture_dir/test-node.json"

bash "$entrypoint" "${base_args[@]}" --download-deps > "$fixture_dir/deps.log"
grep -q '^mod download .*GOTOOLCHAIN=local .*GOSUMDB=sum.golang.org' "$ENTRY_FIXTURE_LOG/go-calls"
pass 'dependency downloads require an explicit flag and keep checksum verification'
reject 'dependency changes to pinned source are rejected' 'Dependency preparation changed the pinned source' env ENTRY_FIXTURE_DIRTY_DEPS=1 bash "$entrypoint" "${base_args[@]}" --download-deps

bash "$entrypoint" status > "$fixture_dir/status.log"
bash "$entrypoint" logs > "$fixture_dir/logs.log"
grep -Fxq 'systemctl status --no-pager --full V2bX-audit-test.service' "$ENTRY_FIXTURE_LOG/services"
grep -Fxq 'journalctl --unit V2bX-audit-test.service --no-pager --lines 100 --output short-iso' "$ENTRY_FIXTURE_LOG/services"
pass 'read-only status and logs address only the isolated service (mocked)'
service_calls_before=$(awk 'END {print NR}' "$ENTRY_FIXTURE_LOG/services")
for mode in start restart stop; do
    bash "$entrypoint" "$mode" > "$fixture_dir/management-$mode-plan.log"
    grep -q '^DRY RUN:' "$fixture_dir/management-$mode-plan.log"
done
[[ $(awk 'END {print NR}' "$ENTRY_FIXTURE_LOG/services") == "$service_calls_before" ]]
pass 'all state-changing management commands default to a plan'
for mode in start restart stop; do bash "$entrypoint" "$mode" --apply; done
grep -Fxq 'systemctl start V2bX-audit-test.service' "$ENTRY_FIXTURE_LOG/services"
grep -Fxq 'systemctl restart V2bX-audit-test.service' "$ENTRY_FIXTURE_LOG/services"
grep -Fxq 'systemctl stop V2bX-audit-test.service' "$ENTRY_FIXTURE_LOG/services"
pass 'explicit management commands address only the isolated service (mocked)'
reject 'install flags cannot leak into management commands' 'Install options cannot be used' bash "$entrypoint" restart --commit "$fixture_commit" --apply
reject 'read-only commands reject apply' 'status is read-only' bash "$entrypoint" status --apply

# The existing 13 checks use the real installer, but only in dry-run/rejection paths.
bash "$script_dir/test-packaging.sh" --bundle "$default_work/bundle" > "$fixture_dir/packaging-13-checks.log"
grep -Fq 'Packaging checks passed: 13.' "$fixture_dir/packaging-13-checks.log"
pass 'existing 13 packaging safeguards pass on the simulated-build bundle'
printf 'Entry-point checks passed: %s. Go compilation, remote transfer and real systemd installation were mocked, not accepted as live-node tests.\n' "$passed"
