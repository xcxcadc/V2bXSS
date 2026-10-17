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
printf 'unexpected\n7\n8\n11\n0\n' | bash "$entrypoint" > "$fixture/navigation.log"
grep -Fq '请输入 0-12' "$fixture/navigation.log"
grep -Fq '查看实时运行 / 连接日志' "$fixture/navigation.log"
[[ $(wc -l < "$MENU_TEST_LOG") == 3 ]]
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
printf '11\n0\n' | MENU_TEST_JOURNAL_STATUS=130 bash "$entrypoint" > "$fixture/interrupted-menu.log"
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
echo 'Menu/log checks passed: 9.'
