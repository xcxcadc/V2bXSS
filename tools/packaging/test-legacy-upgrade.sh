#!/usr/bin/env bash
set -euo pipefail
# Real file transactions in a private fixture; service manager, Go and host
# identity are mocked. No network or real system installation.
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
entry="$script_dir/../../upgrade-legacy-node.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/v2bxss-legacy-check.XXXXXXXX")"
echo "Legacy upgrade fixture retained: $fixture"
mkdir -p "$fixture/bin" "$fixture/source/tools/packaging" "$fixture/node" "$fixture/config"
real_git="$(command -v git)"
export LEGACY_PYTHON="${LEGACY_PYTHON:-$(command -v python3 || command -v python)}"
cp "$script_dir/configure-node.py" "$fixture/source/tools/packaging/"
printf 'module fixture.invalid/test\n\ngo 1.25\n' > "$fixture/source/go.mod"
printf 'package main\nfunc main() {}\n' > "$fixture/source/main.go"
git init -q "$fixture/source"
git -C "$fixture/source" config user.name 'Upgrade fixture'
git -C "$fixture/source" config user.email fixture@example.invalid
git -C "$fixture/source" config core.autocrlf false
git -C "$fixture/source" add go.mod main.go tools/packaging/configure-node.py
git -C "$fixture/source" -c commit.gpgsign=false commit -qm fixture
export LEGACY_FIXTURE_COMMIT="$(git -C "$fixture/source" rev-parse HEAD)"
export LEGACY_FIXTURE="$fixture"
sed -e "s|^legacy_root=/usr/local/V2bX$|legacy_root=$fixture/node|" \
    -e "s|^config_dir=/etc/V2bX$|config_dir=$fixture/config|" \
    -e "s|^systemd_unit=/etc/systemd/system/V2bX.service$|systemd_unit=$fixture/V2bX.service|" \
    -e "s|^openrc_unit=/etc/init.d/V2bX$|openrc_unit=$fixture/V2bX.openrc|" \
    -e "s|^backup_base=/var/backups/v2bxss-legacy$|backup_base=$fixture/backups|" \
    -e "s|^state_dir=/opt/v2bxss-legacy-upgrade$|state_dir=$fixture/state|" \
    "$entry" > "$fixture/upgrade.sh"
cat > "$fixture/bin/go" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "go $*" >> "$LEGACY_FIXTURE/actions"
case "$1" in
    env) echo go1.26.5 ;;
    mod)
        if [[ "${LEGACY_DIRTY:-0}" == 1 ]]; then echo '//changed' >> go.mod; fi ;;
    build)
        [[ "${LEGACY_BUILD_FAIL:-0}" != 1 ]] || exit 31
        output=''
        while (($#)); do
            if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
        done
        printf '#!/usr/bin/env bash\necho audit-%s\n' "${LEGACY_FIXTURE_COMMIT:0:12}" > "$output"
        chmod 0755 "$output" ;;
    *) exit 99 ;;
esac
STUB
cat > "$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "systemctl $*" >> "$LEGACY_FIXTURE/actions"
[[ "$*" != *audit-test* ]] || exit 90
case "$1" in
    show)
        case "$*" in
            *ExecStart*) echo "{ path=$LEGACY_FIXTURE/node/V2bX ; argv[]=V2bX server ; }" ;;
            *MainPID*)
                n="$(<"$LEGACY_FIXTURE/checks")"
                echo $((n+1)) > "$LEGACY_FIXTURE/checks"
                if [[ "${LEGACY_RESTART_LOOP:-0}" == 1 && -f "$LEGACY_FIXTURE/new-running" && "$n" -gt 0 ]]; then echo 456
                else echo 123; fi ;;
        esac ;;
    is-active) [[ "$(<"$LEGACY_FIXTURE/running")" == true ]] ;;
    stop) echo false > "$LEGACY_FIXTURE/running"; rm -f "$LEGACY_FIXTURE/new-running" ;;
    start)
        if grep -q audit- "$LEGACY_FIXTURE/node/V2bX"; then
            [[ "${LEGACY_START_FAIL:-0}" != 1 ]] || exit 32
            touch "$LEGACY_FIXTURE/new-running"
        fi
        echo true > "$LEGACY_FIXTURE/running"
        echo 0 > "$LEGACY_FIXTURE/checks" ;;
    cat) cat "$LEGACY_FIXTURE/V2bX.service" ;;
    *) exit 98 ;;
esac
STUB
cat > "$fixture/bin/rc-service" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "rc-service $*" >> "$LEGACY_FIXTURE/actions"
[[ "$1" == V2bX ]] || exit 90
case "$2" in
    status) [[ "$(<"$LEGACY_FIXTURE/running")" == true ]] ;;
    stop) echo false > "$LEGACY_FIXTURE/running" ;;
    start) echo true > "$LEGACY_FIXTURE/running" ;;
    *) exit 99 ;;
esac
STUB
printf '#!/usr/bin/env bash\ncase "$1" in -s) echo Linux;; -m) echo "${LEGACY_ARCH:-x86_64}";; esac\n' > "$fixture/bin/uname"
printf '#!/usr/bin/env bash\necho 0\n' > "$fixture/bin/id"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/sleep"
printf '#!/usr/bin/env bash\nexec "${LEGACY_PYTHON:-python}" "$@"\n' > "$fixture/bin/python3"
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/flock"
printf '#!/usr/bin/env bash\necho unexpected network >&2; exit 99\n' > "$fixture/bin/curl"
# Git Bash has no chown; fixture does not need root ownership changes.
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/chown"
chmod 0755 "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
reset_node() {
    printf '#!/usr/bin/env bash\necho original\n' > "$fixture/node/V2bX"
    chmod 0755 "$fixture/node/V2bX"
    printf 'ExecStart=%s/node/V2bX server\n' "$fixture" > "$fixture/V2bX.service"
    printf 'command="%s/node/V2bX"\n' "$fixture" > "$fixture/V2bX.openrc"
    printf '{ // JSON5 kept verbatim\n"secret":"fixture-only","Nodes":[] }\n' > "$fixture/config/config.json"
    printf 'fixture-cert' > "$fixture/config/cert.pem"
    printf 'fixture-route' > "$fixture/config/route.json"
    cp "$fixture/node/V2bX" "$fixture/original"
    sha256sum "$fixture/config/"* "$fixture/V2bX.service" "$fixture/V2bX.openrc" > "$fixture/preserved.sha"
    echo true > "$fixture/running"
    echo 0 > "$fixture/checks"
    : > "$fixture/actions"
    rm -f "$fixture/new-running"
}
passed=0
pass() { passed=$((passed+1)); echo "PASS: $1"; }
upgrade() { bash "$fixture/upgrade.sh" --source "$fixture/source" --commit "$LEGACY_FIXTURE_COMMIT" --yes "$@"; }
reset_node
bash -n "$entry"
bash "$fixture/upgrade.sh" --dry-run > "$fixture/dry.log"
cmp "$fixture/node/V2bX" "$fixture/original"
! grep -Eq 'go |systemctl (start|stop)' "$fixture/actions"
[[ ! -e "$fixture/backups" && ! -e "$fixture/state" ]]
pass 'dry run does not build, write state or change service'
upgrade > "$fixture/success.log"
grep -q audit- "$fixture/node/V2bX"
sha256sum --check "$fixture/preserved.sha" >/dev/null
grep -q 'systemctl stop V2bX.service' "$fixture/actions"
[[ "$(<"$fixture/running")" == true ]]
backup="$(sed -n 's/^升级前备份：//p' "$fixture/success.log")"
cmp "$backup/V2bX" "$fixture/original"
tar -tf "$backup/original-files.tar" | grep -q 'config.json'
pass 'running node upgrades; config/certificate/route/service hashes remain unchanged and backup is readable'
bash "$backup/rollback.sh" --rollback "$backup" --yes > "$fixture/rollback.log"
cmp "$fixture/node/V2bX" "$fixture/original"
sha256sum --check "$fixture/preserved.sha" >/dev/null
[[ "$(<"$fixture/running")" == true ]]
pass 'explicit rollback restores only binary and the original service state'
reset_node
echo false > "$fixture/running"
upgrade > "$fixture/stopped.log"
grep -q audit- "$fixture/node/V2bX"
[[ "$(<"$fixture/running")" == false ]]
! grep -Eq 'systemctl (start|stop)' "$fixture/actions"
pass 'stopped node stays stopped during upgrade'
reset_node
if LEGACY_START_FAIL=1 upgrade > "$fixture/failed.log" 2>&1; then exit 1; fi
cmp "$fixture/node/V2bX" "$fixture/original"
[[ "$(<"$fixture/running")" == true ]]
sha256sum --check "$fixture/preserved.sha" >/dev/null
pass 'failed new startup automatically restores old binary and running state'
reset_node
if LEGACY_RESTART_LOOP=1 upgrade > "$fixture/loop.log" 2>&1; then exit 1; fi
cmp "$fixture/node/V2bX" "$fixture/original"
[[ "$(<"$fixture/running")" == true ]]
pass 'rapid service restart is rejected and rolled back'
reset_node
if LEGACY_BUILD_FAIL=1 upgrade > "$fixture/build-failed.log" 2>&1; then exit 1; fi
cmp "$fixture/node/V2bX" "$fixture/original"
! grep -Eq 'systemctl (start|stop)' "$fixture/actions"
pass 'failed build never stops original service'
reset_node
if LEGACY_DIRTY=1 upgrade > "$fixture/dirty.log" 2>&1; then exit 1; fi
! grep -Eq 'systemctl (start|stop)' "$fixture/actions"
git -C "$fixture/source" restore go.mod
pass 'dependency mutation rejects pinned source before replacing binary'
reset_node
if LEGACY_ARCH=s390x upgrade > "$fixture/arch.log" 2>&1; then exit 1; fi
[[ ! -s "$fixture/actions" ]]
pass 'unsupported architecture is rejected before build or service calls'
reset_node
mv "$fixture/V2bX.service" "$fixture/unit.saved"
upgrade > "$fixture/openrc.log"
grep -q 'rc-service V2bX stop' "$fixture/actions"
grep -q 'rc-service V2bX start' "$fixture/actions"
sha256sum --check <(grep -v 'V2bX.service' "$fixture/preserved.sha") >/dev/null
mv "$fixture/unit.saved" "$fixture/V2bX.service"
pass 'OpenRC upgrade uses the original OpenRC service and preserves files'
reset_node
upgrade > "$fixture/tamper.log"
backup="$(sed -n 's/^升级前备份：//p' "$fixture/tamper.log")"
echo changed >> "$fixture/node/V2bX"
before="$(sha256sum "$fixture/node/V2bX")"
if bash "$backup/rollback.sh" --rollback "$backup" --yes > "$fixture/tamper-rejected.log" 2>&1; then exit 1; fi
[[ "$(sha256sum "$fixture/node/V2bX")" == "$before" ]]
pass 'old rollback cannot overwrite a later changed binary'
echo "Legacy upgrade checks passed: $passed. Services and compiler mocked; live business traffic is tested separately."
