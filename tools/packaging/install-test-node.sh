#!/usr/bin/env bash
set -euo pipefail
umask 077

usage() {
    cat <<'USAGE'
Verify/install only the isolated V2bX-audit-test service. No network downloads.
Usage: bash install-test-node.sh --bundle PATH --version VERSION --binary-sha256 HASH --manifest-sha256 HASH [--config TEST_CONFIG] [--apply] [--start] [--dry-run]
Default: verify and print the plan without writing or starting anything.
--apply installs; --apply --start explicitly starts/restarts this isolated service.
First installation requires --config. Existing config is always preserved.
Check separate node IDs, listen ports and test API credentials before --start.
USAGE
}

bundle=''
version=''
expected_binary=''
expected_manifest=''
new_config=''
start_service=false
apply=false
explicit_dry_run=false
while (($#)); do
    case "$1" in
        --bundle) bundle="${2:?missing bundle}"; shift 2 ;;
        --version) version="${2:?missing version}"; shift 2 ;;
        --binary-sha256) expected_binary="${2:?missing binary hash}"; shift 2 ;;
        --manifest-sha256) expected_manifest="${2:?missing manifest hash}"; shift 2 ;;
        --config) new_config="${2:?missing test config}"; shift 2 ;;
        --apply) apply=true; shift ;;
        --start) start_service=true; shift ;;
        --dry-run) explicit_dry_run=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
if $apply && $explicit_dry_run; then echo '--apply and --dry-run conflict' >&2; exit 2; fi
[[ -n "$bundle" && "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$ ]] || { usage >&2; exit 2; }
[[ "$expected_binary" =~ ^[a-fA-F0-9]{64}$ && "$expected_manifest" =~ ^[a-fA-F0-9]{64}$ ]] || { echo 'Both trusted SHA256 hashes are required' >&2; exit 2; }
for required in sha256sum realpath install cmp awk date cp ln mv cut readlink id; do
    command -v "$required" >/dev/null || { echo "Missing command: $required" >&2; exit 1; }
done
bundle=$(realpath -e -- "$bundle")
[[ -d "$bundle" ]] || { echo 'Bundle directory not found' >&2; exit 1; }
for filename in V2bX BUILD-INFO install-test-node.sh rollback-test-node.sh V2bX-audit-test.service SHA256SUMS; do
    [[ -f "$bundle/$filename" && ! -L "$bundle/$filename" ]] || { echo "Missing or symbolic bundle file: $filename" >&2; exit 1; }
done
actual_binary=$(sha256sum "$bundle/V2bX" | cut -d ' ' -f 1)
actual_manifest=$(sha256sum "$bundle/SHA256SUMS" | cut -d ' ' -f 1)
[[ "${actual_binary,,}" == "${expected_binary,,}" && "${actual_manifest,,}" == "${expected_manifest,,}" ]] || { echo 'SHA256 mismatch; no installation performed' >&2; exit 1; }
if ! awk '{name=$2; sub(/^\*/, "", name)} NF != 2 || $1 !~ /^[a-fA-F0-9]+$/ || length($1) != 64 || name !~ /^(V2bX|BUILD-INFO|install-test-node\.sh|rollback-test-node\.sh|V2bX-audit-test\.service)$/ {bad=1} {if (seen[name]++) bad=1} END {exit bad || NR != 5}' "$bundle/SHA256SUMS"; then
    echo 'Invalid bundle manifest' >&2; exit 1
fi
(cd -- "$bundle" && sha256sum --check --strict SHA256SUMS)
[[ "$(awk -F= '$1=="version" {print $2}' "$bundle/BUILD-INFO")" == "$version" ]] || { echo 'Version differs from BUILD-INFO' >&2; exit 1; }
architecture=$(awk -F= '$1=="goarch" {print $2}' "$bundle/BUILD-INFO")
[[ "$(awk -F= '$1=="goos" {print $2}' "$bundle/BUILD-INFO")" == linux && "$architecture" =~ ^(amd64|arm64)$ ]] || { echo 'Bundle target must be Linux amd64 or arm64' >&2; exit 1; }

base_dir=/opt/v2bx-audit-test
config_dir=/etc/v2bx-audit-test
service_file=/etc/systemd/system/V2bX-audit-test.service
backup_base=/var/backups/v2bx-audit-test
for protected in /opt /etc /etc/systemd /etc/systemd/system /var /var/backups "$base_dir" "$base_dir/releases" "$config_dir" "$backup_base" "$service_file" "$config_dir/config.json"; do
    [[ ! -L "$protected" ]] || { echo "Refusing symbolic installation target: $protected" >&2; exit 1; }
done
[[ ! -e "$base_dir/current" || -L "$base_dir/current" ]] || { echo 'current must be a symlink, not an ordinary file/directory' >&2; exit 1; }
previous_release=''
if [[ -L "$base_dir/current" ]]; then
    previous_release=$(realpath -e -- "$base_dir/current")
    [[ "$(dirname -- "$previous_release")" == "$base_dir/releases" && -f "$previous_release/V2bX" && ! -L "$previous_release/V2bX" ]] || { echo 'Previous release escapes the isolated installation or is invalid' >&2; exit 1; }
fi
if [[ -f "$service_file" ]] && ! cmp -s "$service_file" "$bundle/V2bX-audit-test.service"; then
    echo 'Existing test unit differs; review it before installing' >&2; exit 1
fi
release_dir="$base_dir/releases/$version"
[[ ! -e "$release_dir" && ! -L "$release_dir" ]] || { echo 'Version is already installed; use a new version identifier' >&2; exit 1; }
if [[ -f "$config_dir/config.json" ]]; then
    [[ -z "$new_config" ]] || { echo 'Existing config is preserved; omit --config on upgrade' >&2; exit 1; }
else
    [[ -n "$new_config" ]] || { echo 'First installation requires an explicit test-node --config' >&2; exit 1; }
    [[ ! -L "$new_config" ]] || { echo 'Test config must not be a symlink' >&2; exit 1; }
    new_config=$(realpath -e -- "$new_config")
    [[ -f "$new_config" ]] || { echo 'Test config not found' >&2; exit 1; }
fi
if ! $apply; then
    printf 'DRY RUN: verified bundle %s (%s).\nWould install %s\nConfig: %s/config.json\nService: V2bX-audit-test.service\nStart requested: %s\nNo files or services changed. Add --apply to install.\n' "$version" "$architecture" "$release_dir" "$config_dir" "$start_service"
    exit 0
fi
[[ $(id -u) == 0 && $(uname -s) == Linux ]] || { echo 'Linux root required for installation' >&2; exit 1; }
case "$(uname -m):$architecture" in x86_64:amd64|aarch64:arm64|arm64:arm64) ;; *) echo 'Bundle architecture does not match this host' >&2; exit 1 ;; esac
command -v systemctl >/dev/null || { echo 'systemd is required' >&2; exit 1; }
backup_dir="$backup_base/$(date -u +%Y%m%dT%H%M%SZ)-$version-$$"
[[ ! -e "$backup_dir" && ! -L "$backup_dir" ]] || { echo 'Backup path already exists' >&2; exit 1; }
install -d -m 0700 "$backup_base" "$backup_dir"
# Record the rollback location before any release/config/service changes.
printf 'Backup: %s\n' "$backup_dir"
printf '%s\n' "$release_dir" > "$backup_dir/installed-release"
if [[ -n "$previous_release" ]]; then
    printf '%s\n' "$previous_release" > "$backup_dir/previous-release"
    cp -a "$previous_release" "$backup_dir/previous-release-files"
fi
if [[ -f "$config_dir/config.json" ]]; then cp -a "$config_dir/config.json" "$backup_dir/config.json"; fi
if [[ -f "$service_file" ]]; then cp -a "$service_file" "$backup_dir/service"; fi
systemctl is-active V2bX-audit-test.service > "$backup_dir/previous-service-state" || true
install -m 0755 "$bundle/rollback-test-node.sh" "$backup_dir/rollback-test-node.sh"
install -d -m 0700 "$base_dir" "$base_dir/releases" "$config_dir" "$release_dir"
install -m 0755 "$bundle/V2bX" "$release_dir/V2bX"
install -m 0600 "$bundle/BUILD-INFO" "$release_dir/BUILD-INFO"
install -m 0600 "$bundle/SHA256SUMS" "$release_dir/SHA256SUMS"
if [[ -n "$new_config" ]]; then install -m 0600 "$new_config" "$config_dir/config.json"; fi
install -m 0644 "$bundle/V2bX-audit-test.service" "$service_file"
[[ ! -e "$base_dir/current.next-$$" && ! -L "$base_dir/current.next-$$" ]] || { echo 'Temporary link already exists' >&2; exit 1; }
ln -s "$release_dir" "$base_dir/current.next-$$"
mv -Tf "$base_dir/current.next-$$" "$base_dir/current"
systemctl daemon-reload
printf 'Installed version: %s\nRollback preview: bash %q --backup %q\n' "$version" "$backup_dir/rollback-test-node.sh" "$backup_dir"
if $start_service; then
    systemctl restart V2bX-audit-test.service
    systemctl is-active --quiet V2bX-audit-test.service || { echo "Test service did not stay active; inspect journal. Backup: $backup_dir" >&2; exit 1; }
else
    echo 'Service was not started or restarted. A running process keeps its old binary until explicitly restarted.'
fi
