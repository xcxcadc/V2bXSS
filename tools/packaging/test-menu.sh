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
[[ "$*" == 'status --no-pager --full V2bX-audit-test.service' ]] || exit 90
exit "${MENU_TEST_STATUS:-0}"
STUB
cat > "$fixture/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MENU_TEST_LOG"
[[ "$*" == '--unit V2bX-audit-test.service --no-pager --lines 100' ]]
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
grep -Fq '请输入 0-10' "$fixture/navigation.log"
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
echo 'Menu checks passed: 5.'
