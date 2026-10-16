#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Upgrade the original service in place; never call the independent install.sh.
repository=https://github.com/xcxcadc/V2bXSS.git
branch=dev_new
legacy_root=/usr/local/V2bX
legacy_binary="$legacy_root/V2bX"
config_dir=/etc/V2bX
systemd_unit=/etc/systemd/system/V2bX.service
openrc_unit=/etc/init.d/V2bX
backup_base=/var/backups/v2bxss-legacy
state_dir=/opt/v2bxss-legacy-upgrade
service_name=V2bX.service
openrc_name=V2bX
build_tags='sing xray hysteria2 with_quic with_grpc with_utls with_wireguard with_acme with_gvisor'
source_dir=''
requested_commit=''
rollback_dir=''
yes=false
dry_run=false
transaction=false
replaced=false
was_running=false
backup_dir=''

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1"; }
usage() {
    cat <<'HELP'
原版节点升级为 xcxcadc/V2bXSS 二开（独立于新装菜单）
bash upgrade-legacy-node.sh [--yes] [--commit 完整SHA]
bash upgrade-legacy-node.sh --dry-run
bash upgrade-legacy-node.sh --rollback /var/backups/v2bxss-legacy/备份名 [--yes]

自动获取本仓库 dev_new 最新源码、准备依赖并构建。
只替换 /usr/local/V2bX/V2bX；保留配置、证书、端口、路由、服务定义及自启设置。
运行中的服务重启一次，停止的服务保持停止。替换/启动失败自动恢复。
--dry-run 只检查现有安装，不下载、不安装依赖、不构建、不修改文件或服务。
--source PATH --commit SHA 支持干净本地源码（需已有 Go 和依赖缓存）。
回滚只恢复二进制，不覆盖后来修改的配置。
支持 Linux amd64/arm64、systemd/OpenRC；其他架构明确拒绝。
HELP
}
while (($#)); do
    case "$1" in
        --yes) yes=true; shift ;;
        --dry-run) dry_run=true; shift ;;
        --commit|--source|--rollback)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || die "$1 缺少参数"
            case "$1" in
                --commit) requested_commit="$2" ;;
                --source) source_dir="$2" ;;
                --rollback) rollback_dir="$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ -z "$requested_commit" || "$requested_commit" =~ ^[a-fA-F0-9]{40}$ ]] || die '--commit 需要完整 40 位提交号'
[[ -z "$source_dir" || -n "$requested_commit" ]] || die '--source 必须同时指定 --commit'
[[ -z "$rollback_dir" || ( -z "$source_dir" && -z "$requested_commit" ) ]] || die '--rollback 不能与源码选项混用'
[[ "$(uname -s)" == Linux && "$(id -u)" == 0 ]] || die '请在 Linux 服务器使用 root 执行'
case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die '仅支持 Linux amd64/arm64，未修改原节点' ;;
esac
safe_path() {
    local path="$1"
    [[ "$path" == /* ]] || die '只接受绝对路径'
    while [[ "$path" != / ]]; do
        [[ ! -L "$path" ]] || die "拒绝符号链接目标：$path"
        path="$(dirname -- "$path")"
    done
}
for path in "$legacy_root" "$config_dir" "$systemd_unit" "$openrc_unit" "$backup_base" "$state_dir"; do safe_path "$path"; done
[[ -f "$legacy_binary" && ! -L "$legacy_binary" && -x "$legacy_binary" ]] || die '未找到原版 /usr/local/V2bX/V2bX 可执行文件'
[[ -d "$config_dir" && -f "$config_dir/config.json" ]] || die '未找到原版 /etc/V2bX/config.json'
if [[ -f "$systemd_unit" ]] && command -v systemctl >/dev/null && grep -Fq "$legacy_binary" "$systemd_unit"; then
    manager=systemd
    effective_exec="$(systemctl show "$service_name" --property=ExecStart --value)"
    [[ "$effective_exec" == *"path=$legacy_binary "* ]] || die '有效 ExecStart 与原版程序路径不一致，请核对自定义服务'
elif [[ -f "$openrc_unit" ]] && command -v rc-service >/dev/null && grep -Fq "$legacy_binary" "$openrc_unit"; then
    manager=openrc
else die '未识别到原版 systemd/OpenRC 服务；本脚本不新建服务'; fi
active() {
    if [[ "$manager" == systemd ]]; then systemctl is-active --quiet "$service_name"
    else rc-service "$openrc_name" status >/dev/null 2>&1; fi
}
stop_service() {
    if [[ "$manager" == systemd ]]; then systemctl stop "$service_name"
    else rc-service "$openrc_name" stop; fi
}
start_service() {
    if [[ "$manager" == systemd ]]; then systemctl start "$service_name"
    else rc-service "$openrc_name" start; fi
}
stable_service() {
    local i pid='' observed=''
    for ((i=0; i<15; i++)); do
        if active; then break; fi
        sleep 1
    done
    active || return 1
    if [[ "$manager" == systemd ]]; then
        pid="$(systemctl show "$service_name" --property=MainPID --value)"
        [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    fi
    for ((i=0; i<12; i++)); do
        sleep 1
        active || return 1
        if [[ "$manager" == systemd ]]; then
            observed="$(systemctl show "$service_name" --property=MainPID --value)"
            [[ "$observed" == "$pid" ]] || return 1
        fi
    done
}
confirm() {
    if ! $yes; then
        local answer
        read -r -p '确认执行？[y/N]：' answer || die '输入结束，未执行替换'
        [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消。'; exit 0; }
    fi
}
if active; then was_running=true; fi
printf '原版服务：%s；当前运行：%s\n程序：%s\n配置目录：%s\n' "$manager" "$was_running" "$legacy_binary" "$config_dir"
if $dry_run; then
    echo 'DRY RUN：原版安装可识别。未下载、构建或改变文件/服务。'
    exit 0
fi
dependencies() {
    local missing=false dep
    for dep in git curl python3 tar gzip sha256sum realpath flock timeout; do
        command -v "$dep" >/dev/null || missing=true
    done
    if $missing; then
        echo '正在准备构建依赖（不停止原服务）……'
        if command -v apt-get >/dev/null; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y git curl python3 ca-certificates tar gzip coreutils util-linux
        elif command -v dnf >/dev/null; then
            dnf install -y git curl python3 ca-certificates tar gzip coreutils util-linux
        elif command -v yum >/dev/null; then
            yum install -y git curl python3 ca-certificates tar gzip coreutils util-linux
        elif command -v apk >/dev/null; then
            apk add git curl python3 ca-certificates tar gzip coreutils util-linux
        else die '请安装 git curl python3 ca-certificates tar gzip coreutils util-linux'; fi
    fi
    for dep in git curl python3 tar gzip sha256sum realpath flock timeout install cp mv cmp chmod chown; do need "$dep"; done
}
if [[ -z "$rollback_dir" ]]; then dependencies
else for dep in realpath flock sha256sum install cp mv; do need "$dep"; done; fi
install -d -m 0700 "$state_dir"
safe_path "$state_dir/operation.lock"
exec 9>"$state_dir/operation.lock"
flock -n 9 || die '另一项原版升级/回滚正在进行'
atomic_binary() {
    local input="$1" temporary
    temporary="$(mktemp "$legacy_root/.V2bX-upgrade.XXXXXXXX")"
    cp -p -- "$input" "$temporary"
    mv -f -- "$temporary" "$legacy_binary"
}
on_exit() {
    local code=$?
    trap - EXIT INT TERM
    if $transaction; then
        set +e
        echo '升级未完成，自动恢复旧二进制和升级前运行状态……' >&2
        if $replaced; then
            stop_service
            if ! atomic_binary "$backup_dir/V2bX"; then
                printf '自动恢复文件失败，请使用备份人工恢复：%s\n' "$backup_dir" >&2
                exit 1
            fi
        fi
        if $was_running; then
            start_service && stable_service || echo '旧服务启动未稳定，请检查原服务日志。' >&2
        else stop_service; fi
        printf '备份仍保留：%s\n' "$backup_dir" >&2
        [[ "$code" != 0 ]] || code=1
    fi
    exit "$code"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ -n "$rollback_dir" ]]; then
    safe_path "$rollback_dir"
    rollback_dir="$(realpath -e -- "$rollback_dir")"
    [[ "$(dirname -- "$rollback_dir")" == "$backup_base" ]] || die '回滚必须指定本脚本备份目录的直接子目录'
    for file in V2bX old-binary.sha256 new-binary.sha256 service-state service-manager; do
        [[ -f "$rollback_dir/$file" && ! -L "$rollback_dir/$file" ]] || die "缺少有效备份文件：$file"
    done
    [[ "$(<"$rollback_dir/service-manager")" == "$manager" ]] || die '当前服务管理器与备份不一致'
    [[ "$(sha256sum "$rollback_dir/V2bX" | awk '{print $1}')" == "$(<"$rollback_dir/old-binary.sha256")" ]] || die '旧二进制备份哈希不符'
    [[ "$(sha256sum "$legacy_binary" | awk '{print $1}')" == "$(<"$rollback_dir/new-binary.sha256")" ]] || die '当前程序已经改变，拒绝用旧备份覆盖后续升级'
    [[ "$(<"$rollback_dir/service-state")" =~ ^(true|false)$ ]] || die '备份运行状态无效'
    printf '将仅恢复旧二进制；保留现有配置、证书和服务文件。备份：%s\n' "$rollback_dir"
    confirm
    checkpoint="$backup_base/rollback-$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID"
    install -d -m 0700 "$checkpoint"
    cp -p "$legacy_binary" "$checkpoint/V2bX"
    printf '%s\n' "$was_running" > "$checkpoint/service-state"
    backup_dir="$checkpoint"
    transaction=true
    stop_service
    atomic_binary "$rollback_dir/V2bX"
    replaced=true
    if [[ "$(<"$rollback_dir/service-state")" == true ]]; then start_service; stable_service || die '恢复的旧服务启动未稳定'; fi
    transaction=false
    printf '回滚完成；回滚前程序检查点：%s\n' "$checkpoint"
    exit 0
fi
work_dir="$(mktemp -d "${TMPDIR:-/var/tmp}/v2bxss-legacy-upgrade.XXXXXXXX")"
echo "源码/构建目录（保留用于核查）：$work_dir"
if [[ -n "$source_dir" ]]; then
    source_dir="$(realpath -e -- "$source_dir")"
    [[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=normal)" ]] || die '本地源码必须干净'
else
    source_dir="$work_dir/source"
    git init --quiet "$source_dir"
    git -C "$source_dir" config core.autocrlf false
    git -C "$source_dir" -c protocol.file.allow=never -c protocol.ext.allow=never -c http.sslVerify=true \
        -c http.followRedirects=false fetch --quiet --no-tags --depth 1 "$repository" "${requested_commit:-refs/heads/$branch}"
    git -C "$source_dir" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
fi
source_commit="$(git -C "$source_dir" rev-parse HEAD)"
[[ "$source_commit" =~ ^[a-f0-9]{40}$ ]] || die '源码提交无效'
[[ -z "$requested_commit" || "$source_commit" == "${requested_commit,,}" ]] || die '源码与指定提交不一致'
[[ -f "$source_dir/main.go" && -f "$source_dir/tools/packaging/configure-node.py" ]] || die '源码缺少二开构建文件'
required_go="$(awk '$1=="go" {print $2; exit}' "$source_dir/go.mod")"
[[ "$required_go" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || die '源码 Go 版本无效'
current_go="$(GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 go env GOVERSION 2>/dev/null || true)"
if ! python3 "$source_dir/tools/packaging/configure-node.py" go-compatible "$current_go" "$required_go"; then
    echo '正在准备独立 Go 工具链，不替换系统 Go……'
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 20 --max-time 120 'https://go.dev/dl/?mode=json' -o "$work_dir/go.json"
    read -r version filename checksum < <(python3 "$source_dir/tools/packaging/configure-node.py" go-download "$work_dir/go.json" "$arch" "$required_go")
    [[ "$version" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ && "$filename" == "$version.linux-$arch.tar.gz" && "$checksum" =~ ^[a-f0-9]{64}$ ]] || die '工具链下载元数据无效'
    toolchain="$state_dir/toolchains/$version"
    safe_path "$toolchain"
    if [[ ! -x "$toolchain/go/bin/go" ]]; then
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 20 --max-time 900 "https://go.dev/dl/$filename" -o "$work_dir/go.tgz"
        printf '%s  %s\n' "$checksum" "$work_dir/go.tgz" | sha256sum --check --strict
        install -d -m 0700 "$toolchain"
        tar -xzf "$work_dir/go.tgz" -C "$toolchain" --no-same-owner
    fi
    export PATH="$toolchain/go/bin:$PATH"
    python3 "$source_dir/tools/packaging/configure-node.py" go-compatible "$(GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 go env GOVERSION)" "$required_go" || die '工具链版本检查失败'
fi
candidate="$work_dir/V2bX"
# Keep upgrade caches separate from all node configuration and service files.
export GOMODCACHE="${GOMODCACHE:-$state_dir/cache/modules}" GOCACHE="${GOCACHE:-$state_dir/cache/build}"
export GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 CGO_ENABLED=0 GOOS=linux GOARCH="$arch"
export GOMAXPROCS="${GOMAXPROCS:-2}" GOMEMLIMIT="${GOMEMLIMIT:-384MiB}" GOFLAGS=-p=2
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}" GOSUMDB=sum.golang.org
echo "正在构建 $source_commit；原服务未停止，首次可能需要数分钟……"
(
    cd -- "$source_dir"
    go mod download
    go mod verify
    [[ -z "$(git status --porcelain --untracked-files=normal)" ]] || die '依赖准备改变了源码，拒绝安装'
    go build -trimpath -tags "$build_tags" \
        -ldflags "-X github.com/InazumaV/V2bX/cmd.version=audit-${source_commit:0:12} -s -w -buildid=" -o "$candidate" .
)
timeout 20 "$candidate" version > "$work_dir/version.txt" 2>&1 || die '候选程序无法运行'
grep -Fq "audit-${source_commit:0:12}" "$work_dir/version.txt" || die '候选版本不符'
new_hash="$(sha256sum "$candidate" | awk '{print $1}')"
old_hash="$(sha256sum "$legacy_binary" | awk '{print $1}')"
echo "只替换 $legacy_binary；保留配置、证书、geo 数据、路由、服务文件、管理脚本和自启状态。"
echo "新程序 SHA256：$new_hash"
echo '运行中的服务重启一次，已有连接会短暂中断；脚本不会修改面板累计流量。'
confirm
was_running=false
if active; then was_running=true; fi
backup_dir="$backup_base/$(date -u +%Y%m%dT%H%M%SZ)-${source_commit:0:12}-$BASHPID"
install -d -m 0700 "$backup_base" "$backup_dir"
cp -p "$legacy_binary" "$backup_dir/V2bX"
tar -cpf "$backup_dir/original-files.tar" -C / "${legacy_root#/}" "${config_dir#/}"
if [[ "$manager" == systemd ]]; then
    cp -a "$systemd_unit" "$backup_dir/service"
    systemctl cat "$service_name" > "$backup_dir/effective-service.txt"
else cp -a "$openrc_unit" "$backup_dir/service"; fi
printf '%s\n' "$old_hash" > "$backup_dir/old-binary.sha256"
printf '%s\n' "$new_hash" > "$backup_dir/new-binary.sha256"
printf '%s\n' "$was_running" > "$backup_dir/service-state"
printf '%s\n' "$manager" > "$backup_dir/service-manager"
printf '%s\n' "$source_commit" > "$backup_dir/new-source-commit"
install -m 0700 "${BASH_SOURCE[0]}" "$backup_dir/rollback.sh"
printf '升级前备份：%s\n回滚命令：bash %q --rollback %q\n' "$backup_dir" "$backup_dir/rollback.sh" "$backup_dir"
transaction=true
if $was_running; then stop_service; fi
[[ "$(sha256sum "$legacy_binary" | awk '{print $1}')" == "$old_hash" ]] || die '原程序在构建期间被其他操作改变，已取消'
chmod --reference="$legacy_binary" "$candidate"
chown --reference="$legacy_binary" "$candidate"
atomic_binary "$candidate"
replaced=true
if $was_running; then start_service; stable_service || die '新服务退出或发生重启，自动回滚'; fi
transaction=false
printf '升级完成；升级前运行：%s；配置与原服务定义未改写。\n备份：%s\n' "$was_running" "$backup_dir"
echo '运行状态检查不代替业务验收，请核对面板节点回执、流量增量、在线统计和到期用户撤权。'
echo '后续升级仍使用本脚本；不要使用原上游菜单的更新/重装操作，否则可能覆盖二开。'
