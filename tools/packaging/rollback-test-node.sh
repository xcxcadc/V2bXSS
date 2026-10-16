#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Rollback only an isolated V2bX-audit-test installation. No files are deleted.
Usage: bash rollback-test-node.sh --backup /var/backups/v2bx-audit-test/NAME [--apply] [--start] [--dry-run]
Default: verify the selected backup and show the plan without changing anything.
--apply stops this test service and restores a prior release/config/unit when present.
--apply --start also starts the restored prior release. First installs are stopped only.
Existing upstream V2bX services, /etc/V2bX and all backups remain untouched.
USAGE
}

backup_dir=''
apply=false
start_service=false
explicit_dry_run=false
while (($#)); do
    case "$1" in
        --backup) backup_dir="${2:?missing backup}"; shift 2 ;;
        --apply) apply=true; shift ;;
        --start) start_service=true; shift ;;
        --dry-run) explicit_dry_run=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if $apply && $explicit_dry_run; then echo '--apply and --dry-run conflict' >&2; exit 2; fi
[[ -n "$backup_dir" ]] || { usage >&2; exit 2; }
for required in realpath dirname basename install ln mv cmp cp date id uname; do
    command -v "$required" >/dev/null || { echo "Missing command: $required" >&2; exit 1; }
done
base_dir=/opt/v2bx-audit-test
backup_base=/var/backups/v2bx-audit-test
config_dir=/etc/v2bx-audit-test
service_file=/etc/systemd/system/V2bX-audit-test.service
for protected in /opt /etc /etc/systemd /etc/systemd/system /var /var/backups "$base_dir" "$base_dir/releases" "$backup_base" "$config_dir" "$service_file" "$config_dir/config.json" "$backup_dir"; do
    [[ ! -L "$protected" ]] || { echo "Refusing symbolic rollback target: $protected" >&2; exit 1; }
done
backup_dir=$(realpath -e -- "$backup_dir")
[[ -d "$backup_dir" && "$(dirname -- "$backup_dir")" == "$backup_base" ]] || { echo 'Backup must be a direct child of the isolated backup directory' >&2; exit 1; }
for filename in installed-release previous-release config.json service; do
    [[ ! -L "$backup_dir/$filename" && ( ! -e "$backup_dir/$filename" || -f "$backup_dir/$filename" ) ]] || { echo 'Invalid backup entry type' >&2; exit 1; }
done
[[ -f "$backup_dir/installed-release" ]] || { echo 'Backup lacks installed-release metadata' >&2; exit 1; }
installed_release=$(<"$backup_dir/installed-release")
[[ "$(dirname -- "$installed_release")" == "$base_dir/releases" && "$(basename -- "$installed_release")" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$ ]] || { echo 'Invalid installed release in backup' >&2; exit 1; }
[[ -L "$base_dir/current" && "$(realpath -e -- "$base_dir/current")" == "$installed_release" ]] || { echo 'Current release differs from this backup; refusing to roll back a later installation' >&2; exit 1; }
previous_release=''
if [[ -f "$backup_dir/previous-release" ]]; then
    previous_release=$(<"$backup_dir/previous-release")
    [[ "$(dirname -- "$previous_release")" == "$base_dir/releases" && "$(basename -- "$previous_release")" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$ && ! -L "$previous_release" && -d "$previous_release" && ! -L "$previous_release/V2bX" && -f "$previous_release/V2bX" ]] || { echo 'Prior release is missing or outside the isolated installation' >&2; exit 1; }
    [[ ! -L "$backup_dir/previous-release-files" && -d "$backup_dir/previous-release-files" && ! -L "$backup_dir/previous-release-files/V2bX" && -f "$backup_dir/previous-release-files/V2bX" ]] || { echo 'Prior release backup is missing' >&2; exit 1; }
    cmp -s "$previous_release/V2bX" "$backup_dir/previous-release-files/V2bX" || { echo 'Prior binary differs from the backup; review before restoring manually' >&2; exit 1; }
fi
if ! $apply; then
    printf 'DRY RUN: stop V2bX-audit-test.service only.\nPrevious release: %s\nRestore prior config/unit when backed up. Start requested: %s\nNo files or services changed. Add --apply to roll back.\n' "${previous_release:-none (first installation; service stays stopped)}" "$start_service"
    exit 0
fi
[[ $(id -u) == 0 && $(uname -s) == Linux ]] || { echo 'Linux root required for rollback' >&2; exit 1; }
command -v systemctl >/dev/null || { echo 'systemd is required' >&2; exit 1; }
checkpoint="$backup_base/rollback-checkpoint-$(date -u +%Y%m%dT%H%M%SZ)-$$"
[[ ! -e "$checkpoint" && ! -L "$checkpoint" ]] || { echo 'Rollback checkpoint already exists' >&2; exit 1; }
install -d -m 0700 "$checkpoint"
printf '%s\n' "$installed_release" > "$checkpoint/current-release"
if [[ -f "$config_dir/config.json" ]]; then cp -a "$config_dir/config.json" "$checkpoint/config.json"; fi
if [[ -f "$service_file" ]]; then cp -a "$service_file" "$checkpoint/service"; fi
printf 'Rollback checkpoint: %s\n' "$checkpoint"
systemctl stop V2bX-audit-test.service
if [[ -z "$previous_release" ]]; then
    echo 'First installation stopped. Isolated files, configuration and backups retained; no existing upstream service changed.'
    exit 0
fi
if [[ -f "$backup_dir/config.json" ]]; then install -m 0600 "$backup_dir/config.json" "$config_dir/config.json"; fi
if [[ -f "$backup_dir/service" ]]; then install -m 0644 "$backup_dir/service" "$service_file"; fi
[[ ! -e "$base_dir/current.rollback-$$" && ! -L "$base_dir/current.rollback-$$" ]] || { echo 'Temporary rollback link already exists' >&2; exit 1; }
ln -s "$previous_release" "$base_dir/current.rollback-$$"
mv -Tf "$base_dir/current.rollback-$$" "$base_dir/current"
systemctl daemon-reload
printf 'Restored release: %s\n' "$previous_release"
if $start_service; then
    systemctl start V2bX-audit-test.service
    systemctl is-active --quiet V2bX-audit-test.service || { echo 'Restored test service did not stay active; inspect its journal' >&2; exit 1; }
else
    echo 'Restored test service remains stopped; start explicitly after checking configuration.'
fi
