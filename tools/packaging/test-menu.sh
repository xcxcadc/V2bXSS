#!/usr/bin/env bash
set -euo pipefail
# No real network, root writes or service changes. Run from an unprivileged host.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
entrypoint="$script_dir/../../install.sh"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/v2bxss-menu-check.XXXXXXXX")
mkdir "$fixture/bin"
export MENU_TEST_LOG="$fixture/services"
cat > "$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MENU_TEST_LOG"
[[ "$*" == 'status --no-pager --full v2bxss.service' ]] || exit 90
exit "${MENU_TEST_STATUS:-0}"
STUB
cat > "$fixture/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MENU_TEST_LOG"
case "$*" in
    '--unit v2bxss.service --no-pager --lines 100 --output short-iso' | \
    '--unit v2bxss.service --no-pager --lines 100 --output short-iso --follow' | \
    '--unit V2bX.service --no-pager --lines 0 --output short-iso --follow') ;;
    *) exit 91 ;;
esac
exit "${MENU_TEST_JOURNAL_STATUS:-0}"
STUB
cat > "$fixture/bin/uname" <<'STUB'
#!/usr/bin/env bash
echo Darwin
STUB
for tool in git curl apt-get go; do
    printf '#!/usr/bin/env bash\nprintf "Unexpected dependency/network call" >&2\nexit 99\n' > "$fixture/bin/$tool"
done
chmod 0755 "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
printf '0\n' | bash "$entrypoint" > "$fixture/exit.log"
grep -Fq 'V2bXSS 二开管理菜单' "$fixture/exit.log"
[[ ! -e "$MENU_TEST_LOG" ]]
echo 'PASS: no-argument menu opens and exits without dependencies or network'
printf 'unexpected\n7\n8\n0\n' | bash "$entrypoint" > "$fixture/navigation.log"
grep -Fq '请输入 0-13' "$fixture/navigation.log"
grep -Fq '13. 卸载 V2bXSS' "$fixture/navigation.log"
grep -Fq '查看实时运行 / 连接日志' "$fixture/navigation.log"
grep -Fq '1. 安装最新二开版本' "$fixture/navigation.log"
grep -Fq '2. 更新到最新二开版本' "$fixture/navigation.log"
grep -Fq '11. 添加对接节点' "$fixture/navigation.log"
[[ $(wc -l < "$MENU_TEST_LOG") == 2 ]]
echo 'PASS: invalid input returns to menu; status/logs target only fork service'
printf '7\n0\n' | MENU_TEST_STATUS=3 bash "$entrypoint" > "$fixture/inactive.log"
grep -Fq '菜单仍可继续使用' "$fixture/inactive.log"
echo 'PASS: inactive service status does not close the menu'
printf '1\n0\n' | bash "$entrypoint" > "$fixture/host.log" 2>&1
grep -Fq 'Linux root is required' "$fixture/host.log"
echo 'PASS: unsupported host cannot install and returns to menu'
bash "$entrypoint" < /dev/null > "$fixture/eof.log"
echo 'PASS: closed stdin exits without hanging'

bash "$entrypoint" logs -f > "$fixture/follow.log"
bash "$entrypoint" logs --follow --lines 0 --service V2bX.service > "$fixture/legacy-follow.log"
grep -Fxq -- '--unit V2bX.service --no-pager --lines 0 --output short-iso --follow' "$MENU_TEST_LOG"
echo 'PASS: live CLI supports both service layouts without starting or restarting either'

MENU_TEST_JOURNAL_STATUS=130 bash "$entrypoint" logs -f > "$fixture/interrupted.log"
printf '8\n0\n' | MENU_TEST_JOURNAL_STATUS=130 bash "$entrypoint" > "$fixture/interrupted-menu.log"
! grep -Fq '菜单仍可继续使用' "$fixture/interrupted-menu.log"
echo 'PASS: interrupted follow returns cleanly to the caller or menu'

if MENU_TEST_JOURNAL_STATUS=1 bash "$entrypoint" logs -f > "$fixture/journal-error.log" 2>&1; then
    echo 'journalctl error was hidden' >&2; exit 1
fi
echo 'PASS: real journal errors are not hidden as normal interruption'

calls_before=$(wc -l < "$MENU_TEST_LOG")
for args in 'logs --lines -1' 'logs --lines 10001' 'logs --lines' \
            'logs --service ssh.service' 'logs --service' 'logs --apply' \
            'logs --dry-run' 'restart -f --apply' 'install --follow'; do
    read -r -a values <<< "$args"
    if bash "$entrypoint" "${values[@]}" > "$fixture/rejected.log" 2>&1; then
        printf 'Unexpected success: %s\n' "$args" >&2; exit 1
    fi
done
[[ $(wc -l < "$MENU_TEST_LOG") == "$calls_before" ]]
echo 'PASS: invalid counts, unrelated services, mutation flags and misplaced log flags are rejected'
bash "$entrypoint" uninstall > "$fixture/uninstall-plan.log"
bash "$entrypoint" uninstall --dry-run > "$fixture/uninstall-dry-run.log"
grep -Fq 'DRY RUN' "$fixture/uninstall-plan.log"
grep -Fq '不永久删除' "$fixture/uninstall-dry-run.log"
[[ $(wc -l < "$MENU_TEST_LOG") == "$calls_before" ]]
echo 'PASS: uninstall defaults to a plan without service, network or file mutations'
# Load definitions without invoking the CLI, then exercise cancellation before
# any backup command can run. These use a temporary base and no host paths.
sed '/^if ((\$# == 0))/,$d' "$entrypoint" > "$fixture/functions.sh"
(
    source "$fixture/functions.sh"
    menu_base="$fixture/installation"
    mkdir -p "$menu_base/current" "$fixture/backups/previous"
    printf '%s\n' "$menu_base/current" > "$fixture/backups/previous/installed-release"
    printf previous > "$fixture/backups/previous/previous-release"
    printf '#!/usr/bin/env bash\ntouch %q\n' "$fixture/rollback-ran" > "$fixture/backups/previous/rollback-test-node.sh"
    # Redirect only the backup search into the fixture.
    eval "$(declare -f menu_rollback | sed "s|/var/backups/v2bxss/|$fixture/backups/|g")"
    for answer in '' '0' 'y\n0' 'y\n' 'y\nWRONG'; do
        printf '%b\n' "$answer" | menu_rollback
        [[ ! -e "$fixture/rollback-ran" ]]
    done
    menu_rollback < /dev/null
    [[ ! -e "$fixture/rollback-ran" ]]
    printf 'y\nROLLBACK\n' | menu_rollback
    [[ -f "$fixture/rollback-ran" ]]
)
echo 'PASS: rollback requires both confirmations; cancel and EOF never execute rollback'
(
    source "$fixture/functions.sh"
    menu_base="$fixture/guard"
    menu_config="$menu_base/config.json"
    eval "$(declare -f menu_check_install_mode | sed -e "s|/etc/systemd/system/v2bxss.service|$fixture/guard-unit|g" \
        -e "s|/etc/v2bx-audit-test/config.json|$fixture/old-config|g" -e "s|/etc/V2bX/config.json|$fixture/upstream-config|g")"
    menu_check_install_mode install
    if (menu_check_install_mode update) > "$fixture/missing-update.log" 2>&1; then exit 1; fi
    mkdir -p "$menu_base/current"
    printf '#!/usr/bin/env bash\n' > "$menu_base/current/v2bxss"
    chmod 0755 "$menu_base/current/v2bxss"
    printf '{}' > "$menu_config"
    menu_check_install_mode update
    if (menu_check_install_mode install) > "$fixture/duplicate-install.log" 2>&1; then exit 1; fi
)
echo 'PASS: install/update guards reject duplicate install and update before installation'
(
    source "$fixture/functions.sh"
    menu_require_host() { :; }
    menu_dependencies() { :; }
    menu_check_install_mode() { :; }
    menu_install_latest() { echo "build-$1"; }
    menu_configure() { echo "config-$1"; }
    for action in 1 2 3 11; do menu_action "$action"; done
) > "$fixture/dispatch.log"
printf 'build-install\nbuild-update\nconfig-3\nconfig-11\n' > "$fixture/dispatch.expected"
cmp "$fixture/dispatch.expected" "$fixture/dispatch.log"
echo 'PASS: menu 1 installs, 2 updates, 3 imports and 11 appends nodes'
echo 'Menu/log checks passed: 13.'
