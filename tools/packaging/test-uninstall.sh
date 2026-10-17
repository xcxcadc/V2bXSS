#!/usr/bin/env bash
# Real file moves in disposable mount namespaces; service/network are stubs.
# Never uninstall a real node. No builds, dependencies or network are needed.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $# == 0 ]]; then
    [[ $(id -u) == 0 ]] || { echo 'Isolated uninstall fixtures require Linux root/unshare.' >&2; exit 2; }
    for scenario in active stopped cancel eof menu dropin wrong-exec unit-symlink backup-symlink \
                    lock-held cross-fs fail-stop fail-disable fail-reload restore-fail restore-refuse manager-only; do
        unshare --mount --propagation private bash -c '
            set -euo pipefail
            for root in /etc /opt /usr/local/bin; do mount -t tmpfs -o mode=0755 tmpfs "$root"; done
            mkdir /etc/.fixture-backups
            mount --bind /etc/.fixture-backups /var/backups
            exec bash "$1" --scenario "$2"
        ' bash "${BASH_SOURCE[0]}" "$scenario"
    done
    echo 'Uninstall/restore isolated scenarios passed: 17.'
    exit 0
fi
[[ $# == 2 && $1 == --scenario ]] || exit 2
scenario=$2
for path in /etc /opt /var/backups /usr/local/bin; do
    [[ $(findmnt -n -o FSTYPE --mountpoint "$path") == tmpfs ]] || {
        echo 'Refusing to test outside masked tmpfs roots.' >&2; exit 2;
    }
done
fixture=$(mktemp -d "${TMPDIR:-/tmp}/v2bxss-uninstall-check.XXXXXXXX")
touch "$fixture/calls"
mkdir -p "$fixture/bin" /etc/systemd/system /etc/v2bxss/releases/fixture /etc/V2bX /opt/other-app
entry="$script_dir/../../install.sh"
export UNINSTALL_FIXTURE=$fixture
export UNINSTALL_REAL_STAT
UNINSTALL_REAL_STAT=$(command -v stat)
cat > "$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$UNINSTALL_FIXTURE/calls"
action=$1; shift
if [[ "$action" != daemon-reload && "$*" != *v2bxss.service* ]]; then
    echo 'Unrelated service operation blocked' >&2; exit 91
fi
case "$action" in
    show)
        case "$*" in
            *FragmentPath*) [[ ! -f /etc/systemd/system/v2bxss.service ]] || echo /etc/systemd/system/v2bxss.service ;;
            *DropInPaths*) [[ ${UNINSTALL_DROPIN:-0} == 0 ]] || echo /run/systemd/system/v2bxss.service.d/override.conf ;;
            *ExecStart*) echo "{ path=${UNINSTALL_EXEC:-/etc/v2bxss/current/v2bxss} ; argv[]=v2bxss server ; }" ;;
            *) exit 92 ;;
        esac
        exit 0 ;;
    is-active) [[ $(<"$UNINSTALL_FIXTURE/active") == true ]] ;;
    is-enabled) [[ $(<"$UNINSTALL_FIXTURE/enabled") == true ]] ;;
    stop)
        [[ ${UNINSTALL_FAIL:-} != stop ]] || exit 41
        printf false > "$UNINSTALL_FIXTURE/active" ;;
    disable)
        [[ ${UNINSTALL_FAIL:-} != disable ]] || exit 42
        printf false > "$UNINSTALL_FIXTURE/enabled" ;;
    start)
        [[ ${UNINSTALL_RESTORE_FAIL:-0} == 0 ]] || exit 43
        printf true > "$UNINSTALL_FIXTURE/active" ;;
    enable) printf true > "$UNINSTALL_FIXTURE/enabled" ;;
    daemon-reload)
        if [[ ${UNINSTALL_FAIL:-} == reload && ! -e "$UNINSTALL_FIXTURE/reload-failed" ]]; then
            touch "$UNINSTALL_FIXTURE/reload-failed"; exit 44
        fi ;;
    reset-failed) : ;;
    *) exit 93 ;;
esac
STUB
cat > "$fixture/bin/stat" <<'STUB'
#!/usr/bin/env bash
if [[ ${UNINSTALL_CROSS_FS:-0} == 1 && ${!#} == /var/backups/v2bxss ]]; then echo 999999999; exit 0; fi
exec "$UNINSTALL_REAL_STAT" "$@"
STUB
for tool in git curl wget go apt-get; do
    printf '#!/usr/bin/env bash\necho "Unexpected network/compiler" >&2\nexit 99\n' > "$fixture/bin/$tool"
done
chmod 0755 "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
printf '{"fixture":"configuration preserved"}\n' > /etc/v2bxss/config.json
printf 'fixture private certificate\n' > /etc/v2bxss/tls.key
printf '#!/bin/sh\necho fixture-node\n' > /etc/v2bxss/releases/fixture/v2bxss
chmod 0700 /etc/v2bxss/releases/fixture/v2bxss
ln -s /etc/v2bxss/releases/fixture /etc/v2bxss/current
printf 'original configuration untouched\n' > /etc/V2bX/config.json
printf 'original unit untouched\n' > /etc/systemd/system/V2bX.service
printf 'external cert untouched\n' > /opt/other-app/external.pem
mkdir -p /var/backups/v2bxss/previous
printf 'previous backup untouched\n' > /var/backups/v2bxss/previous/marker
bash "$entry" repair > "$fixture/repair.log"
cp "$script_dir/v2bxss.service" /etc/systemd/system/v2bxss.service
printf true > "$fixture/active"
printf true > "$fixture/enabled"
if [[ "$scenario" == stopped || "$scenario" == manager-only ]]; then
    printf false > "$fixture/active"; printf false > "$fixture/enabled"
fi
if [[ "$scenario" == manager-only ]]; then mv /etc/systemd/system/v2bxss.service "$fixture/unused-unit"; fi
sha256sum /etc/v2bxss/config.json /etc/v2bxss/tls.key /etc/v2bxss/current/v2bxss > "$fixture/data.sha"
sha256sum /etc/V2bX/config.json /etc/systemd/system/V2bX.service /opt/other-app/external.pem /var/backups/v2bxss/previous/marker > "$fixture/unrelated.sha"
assert_installed() {
    [[ -f /etc/v2bxss/v2bxss && -f /usr/local/bin/v2bxss ]]
    sha256sum --check "$fixture/data.sha" >/dev/null
    [[ $(<"$fixture/active") == true && $(<"$fixture/enabled") == true ]]
}
case "$scenario" in
    cancel|eof)
        if [[ "$scenario" == cancel ]]; then printf 'no\n' | bash "$entry" uninstall --apply > "$fixture/result.log";
        else bash "$entry" uninstall --apply < /dev/null > "$fixture/result.log"; fi
        assert_installed
        ! grep -Eq '^(stop|disable|start|enable|daemon-reload)' "$fixture/calls"
        ;;
    dropin|wrong-exec|unit-symlink|backup-symlink|lock-held|cross-fs)
        case "$scenario" in
            dropin) export UNINSTALL_DROPIN=1 ;;
            wrong-exec) export UNINSTALL_EXEC=/usr/bin/unrelated-app ;;
            unit-symlink)
                mv /etc/systemd/system/v2bxss.service "$fixture/unit"
                ln -s "$fixture/unit" /etc/systemd/system/v2bxss.service ;;
            backup-symlink)
                mv /var/backups/v2bxss "$fixture/saved-backups"
                ln -s "$fixture/saved-backups" /var/backups/v2bxss ;;
            lock-held)
                mkdir -p /etc/v2bxss/manager
                exec 7>/etc/v2bxss/manager/operation.lock
                flock -n 7 ;;
            cross-fs) export UNINSTALL_CROSS_FS=1 ;;
        esac
        if printf 'UNINSTALL\n' | bash "$entry" uninstall --apply > "$fixture/result.log" 2>&1; then exit 1; fi
        assert_installed
        ! grep -Eq '^(stop|disable|start|enable|daemon-reload)' "$fixture/calls"
        ;;
    fail-stop|fail-disable|fail-reload)
        export UNINSTALL_FAIL=${scenario#fail-}
        if printf 'UNINSTALL\n' | bash "$entry" uninstall --apply > "$fixture/result.log" 2>&1; then exit 1; fi
        assert_installed
        [[ -f /etc/systemd/system/v2bxss.service ]]
        ;;
    active|stopped|menu|restore-fail|restore-refuse|manager-only)
        if [[ "$scenario" == menu ]]; then
            printf '13\nUNINSTALL\n' | bash "$entry" > "$fixture/result.log"
            ! grep -Fq '菜单仍可继续使用' "$fixture/result.log"
        else printf 'UNINSTALL\n' | bash "$entry" uninstall --apply > "$fixture/result.log"; fi
        [[ ! -e /etc/v2bxss && ! -e /etc/systemd/system/v2bxss.service && ! -e /usr/local/bin/v2bxss ]]
        [[ $(<"$fixture/active") == false && $(<"$fixture/enabled") == false ]]
        backup=$(sed -n 's/^卸载备份：//p' "$fixture/result.log")
        [[ -d "$backup/installation" && -f "$backup/complete" && $(stat -c %a "$backup") == 700 ]]
        bash -n "$backup/restore.sh"
        if [[ "$scenario" == restore-refuse ]]; then
            mkdir /etc/v2bxss
            printf 'new install\n' > /etc/v2bxss/new-marker
            if printf 'RESTORE\n' | bash "$backup/restore.sh" --apply > "$fixture/refuse.log" 2>&1; then exit 1; fi
            grep -Fxq 'new install' /etc/v2bxss/new-marker
            [[ -f "$backup/installation/config.json" ]]
        else
            if [[ "$scenario" == restore-fail ]]; then
                if printf 'RESTORE\n' | UNINSTALL_RESTORE_FAIL=1 bash "$backup/restore.sh" --apply > "$fixture/failed-restore.log" 2>&1; then exit 1; fi
                [[ ! -e /etc/v2bxss && ! -e /etc/systemd/system/v2bxss.service && ! -e /usr/local/bin/v2bxss ]]
                [[ -f "$backup/installation/config.json" ]]
            fi
            bash "$backup/restore.sh" > "$fixture/restore-plan.log"
            [[ ! -e /etc/v2bxss ]]
            printf 'no\n' | bash "$backup/restore.sh" --apply > "$fixture/restore-cancel.log"
            [[ ! -e /etc/v2bxss ]]
            printf 'RESTORE\n' | bash "$backup/restore.sh" --apply > "$fixture/restore.log"
            sha256sum --check "$fixture/data.sha" >/dev/null
            [[ -f /etc/v2bxss/v2bxss && -f /usr/local/bin/v2bxss ]]
            if [[ "$scenario" == stopped || "$scenario" == manager-only ]]; then
                [[ $(<"$fixture/active") == false && $(<"$fixture/enabled") == false ]]
            else [[ $(<"$fixture/active") == true && $(<"$fixture/enabled") == true ]]; fi
            printf '0\n' | v2bxss > "$fixture/restored-menu.log"
            grep -Fq '13. 卸载 V2bXSS' "$fixture/restored-menu.log"
        fi
        ;;
    *) exit 2 ;;
esac
sha256sum --check "$fixture/unrelated.sha" >/dev/null
! grep -Eq '(stop|disable|start|enable).*V2bX.service' "$fixture/calls"
echo "PASS: uninstall scenario $scenario; original node/external files/backups unchanged"
