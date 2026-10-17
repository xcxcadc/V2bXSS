#!/usr/bin/env bash
# Real configuration writes, fake services/editors, host directories masked.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $# == 0 ]]; then
    exec unshare --mount --propagation private bash -c '
        set -euo pipefail
        for root in /etc /usr/local/bin; do mount -t tmpfs -o mode=0755 tmpfs "$root"; done
        exec bash "$1" --isolated
    ' bash "${BASH_SOURCE[0]}"
fi
[[ $# == 1 && $1 == --isolated ]] || exit 2
for root in /etc /usr/local/bin; do
    [[ $(findmnt -n -o FSTYPE --mountpoint "$root") == tmpfs ]] || exit 2
done
fixture=$(mktemp -d /tmp/v2bxss-config-check.XXXXXXXX)
entry="$script_dir/../../install.sh"
mkdir -p "$fixture/bin"
export CONFIG_FIXTURE=$fixture
cat > "$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CONFIG_FIXTURE/calls"
case "$1" in
    is-active) [[ $(<"$CONFIG_FIXTURE/active") == true ]] ;;
    restart)
        if grep -Fq invalid.example /etc/v2bxss/config.json; then echo false > "$CONFIG_FIXTURE/active"; exit 1; fi
        echo true > "$CONFIG_FIXTURE/active" ;;
    stop) echo false > "$CONFIG_FIXTURE/active" ;;
    *) exit 98 ;;
esac
STUB
cat > "$fixture/bin/fix-config" <<'STUB'
#!/usr/bin/env bash
sed -i 's/invalid.example/valid.example/g' "$1"
STUB
cat > "$fixture/bin/journalctl" <<'STUB'
#!/usr/bin/env bash
echo 'fixture startup error (no credentials)'
STUB
chmod 0755 "$fixture/bin/"*
export PATH="$fixture/bin:$PATH" EDITOR="$fixture/bin/fix-config"
sed '/^if ((\$# == 0))/,$d' "$entry" > "$fixture/functions.sh"
source "$fixture/functions.sh"
manager_install "$entry"
menu_config_tool
menu_stable_service() { systemctl is-active --quiet "$service"; }
echo true > "$fixture/active"
cat > "$menu_config" <<'JSON'
{"Cores":[{"Type":"xray"}],"Nodes":[{"ApiConfig":{"ApiHost":"https://valid.example","ApiKey":"fixture-secret","NodeID":1,"NodeType":"vmess"},"Options":{"Core":"xray"}}]}
JSON
chmod 0600 "$menu_config"
cp "$menu_config" "$fixture/original.json"
sed 's/valid.example/invalid.example/g' "$menu_config" > "$fixture/candidate.json"
menu_config_draft "$fixture/candidate.json"
first=$menu_draft
if menu_try_config "$first" > "$fixture/failure.log"; then exit 1; fi
cmp "$menu_config" "$fixture/candidate.json"
cmp "$first/previous.json" "$fixture/original.json"
[[ $(<"$first/state") == failed && $(stat -c %a "$first/config.json") == 600 && $(stat -c %a "$first") == 700 ]]
printf '0\n' | menu_config_recovery "$first" > "$fixture/return.log"
cmp "$menu_config" "$fixture/candidate.json"
echo 'PASS: runtime failure and returning to main menu retain new config, draft and previous backup'
printf '3\n1\n3\n1\n2\n0\n' | menu_configure 3 > "$fixture/resume.log"
[[ $(<"$first/state") == applied ]]
grep -Fq valid.example "$menu_config"
! grep -Fq invalid.example "$menu_config"
grep -Fq 'fixture startup error' "$fixture/resume.log"
echo 'PASS: configuration submenu resumes failed draft, views logs, edits and retries without retyping node'
menu_config_draft "$fixture/candidate.json"
second=$menu_draft
if menu_try_config "$second" >/dev/null; then exit 1; fi
printf '4\n0\n0\n' | menu_config_recovery "$second" >/dev/null
cmp "$menu_config" "$fixture/candidate.json"
printf '4\ny\n' | menu_config_recovery "$second" >/dev/null
cmp "$menu_config" "$second/previous.json"
cmp "$second/config.json" "$fixture/candidate.json"
[[ $(<"$second/state") == restored && $(<"$fixture/active") == true ]]
echo 'PASS: restore requires explicit confirmation; attempted config survives restoration'
echo false > "$fixture/active"
menu_config_draft "$fixture/candidate.json"
if menu_try_config "$menu_draft" >/dev/null; then exit 1; fi
printf '4\ny\n' | menu_config_recovery "$menu_draft" >/dev/null
[[ $(<"$fixture/active") == false ]]
echo 'PASS: explicit restore preserves previously stopped service state'
cp "$menu_config" "$fixture/before-invalid.json"
printf '{invalid-json' > "$fixture/bad.json"
menu_config_draft "$fixture/bad.json"
calls_before=$(wc -l < "$fixture/calls")
if menu_try_config "$menu_draft" > "$fixture/invalid.log" 2>&1; then exit 1; fi
cmp "$menu_config" "$fixture/before-invalid.json"
[[ $(wc -l < "$fixture/calls") == "$calls_before" ]]
cmp "$menu_draft/config.json" "$fixture/bad.json"
echo 'PASS: invalid syntax stays editable, with no live-file replacement or restart'
! grep -Fq fixture-secret "$fixture/"*.log
echo 'PASS: manager output does not print API credentials'
printf '0\n' | v2bx > "$fixture/alias.log"
grep -Fq 'V2bXSS 二开管理菜单' "$fixture/alias.log"
echo 'PASS: v2bx opens self-contained fork manager'
mv /usr/local/bin/v2bx "$fixture/owned-alias"
printf '#!/bin/sh\necho unrelated\n' > /usr/local/bin/v2bx
manager_install "$entry" > "$fixture/conflict.log"
grep -Fq unrelated /usr/local/bin/v2bx
grep -Fq '保留现有' "$fixture/conflict.log"
echo 'PASS: existing unrelated v2bx entry is retained'
echo 'Configuration recovery checks passed: 8.'
