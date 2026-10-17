#!/usr/bin/env bash
set -euo pipefail
umask 077

# Non-privileged validation only. No --apply command is executed by this test.
[[ $# == 2 && "$1" == --bundle ]] || { echo 'Usage: bash test-packaging.sh --bundle BUILT_BUNDLE' >&2; exit 2; }
for protected in /etc/v2bxss /etc/v2bxss /etc/systemd/system/v2bxss.service /var/backups/v2bxss; do
    [[ ! -e "$protected" && ! -L "$protected" ]] || { echo 'Run on a clean validation workstation; isolated installation already exists' >&2; exit 1; }
done
bundle=$(realpath -e -- "$2")
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture_dir=$(mktemp -d "${TMPDIR:-/tmp}/v2bx-packaging-check.XXXXXXXX")
printf 'Validation fixture retained: %s\n' "$fixture_dir"
printf '{}\n' > "$fixture_dir/test-config.json"
version=$(awk -F= '$1=="version" {print $2}' "$bundle/BUILD-INFO")
binary_hash=$(sha256sum "$bundle/v2bxss" | cut -d ' ' -f 1)
manifest_hash=$(sha256sum "$bundle/SHA256SUMS" | cut -d ' ' -f 1)
args=(--bundle "$bundle" --version "$version" --binary-sha256 "$binary_hash" --manifest-sha256 "$manifest_hash" --config "$fixture_dir/test-config.json")
passed=0
check_rejected() {
    local label=$1
    shift
    if "$@" > "$fixture_dir/rejection-$passed.log" 2>&1; then
        echo "Unexpected success: $label" >&2
        exit 1
    fi
    passed=$((passed + 1))
    printf 'PASS: %s\n' "$label"
}
for script in "$script_dir"/*.sh; do bash -n "$script"; done
passed=$((passed + 1)); echo 'PASS: all packaging scripts parse'
bash "$script_dir/install-test-node.sh" "${args[@]}" > "$fixture_dir/default.log"
grep -q 'DRY RUN:' "$fixture_dir/default.log"
passed=$((passed + 1)); echo 'PASS: default install verifies without apply'
bash "$script_dir/install-test-node.sh" "${args[@]}" --start > "$fixture_dir/start-without-apply.log"
grep -q 'DRY RUN:' "$fixture_dir/start-without-apply.log"
passed=$((passed + 1)); echo 'PASS: start without apply remains dry run'
check_rejected 'apply/dry-run conflict rejected' bash "$script_dir/install-test-node.sh" "${args[@]}" --apply --dry-run
check_rejected 'wrong binary hash rejected' bash "$script_dir/install-test-node.sh" "${args[@]}" --binary-sha256 0000000000000000000000000000000000000000000000000000000000000000
check_rejected 'wrong manifest hash rejected' bash "$script_dir/install-test-node.sh" "${args[@]}" --manifest-sha256 0000000000000000000000000000000000000000000000000000000000000000
check_rejected 'wrong version rejected' bash "$script_dir/install-test-node.sh" "${args[@]}" --version invalid-version-for-test
cp -a "$bundle" "$fixture_dir/tampered"
printf '\n# tampered fixture\n' >> "$fixture_dir/tampered/rollback-test-node.sh"
check_rejected 'tampered component rejected' bash "$script_dir/install-test-node.sh" "${args[@]}" --bundle "$fixture_dir/tampered"
cp -a "$bundle" "$fixture_dir/traversal"
printf '%s  ../outside-file\n' "$binary_hash" >> "$fixture_dir/traversal/SHA256SUMS"
bad_manifest=$(sha256sum "$fixture_dir/traversal/SHA256SUMS" | cut -d ' ' -f 1)
check_rejected 'manifest path traversal rejected' bash "$script_dir/install-test-node.sh" "${args[@]}" --bundle "$fixture_dir/traversal" --manifest-sha256 "$bad_manifest"
check_rejected 'rollback outside fixed backup path rejected' bash "$script_dir/rollback-test-node.sh" --backup "$fixture_dir"
check_rejected 'missing rollback backup rejected' bash "$script_dir/rollback-test-node.sh" --backup "$fixture_dir/no-such-backup"
check_rejected 'rollback conflicting modes rejected' bash "$script_dir/rollback-test-node.sh" --backup "$fixture_dir" --apply --dry-run
for protected in /etc/v2bxss /etc/v2bxss /etc/systemd/system/v2bxss.service /var/backups/v2bxss; do
    [[ ! -e "$protected" && ! -L "$protected" ]] || { echo 'Unexpected installation target creation' >&2; exit 1; }
done
passed=$((passed + 1)); echo 'PASS: no installation/service/backup paths created'
printf 'Packaging checks passed: %s. Actual root/systemd install and rollback were not exercised.\n' "$passed"
