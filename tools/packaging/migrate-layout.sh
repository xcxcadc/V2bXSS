#!/usr/bin/env bash
# Migrate only the former independent audit-test installation, never /etc/V2bX.
set -Eeuo pipefail
umask 077
old_base=/opt/v2bx-audit-test
old_config=/etc/v2bx-audit-test
old_unit=/etc/systemd/system/V2bX-audit-test.service
old_service=V2bX-audit-test.service
proc_root=/proc
base=/etc/v2bxss
unit=/etc/systemd/system/v2bxss.service
service=v2bxss.service
backup_base=/var/backups/v2bxss
apply=false
rollback=''
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
die() { printf '迁移失败：%s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --apply) apply=true; shift ;;
        --rollback) rollback=${2:?missing backup}; shift 2 ;;
        *) die '用法：bash migrate-layout.sh [--apply] [--rollback 备份绝对路径]' ;;
    esac
done
for dep in realpath sha256sum systemctl install cp ln mv awk sed date flock timeout find dirname id uname cmp; do
    command -v "$dep" >/dev/null || die "缺少 $dep"
done
safe_path() {
    local item=$1
    [[ "$item" == /* ]] || die '只接受绝对路径'
    while [[ "$item" != / ]]; do
        [[ ! -L "$item" ]] || die "拒绝符号链接路径：$item"
        item=$(dirname -- "$item")
    done
}
for item in "$old_base" "$old_config" "$old_config/config.json" "$old_unit" "$base" "$base/config.json" "$base/releases" "$unit" "$backup_base"; do
    safe_path "$item"
done
stable() {
    local pid i
    systemctl is-active --quiet "$service" || return 1
    pid=$(systemctl show "$service" --property=MainPID --value)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    for ((i=0; i<12; i++)); do
        sleep 1
        systemctl is-active --quiet "$service" || return 1
        [[ $(systemctl show "$service" --property=MainPID --value) == "$pid" ]] || return 1
    done
}
restore_old() {
    systemctl stop "$service" || return 1
    systemctl disable "$service" || return 1
    if [[ $(<"$backup/old-enabled") == true ]]; then systemctl enable "$old_service" || return 1; fi
    if [[ $(<"$backup/old-active") == true ]]; then
        systemctl start "$old_service" || return 1
        systemctl is-active --quiet "$old_service" || return 1
    fi
}
if [[ -n "$rollback" ]]; then
    safe_path "$rollback"
    backup=$(realpath -e -- "$rollback")
    [[ $(dirname -- "$backup") == "$backup_base" ]] || die '备份不属于 v2bxss 备份目录'
    for file in old-enabled old-active migrated-release binary.sha256; do
        [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || die '备份元数据缺失'
    done
    [[ $(<"$backup/old-enabled") =~ ^(true|false)$ && $(<"$backup/old-active") =~ ^(true|false)$ ]] || die '备份状态无效'
    release=$(<"$backup/migrated-release")
    [[ $(dirname -- "$release") == "$base/releases" && ! -L "$release" && -f "$release/v2bxss" && ! -L "$release/v2bxss" ]] || die '迁移版本无效'
    [[ -L "$base/current" && $(realpath -e -- "$base/current") == "$release" ]] || die '已经更新到其他版本，拒绝旧迁移回滚'
    [[ $(sha256sum "$release/v2bxss" | awk '{print $1}') == "$(<"$backup/binary.sha256")" ]] || die '迁移程序已改变'
    if ! $apply; then echo 'DRY RUN：仅切回旧服务；新旧文件和配置均保留。'; exit 0; fi
    [[ $(id -u) == 0 && $(uname -s) == Linux ]] || die '需要 Linux root'
    exec 9>"$base/layout.lock"
    flock -n 9 || die '另一项迁移或回滚正在进行'
    restore_old
    echo '已切回旧服务；新目录、备份和管理命令保留。'
    exit 0
fi
[[ -f "$old_config/config.json" && -f "$old_unit" ]] || die '没有找到旧版独立安装'
[[ ! -e "$base/config.json" && ! -L "$base/current" && ! -e "$base/current" && ! -e "$unit" ]] || die '新目录已有节点安装；拒绝覆盖'
[[ -z $(systemctl show "$old_service" --property=DropInPaths --value) ]] || die '旧服务含自定义 drop-in，请先人工审查'
[[ $(systemctl show "$old_service" --property=ExecStart --value) == *"path=$old_base/current/V2bX "* ]] || die '旧服务程序路径不是标准独立安装'
[[ -f "$script_dir/v2bxss.service" ]] || die '缺少已审查的服务模板'
normalize_unit() {
    sed -e 's#/opt/v2bx-audit-test/current/V2bX#/etc/v2bxss/current/v2bxss#g' \
        -e 's#/etc/v2bx-audit-test#/etc/v2bxss#g' \
        -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' -e '/^Description=/d' "$1"
}
cmp -s <(normalize_unit "$old_unit") <(normalize_unit "$script_dir/v2bxss.service") ||
    die '旧服务含自定义参数，请先人工审查，避免丢失现有设置'
for item in current releases v2bxss manager toolchains build-cache; do
    [[ ! -e "$old_config/$item" && ! -L "$old_config/$item" ]] || die "旧配置目录含保留名称：$item"
done
binary="$old_base/current/V2bX"
if [[ ! -f "$binary" ]]; then
    # A running Linux executable remains recoverable even if its parent
    # directory was removed. Preserve it BEFORE stopping the old process.
    pid=$(systemctl show "$old_service" --property=MainPID --value)
    [[ "$pid" =~ ^[1-9][0-9]*$ && -r "$proc_root/$pid/exe" ]] || die '旧程序和运行中程序都不可读取，不能安全迁移'
    binary="$proc_root/$pid/exe"
fi
if ! $apply; then
    printf 'DRY RUN：复制旧配置和程序至 %s；保留旧文件；切换为 %s。\n' "$base" "$service"
    exit 0
fi
[[ $(id -u) == 0 && $(uname -s) == Linux ]] || die '需要 Linux root'
[[ -f "$script_dir/v2bxss.service" && -f "$script_dir/../../install.sh" ]] || die '需要完整、已审查的源码快照'
install -d -m 0700 "$base" "$backup_base"
exec 9>"$base/layout.lock"
flock -n 9 || die '另一项迁移或回滚正在进行'
stamp=$(date -u +%Y%m%dT%H%M%SZ)-$$
backup="$backup_base/layout-$stamp"
release="$base/releases/migrated-$stamp"
[[ ! -e "$backup" && ! -L "$backup" && ! -e "$release" && ! -L "$release" ]] || die '迁移备份或版本目录已经存在'
install -d -m 0700 "$backup" "$release"
cp -a "$old_config" "$backup/config"
cp -a "$old_unit" "$backup/service"
[[ ! -f /usr/local/bin/v2bxss ]] || cp -a /usr/local/bin/v2bxss "$backup/launcher"
install -m 0700 "$binary" "$backup/v2bxss"
timeout 20 "$backup/v2bxss" version > "$backup/version.txt" 2>&1 || die '旧程序无法执行，未停止节点'
sha256sum "$backup/v2bxss" | awk '{print $1}' > "$backup/binary.sha256"
printf false > "$backup/old-active"
printf false > "$backup/old-enabled"
if systemctl is-active --quiet "$old_service"; then printf true > "$backup/old-active"; fi
if systemctl is-enabled --quiet "$old_service"; then printf true > "$backup/old-enabled"; fi
printf '%s\n' "$release" > "$backup/migrated-release"
install -m 0700 "${BASH_SOURCE[0]}" "$backup/rollback-layout.sh"
printf '迁移备份：%s\n回滚：bash %q --rollback %q --apply\n' "$backup" "$backup/rollback-layout.sh" "$backup"
# Keep an old-layout restart path even when /opt was previously removed.
if [[ ! -f "$old_base/current/V2bX" ]]; then
    [[ ! -e "$old_base/current" && ! -L "$old_base/current" ]] || die '旧 current 无效，拒绝覆盖'
    recovered="$old_base/releases/recovered-$stamp"
    safe_path "$old_base/releases"
    install -d -m 0700 "$recovered"
    install -m 0700 "$backup/v2bxss" "$recovered/V2bX"
    ln -s "$recovered" "$old_base/current"
fi
cp -a "$old_config/." "$base/"
# Change only the former private root prefix, preserving JSON/JSON5 and all
# credentials/options. External certificate/config paths remain untouched.
while IFS= read -r -d '' file; do
    sed -i 's#/etc/v2bx-audit-test/#/etc/v2bxss/#g' "$file"
done < <(find "$base" -type f \( -name '*.json' -o -name '*.json5' \) -print0)
install -m 0700 "$backup/v2bxss" "$release/v2bxss"
printf 'version=migrated-%s\nlayout_migration=true\n' "$stamp" > "$release/BUILD-INFO"
ln -s "$release" "$base/current"
install -m 0644 "$script_dir/v2bxss.service" "$unit"
bash "$script_dir/../../install.sh" repair
systemctl daemon-reload
switching=false
on_exit() {
    local code=$?
    trap - EXIT INT TERM
    if $switching && [[ $code != 0 ]]; then
        echo '新服务切换失败，正在切回旧服务；所有文件均保留。' >&2
        restore_old || echo "自动切回未成功，请检查迁移备份：$backup" >&2
    fi
    exit "$code"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
switching=true
if [[ $(<"$backup/old-active") == true ]]; then
    systemctl stop "$old_service"
    systemctl start "$service"
    stable || die '新服务未稳定运行'
fi
if [[ $(<"$backup/old-enabled") == true ]]; then systemctl enable "$service"; fi
systemctl disable "$old_service"
switching=false
printf '迁移完成：%s；命令：v2bxss；服务：%s。旧文件未删除。\n' "$base" "$service"
