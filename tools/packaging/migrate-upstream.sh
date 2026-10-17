#!/usr/bin/env bash
# Copy all upstream nodes/resources and switch services only after verification.
set -Eeuo pipefail
umask 077
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
base=/etc/v2bxss
old_service=V2bX.service
service=v2bxss.service
unit=/etc/systemd/system/v2bxss.service
apply=false
bundle='' version='' binary_hash='' manifest_hash='' rollback=''
die() { printf '迁移失败：%s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --apply) apply=true; shift ;;
        --bundle) bundle=${2:?}; shift 2 ;;
        --version) version=${2:?}; shift 2 ;;
        --binary-sha256) binary_hash=${2:?}; shift 2 ;;
        --manifest-sha256) manifest_hash=${2:?}; shift 2 ;;
        --rollback) rollback=${2:?}; shift 2 ;;
        *) die '用法：migrate-upstream.sh [bundle 校验参数 --apply] 或 --rollback 备份路径 --apply' ;;
    esac
done
for dep in systemctl python3 sha256sum realpath flock cp install find sort xargs timeout; do
    command -v "$dep" >/dev/null || die "缺少 $dep"
done
safe_path() {
    local item=$1
    [[ "$item" == /* ]] || die '需要绝对路径'
    while [[ "$item" != / ]]; do
        [[ ! -L "$item" ]] || die "不支持符号链接路径：$item"
        item=$(dirname -- "$item")
    done
}
for item in "$base" "$unit" /var/backups/v2bxss "$base/layout.lock" "$base/manager"; do safe_path "$item"; done
stable() {
    local pid i
    systemctl is-active --quiet "$1" || return 1
    pid=$(systemctl show "$1" --property=MainPID --value)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    for ((i=0; i<12; i++)); do
        sleep 1
        systemctl is-active --quiet "$1" || return 1
        [[ $(systemctl show "$1" --property=MainPID --value) == "$pid" ]] || return 1
    done
}
restore_old() {
    systemctl stop "$service" || return 1
    systemctl disable "$service" || return 1
    if [[ $(<"$backup/old-enabled") == true ]]; then systemctl enable "$old_service" || return 1; fi
    if [[ $(<"$backup/old-active") == true ]]; then systemctl start "$old_service" && stable "$old_service" || return 1; fi
}
if [[ -n "$rollback" ]]; then
    safe_path "$rollback"
    backup=$(realpath -e "$rollback")
    [[ $(dirname "$backup") == /var/backups/v2bxss ]] || die '备份目录不属于本管理器'
    for file in old-enabled old-active migrated-release binary.sha256; do
        [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || die '备份元数据不完整'
    done
    [[ $(<"$backup/old-enabled") =~ ^(true|false)$ && $(<"$backup/old-active") =~ ^(true|false)$ ]] || die '备份状态错误'
    [[ -L "$base/current" && $(realpath -e "$base/current") == "$(<"$backup/migrated-release")" ]] || die '已更新到其他版本，拒绝旧迁移回滚'
    [[ $(sha256sum "$base/current/v2bxss" | cut -d ' ' -f 1) == "$(<"$backup/binary.sha256")" ]] || die '迁移程序已经改变'
    if ! $apply; then echo 'DRY RUN：切回原版服务；保留全部新旧文件。'; exit 0; fi
    [[ $(id -u) == 0 && $(uname -s) == Linux ]] || die '需要 Linux root'
    exec 10>"$base/layout.lock"; flock -n 10 || die '另一项迁移正在运行'
    restore_old || die '切回失败；请检查保留的备份与服务日志'
    echo '已切回原版服务；新旧文件和备份全部保留。'
    exit 0
fi
python3 "$script_dir/migrate-upstream.py"
[[ ! -e "$base/current" && ! -L "$base/current" && ! -e "$base/config.json" && ! -e "$unit" ]] || die '目标已有节点安装，拒绝覆盖'
[[ $(systemctl show "$old_service" --property=FragmentPath --value) == /etc/systemd/system/V2bX.service ]] || die '原版有效 unit 路径不是标准安装'
[[ -z $(systemctl show "$old_service" --property=DropInPaths --value) ]] || die '原服务含自定义 drop-in，需人工审查'
[[ $(systemctl show "$old_service" --property=ExecStart --value) == *'path=/usr/local/V2bX/V2bX '* ]] || die '原服务执行路径不是标准安装'
if [[ -n "$bundle" ]]; then
    [[ -d "$bundle" && ! -L "$bundle" ]] || die '缺少受控 bundle'
    bash "$script_dir/install-test-node.sh" --bundle "$bundle" --version "$version" \
        --binary-sha256 "$binary_hash" --manifest-sha256 "$manifest_hash" --config /etc/V2bX/config.json
fi
if ! $apply; then
    echo 'DRY RUN：原版全目录配置/运行资源 → /etc/v2bxss；旧服务保持不变。'
    exit 0
fi
[[ $(id -u) == 0 && $(uname -s) == Linux && -n "$bundle" ]] || die '执行迁移需要 Linux root 和校验后的 bundle'
install -d -m 0700 "$base" /var/backups/v2bxss
exec 10>"$base/layout.lock"; flock -n 10 || die '另一项迁移正在运行'
backup="/var/backups/v2bxss/upstream-$(date -u +%Y%m%dT%H%M%SZ)-$$"
[[ ! -e "$backup" && ! -L "$backup" ]] || die '备份目标已存在'
install -d -m 0700 "$backup"
printf '迁移备份：%s\n' "$backup"
source_fingerprint=$(python3 "$script_dir/migrate-upstream.py" --fingerprint)
cp -a /etc/V2bX "$backup/config"
cp -a /usr/local/V2bX "$backup/runtime"
cp -a /etc/systemd/system/V2bX.service "$backup/service"
printf false > "$backup/old-active"; printf false > "$backup/old-enabled"
if systemctl is-active --quiet "$old_service"; then printf true > "$backup/old-active"; fi
if systemctl is-enabled --quiet "$old_service"; then printf true > "$backup/old-enabled"; fi
python3 "$script_dir/migrate-upstream.py" "$backup/staged"
timeout 20 "$bundle/v2bxss" version > "$backup/new-version.txt" 2>&1 || die '二开程序无法运行；未停止原节点'
switching=false
on_exit() {
    local code=$?
    trap - EXIT INT TERM
    if $switching && [[ $code != 0 ]]; then
        echo '迁移失败，正在恢复原服务。全部文件均保留。' >&2
        restore_old || echo "恢复未完成，请检查 $backup" >&2
    fi
    exit "$code"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Copy complete config trees, including JSON5, Includes, TLS and unknown options.
# The original working directory is retained in a separate runtime subtree.
cp -a "$backup/staged/config/." "$base/"
cp -a "$backup/staged/runtime" "$base/legacy-runtime"
bash "$script_dir/install-test-node.sh" --bundle "$bundle" --version "$version" \
    --binary-sha256 "$binary_hash" --manifest-sha256 "$manifest_hash" --apply
install -m 0644 "$backup/staged/service" "$unit"
install -d -m 0700 "$base/manager"
install -m 0600 "$unit" "$base/manager/migrated-service"
printf '%s\n' "$(realpath -e "$base/current")" > "$backup/migrated-release"
sha256sum "$base/current/v2bxss" | cut -d ' ' -f 1 > "$backup/binary.sha256"
install -m 0700 "${BASH_SOURCE[0]}" "$backup/rollback-upstream.sh"
printf '回滚：bash %q --rollback %q --apply\n' "$backup/rollback-upstream.sh" "$backup"
systemctl daemon-reload
[[ $(python3 "$script_dir/migrate-upstream.py" --fingerprint) == "$source_fingerprint" ]] || die '原配置/资源在迁移中发生变化，未切换原服务；请审查后重试'
switching=true
if [[ $(<"$backup/old-active") == true ]]; then
    systemctl stop "$old_service"
    systemctl start "$service"
    stable "$service" || die '二开服务启动不稳定'
fi
if [[ $(<"$backup/old-enabled") == true ]]; then systemctl enable "$service"; fi
systemctl disable "$old_service"
switching=false
echo '迁移完成：全部配置/多协议节点保留；管理命令 v2bxss。'
echo '请核对面板节点回执、流量/在线上报和到期撤权。未修改面板或防火墙。'
