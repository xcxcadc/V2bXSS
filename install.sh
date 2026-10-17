#!/usr/bin/env bash
set -euo pipefail
umask 077

# This entry installs this fork only. It never runs an upstream installer.
repository='https://github.com/xcxcadc/V2bXSS.git'
service='v2bxss.service'

# The downloaded entry is self-contained: opening the menu needs no checkout,
# Go installation, network request or root privileges.
menu_base=/etc/v2bxss
menu_config=/etc/v2bxss/config.json
menu_branch=dev_new

manager_require_target() {
    need_linux_root
    for target in /etc /usr /usr/local /usr/local/bin "$menu_base" "$menu_base/v2bxss" "$menu_base/manager" "$menu_base/toolchains" "$menu_config"; do
        [[ ! -L "$target" ]] || die "安装路径不能是符号链接：$target"
    done
    [[ ! -L /usr/local/bin/v2bxss ]] || die '/usr/local/bin/v2bxss 已有符号链接，请先检查'
    if [[ -e /usr/local/bin/v2bxss ]] && ! grep -Fq '# V2bXSS menu launcher' /usr/local/bin/v2bxss; then
        die '/usr/local/bin/v2bxss 已被其他程序使用'
    fi
}

menu_require_host() {
    manager_require_target
    need_command systemctl
    [[ -d /run/systemd/system ]] || die '需要使用 systemd 的 Linux 服务器'
    case "$(uname -m)" in
        x86_64) menu_arch=amd64 ;;
        aarch64|arm64) menu_arch=arm64 ;;
        *) die '当前支持 Linux amd64 / arm64' ;;
    esac
}

# Install the actual manager before its shortcut. This path also works without
# a compiler, source checkout, node binary or network, including after failure.
manager_install() {
    local source=$1 staged backup=''
    manager_require_target
    for dep in install mktemp mv cmp; do need_command "$dep"; done
    [[ -f "$source" ]] || die '管理脚本源文件不存在'
    install -d -m 0700 "$menu_base"
    if [[ -f "$menu_base/v2bxss" ]] && ! cmp -s "$source" "$menu_base/v2bxss"; then
        backup="/var/backups/v2bxss/manager-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        for target in /var /var/backups /var/backups/v2bxss "$backup"; do
            [[ ! -L "$target" ]] || die "备份路径不能是符号链接：$target"
        done
        install -d -m 0700 "$backup"
        cp -a "$menu_base/v2bxss" "$backup/v2bxss"
        [[ ! -f /usr/local/bin/v2bxss ]] || cp -a /usr/local/bin/v2bxss "$backup/launcher"
        printf '管理脚本备份：%s\n' "$backup"
    fi
    if ! cmp -s "$source" "$menu_base/v2bxss"; then
        staged=$(mktemp "$menu_base/.manager.XXXXXXXX")
        install -m 0700 "$source" "$staged"
        mv -Tf "$staged" "$menu_base/v2bxss"
    fi
    install -d -m 0755 /usr/local/bin
    staged=$(mktemp /usr/local/bin/.v2bxss.XXXXXXXX)
    cat > "$staged" <<'LAUNCHER'
#!/usr/bin/env bash
# V2bXSS menu launcher
manager=/etc/v2bxss/v2bxss
if [[ ! -f "$manager" ]]; then
    echo 'V2bXSS 管理脚本缺失；节点服务不受此提示影响。请重新运行修复命令：' >&2
    echo 'wget -N https://raw.githubusercontent.com/xcxcadc/V2bXSS/dev_new/install.sh && bash install.sh repair' >&2
    exit 1
fi
exec bash "$manager" "$@"
LAUNCHER
    chmod 0755 "$staged"
    if cmp -s "$staged" /usr/local/bin/v2bxss; then
        # Retain the harmless staged launcher rather than deleting user files.
        mv -Tf "$staged" "$menu_base/launcher.last-check"
    else
        mv -Tf "$staged" /usr/local/bin/v2bxss
    fi
    [[ -f "$menu_base/v2bxss" ]] || die '管理脚本安装校验失败'
}

menu_stable_service() {
    local i pid
    for ((i=0; i<15; i++)); do
        if systemctl is-active --quiet "$service"; then break; fi
        sleep 1
    done
    systemctl is-active --quiet "$service" || return 1
    pid=$(systemctl show "$service" --property=MainPID --value)
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
    for ((i=0; i<12; i++)); do
        sleep 1
        systemctl is-active --quiet "$service" || return 1
        [[ "$(systemctl show "$service" --property=MainPID --value)" == "$pid" ]] || return 1
    done
}

menu_dependencies() {
    local missing=false
    for dep in git curl python3 tar gzip sha256sum realpath flock; do
        command -v "$dep" >/dev/null || missing=true
    done
    if $missing; then
        echo '正在自动准备安装依赖……'
        if command -v apt-get >/dev/null; then
            apt-get update
            DEBIAN_FRONTEND=noninteractive apt-get install -y git curl python3 ca-certificates tar gzip coreutils util-linux
        elif command -v dnf >/dev/null; then
            dnf install -y git curl python3 ca-certificates tar gzip coreutils util-linux
        elif command -v yum >/dev/null; then
            yum install -y git curl python3 ca-certificates tar gzip coreutils util-linux
        else
            die '请先安装 git curl python3 ca-certificates tar gzip coreutils util-linux'
        fi
    fi
    for dep in git curl python3 tar gzip sha256sum realpath flock; do need_command "$dep"; done
    install -d -m 0700 "$menu_base" "$menu_base/manager"
    exec 9>"$menu_base/manager/operation.lock"
    flock -n 9 || die '另一个安装/配置操作正在进行，请稍后重试'
}

menu_fetch_source() {
    menu_work=$(mktemp -d "${TMPDIR:-/var/tmp}/v2bxss-menu.XXXXXXXX")
    install -d -m 0700 "$menu_work/tmp"
    export TMPDIR="$menu_work/tmp"
    menu_source="$menu_work/source"
    echo '正在获取 xcxcadc/V2bXSS 最新二开版本……'
    git init --quiet "$menu_source"
    git -C "$menu_source" config core.autocrlf false
    git -C "$menu_source" -c protocol.file.allow=never -c protocol.ext.allow=never \
        -c http.sslVerify=true -c http.followRedirects=false \
        fetch --quiet --no-tags --depth 1 "$repository" "refs/heads/$menu_branch"
    git -C "$menu_source" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
    menu_commit=$(git -C "$menu_source" rev-parse HEAD)
    [[ "$menu_commit" =~ ^[a-f0-9]{40}$ ]] || die '无法确认源码版本'
    printf '本次版本：%s\n' "$menu_commit"
    printf '二开源码：https://github.com/xcxcadc/V2bXSS/commit/%s\n' "$menu_commit"
}

menu_prepare_go() {
    # Use a suitable existing Go, otherwise install an isolated, checksummed
    # toolchain. Never replace /usr/local/go or the system package manager's Go.
    local current='' required
    required=$(awk '$1 == "go" {print $2; exit}' "$menu_source/go.mod")
    if command -v go >/dev/null; then
        current=$(GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 go env GOVERSION 2>/dev/null || true)
    fi
    if python3 "$menu_source/tools/packaging/configure-node.py" go-compatible "$current" "$required"; then return; fi
    local metadata archive filename checksum go_version go_root
    metadata="$menu_work/go-downloads.json"
    echo '正在自动准备独立 Go 编译环境（不会替换系统 Go）……'
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --retry 2 --connect-timeout 20 --max-time 120 'https://go.dev/dl/?mode=json' -o "$metadata"
    read -r go_version filename checksum < <(python3 "$menu_source/tools/packaging/configure-node.py" go-download "$metadata" "$menu_arch" "$required")
    [[ "$go_version" =~ ^go[0-9]+\.[0-9]+\.[0-9]+$ && "$filename" == "$go_version.linux-$menu_arch.tar.gz" && "$checksum" =~ ^[a-f0-9]{64}$ ]] || die 'Go 下载元数据无效'
    go_root="$menu_base/toolchains/$go_version"
    [[ ! -L "$go_root" ]] || die 'Go 工具链目录不能是符号链接'
    if [[ ! -x "$go_root/go/bin/go" ]]; then
        archive="$menu_work/$filename"
        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --retry 2 --connect-timeout 20 --max-time 900 "https://go.dev/dl/$filename" -o "$archive"
        printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --strict
        install -d -m 0700 "$menu_base/toolchains" "$go_root"
        tar -xzf "$archive" -C "$go_root" --no-same-owner
    fi
    export PATH="$go_root/go/bin:$PATH"
    current=$(GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 go env GOVERSION)
    python3 "$menu_source/tools/packaging/configure-node.py" go-compatible "$current" "$required" || die '自动安装的 Go 版本不满足源码要求'
}

menu_save_manager() {
    manager_install "$menu_source/install.sh"
    install -d -m 0700 "$menu_base/manager"
    install -m 0600 "$menu_source/tools/packaging/configure-node.py" "$menu_base/manager/configure-node.py"
}

menu_new_config() {
    local choice config_path
    printf '\n1. 按提示填写面板 / 节点信息（可添加多个节点）\n2. 导入已有 JSON 配置文件\n'
    read -r -p '请选择 [1]：' choice || return 1
    if [[ "${choice:-1}" == 1 ]]; then
        python3 "$menu_source/tools/packaging/configure-node.py" wizard --output "$menu_work/config.json"
    elif [[ "$choice" == 2 ]]; then
        read -r -p '配置文件的绝对路径：' config_path || return 1
        python3 "$menu_source/tools/packaging/configure-node.py" import --input "$config_path" --output "$menu_work/config.json"
    else
        die '无效选择'
    fi
}

menu_install_latest() {
    if [[ ! -f "$menu_config" && -f /etc/v2bx-audit-test/config.json ]]; then
        die '检测到旧版安装，请先选择菜单 12 迁移，避免重复节点或覆盖原配置'
    fi
    menu_fetch_source
    local args=() installed_commit=''
    if [[ -f "$menu_config" ]]; then
        echo '已存在配置：将完整保留，包括证书、混淆和多节点设置。'
    else
        menu_new_config
        args+=(--config "$menu_work/config.json")
    fi
    if [[ -f "$menu_base/current/BUILD-INFO" ]]; then
        installed_commit=$(awk -F= '$1 == "source_commit" {print $2; exit}' "$menu_base/current/BUILD-INFO")
    fi
    if [[ "$installed_commit" == "$menu_commit" ]]; then
        menu_save_manager
        echo '已经是本仓库最新版本，无需重新编译或重启。输入 v2bxss 可再次打开菜单。'
        return
    fi
    menu_prepare_go
    export GOMODCACHE="$menu_base/build-cache/modules" GOCACHE="$menu_base/build-cache/go"
    export GOPROXY='https://proxy.golang.org,direct' GOSUMDB=sum.golang.org
    export GOMAXPROCS="${GOMAXPROCS:-2}" GOMEMLIMIT="${GOMEMLIMIT:-384MiB}" GOFLAGS='-p=2'
    echo '正在下载校验依赖并编译二开；首次安装可能需要数分钟，请等待……'
    bash "$menu_source/install.sh" install --source "$menu_source" --commit "$menu_commit" \
        --arch "$menu_arch" --version "audit-${menu_commit:0:12}-$(date -u +%Y%m%d%H%M%S)" \
        --download-deps --apply --start "${args[@]}"
    menu_save_manager
    systemctl enable "$service"
    echo '安装完成。已开启开机自启；以后输入 v2bxss 打开菜单。'
    echo '后台托管审计规则自动同步，无需每次修改规则后重启节点。'
}

menu_migrate() {
    local answer
    echo '将旧版独立安装迁移到 /etc/v2bxss，保留旧配置和回滚资料。需要切换服务一次。'
    read -r -p '确认迁移？[y/N]：' answer || return 1
    [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消'; return; }
    menu_fetch_source
    bash "$menu_source/tools/packaging/migrate-layout.sh" --apply
    menu_save_manager
}

menu_configure() {
    [[ -f "$menu_config" ]] || die '请先选择 1 完成安装'
    menu_fetch_source
    if [[ "$1" == 2 ]]; then
        python3 "$menu_source/tools/packaging/configure-node.py" wizard --existing "$menu_config" --output "$menu_work/config.json"
    else
        local import_path answer
        read -r -p '导入配置的绝对路径：' import_path
        python3 "$menu_source/tools/packaging/configure-node.py" import --input "$import_path" --output "$menu_work/config.json"
        read -r -p '将替换当前配置（先备份），确认？[y/N]：' answer
        [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消'; return; }
    fi
    local backup
    backup="/var/backups/v2bxss/config-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    install -d -m 0700 "$backup"
    cp -a "$menu_config" "$backup/config.json"
    printf '配置备份：%s\n' "$backup/config.json"
    install -m 0600 "$menu_work/config.json" "${menu_config}.next"
    mv -Tf "${menu_config}.next" "$menu_config"
    if ! systemctl restart "$service" || ! menu_stable_service; then
        install -m 0600 "$backup/config.json" "$menu_config"
        systemctl restart "$service" || true
        die '新配置启动失败，已恢复旧配置；请检查菜单日志'
    fi
    echo '配置已保存并重启该二开服务。请在后台检查节点回执和用户/流量上报。'
}

menu_rollback() {
    local current backup selected='' answer
    current=$(realpath -e "$menu_base/current")
    # Pick only a backup for the currently installed release, never an older
    # unrelated snapshot or a config-only checkpoint.
    for backup in /var/backups/v2bxss/*; do
        [[ -d "$backup" && ! -L "$backup" && -f "$backup/installed-release" && -f "$backup/previous-release" ]] || continue
        if [[ "$(<"$backup/installed-release")" == "$current" ]]; then selected=$backup; fi
    done
    [[ -n "$selected" ]] || die '没有适用于当前版本的上一版备份'
    printf '将使用备份：%s\n' "$selected"
    read -r -p '回滚二进制及该备份中的配置并重启？[y/N]：' answer
    [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消'; return; }
    bash "$selected/rollback-test-node.sh" --backup "$selected" --apply --start
}

# Read only: never change the log level, configuration or service state.
# Keep the signal handler in a subshell so it cannot leak into other actions.
show_logs() (
    local unit=$1 lines=$2 follow=$3 result=0
    local args=(--unit "$unit" --no-pager --lines "$lines" --output short-iso)
    need_command journalctl
    if [[ "$follow" == true ]]; then
        args+=(--follow)
        printf '实时运行/连接日志：%s；按 Ctrl+C 结束查看，不会停止节点。\n' "$unit"
        printf '仅显示当前日志配置已输出的记录；审计命中证据请在后台查看。\n'
        trap ':' INT
    fi
    journalctl "${args[@]}" || result=$?
    if [[ "$follow" == true && "$result" == 130 ]]; then exit 0; fi
    exit "$result"
)

menu_action() {
    case "$1" in
        7) need_command systemctl; systemctl status --no-pager --full "$service"; return ;;
        8) show_logs "$service" 100 false; return ;;
        11) show_logs "$service" 100 true; return ;;
    esac
    menu_require_host
    case "$1" in
        1|2|3|12) menu_dependencies ;;
    esac
    case "$1" in
        1) menu_install_latest ;;
        2|3) menu_configure "$1" ;;
        4) systemctl start "$service"; menu_stable_service ;;
        5) systemctl stop "$service" ;;
        6) systemctl restart "$service"; menu_stable_service ;;
        9)
            if systemctl is-enabled --quiet "$service"; then
                systemctl disable "$service"
            else
                systemctl enable "$service"
            fi
            ;;
        10) menu_rollback ;;
        12) menu_migrate ;;
        *) die '无效菜单操作' ;;
    esac
}

interactive_menu() {
    local choice
    # Ctrl+C during the live viewer ends journalctl and returns to this menu.
    # The viewer runs in its own shell and installs its own INT handler.
    trap ':' INT
    while true; do
        printf '\n========== V2bXSS 二开管理菜单 ==========\n'
        printf '仓库：xcxcadc/V2bXSS · dev_new\n'
        printf ' 1. 安装 / 更新到最新二开版本\n 2. 添加对接节点（保留已有节点）\n 3. 导入 / 替换配置（自动备份）\n'
        printf ' 4. 启动服务\n 5. 停止服务\n 6. 重启服务\n 7. 查看运行状态\n 8. 查看最近日志\n'
        printf ' 9. 开启 / 关闭开机自启\n10. 回滚上一版本\n11. 查看实时运行 / 连接日志（Ctrl+C 返回）\n12. 迁移旧版独立安装到 /etc/v2bxss\n 0. 退出\n'
        printf '管理服务：%s\n' "$service"
        read -r -p '请选择 [0-12]：' choice || return 0
        case "$choice" in
            0) return 0 ;;
            [1-9]|10|11|12)
                # A separate shell preserves errexit inside every action even
                # when the menu catches its exit code to stay open on failure.
                bash "${BASH_SOURCE[0]}" __menu_action "$choice" || echo '操作未完成；请查看上方错误。菜单仍可继续使用。'
                ;;
            *) echo '请输入 0-12。' ;;
        esac
    done
}

usage() {
    cat <<'USAGE'
Build this V2bXSS fork and manage the independent v2bxss.service.

Interactive (recommended): bash install.sh
Reopen after installation: v2bxss
Repair only the menu/shortcut, with no build, network or service restart:
  bash install.sh repair
All new fork files use /etc/v2bxss; the node executable is current/v2bxss.
Menu option 12 migrates an old independent audit-test installation with backup.
The menu prepares dependencies, resolves this fork's latest commit, prompts for
node configuration and installs/starts it. Existing configuration is preserved.
The options below are the optional advanced/non-interactive interface.

Install (default is build, verify and print a plan):
  bash install.sh [install] --commit FULL_40_CHARACTER_SHA [--source CLEAN_CHECKOUT]
      [--version VERSION] [--arch amd64|arm64] [--config TEST_CONFIG]
      [--download-deps] [--apply] [--start] [--dry-run]

  --commit          Required exact source commit; branches and short SHAs are rejected.
  --source          Use a clean local checkout at that commit; otherwise fetch this fork.
  --config          Required on first installation; omit it on upgrade to preserve config.
  --download-deps   Explicitly populate the existing Go module cache with verified modules.
  --apply           Install the isolated test service; no other service is managed.
  --start           Start/restart that service only when combined with --apply.

Prerequisites: Git, GNU tools and a preinstalled Go >= the source go.mod minimum
with GOEXPERIMENT=jsonv2 support. The script never installs or replaces Go.
Without --download-deps the full module cache must already be available.
Build/source artifacts are retained in a printed temporary directory, even in dry run.
Actual installation needs Linux root and systemd. No prebuilt Release is assumed.

Management (only v2bxss.service):
  bash install.sh status
  bash install.sh logs
  bash install.sh logs -f [--lines 100]
  bash install.sh logs -f --service V2bX.service
  bash install.sh start|restart|stop [--apply | --dry-run]
Installed shortcut: v2bxss logs -f (menu option 11). Ctrl+C stops viewing only.
Log flags: -f/--follow, -n/--lines 0..10000, --service
v2bxss.service (default), V2bX-audit-test.service (old independent layout)
or V2bX.service (original-service upgrade).
The viewer uses current journal output; it does not enable access/debug logging
or collect every connection. Audit matches remain in the panel evidence page.
State-changing management commands print a plan unless --apply is explicit.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
need_command() { command -v "$1" >/dev/null || die "Missing command: $1"; }
need_linux_root() {
    need_command id
    need_command uname
    [[ $(uname -s) == Linux && $(id -u) == 0 ]] || die 'Linux root is required for --apply; existing services were not changed'
}

if (($# == 0)) || [[ "${1:-}" == menu ]]; then
    if [[ $(uname -s) == Linux && $(id -u) == 0 ]]; then
        manager_install "${BASH_SOURCE[0]}"
    fi
    interactive_menu
    exit 0
fi
if [[ "${1:-}" == repair ]]; then
    [[ $# == 1 ]] || die 'repair 不接受其他参数'
    manager_install "${BASH_SOURCE[0]}"
    echo '管理入口已修复：v2bxss；脚本：/etc/v2bxss/v2bxss。未重启或修改节点配置。'
    exit 0
fi
if [[ "${1:-}" == __menu_action ]]; then
    [[ $# == 2 ]] || die '无效菜单参数'
    menu_action "$2"
    exit 0
fi

action=install
if (($#)) && [[ "$1" != -* ]]; then
    action=$1
    shift
fi
case "$action" in
    install|status|logs|start|restart|stop) ;;
    help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac

commit=''
local_source=''
version=''
architecture=amd64
new_config=''
apply=false
start_service=false
explicit_dry_run=false
download_deps=false
has_install_option=false
has_log_option=false
follow_logs=false
log_lines=100
log_service=$service
while (($#)); do
    case "$1" in
        --commit) commit="${2:?missing full commit SHA}"; has_install_option=true; shift 2 ;;
        --source) local_source="${2:?missing local checkout}"; has_install_option=true; shift 2 ;;
        --version) version="${2:?missing version}"; has_install_option=true; shift 2 ;;
        --arch) architecture="${2:?missing architecture}"; has_install_option=true; shift 2 ;;
        --config) new_config="${2:?missing test config}"; has_install_option=true; shift 2 ;;
        --download-deps) download_deps=true; has_install_option=true; shift ;;
        --apply) apply=true; shift ;;
        --start) start_service=true; has_install_option=true; shift ;;
        --dry-run) explicit_dry_run=true; shift ;;
        -f|--follow) follow_logs=true; has_log_option=true; shift ;;
        -n|--lines)
            [[ $# -ge 2 ]] || die '--lines requires a number from 0 to 10000'
            log_lines=$2; has_log_option=true; shift 2 ;;
        --service)
            [[ $# -ge 2 ]] || die '--service requires a supported service name'
            log_service=$2; has_log_option=true; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
$apply && $explicit_dry_run && die '--apply and --dry-run conflict'
if $has_log_option; then
    [[ "$action" == logs ]] || die 'Log options can only be used with logs'
fi
[[ "$log_lines" =~ ^([0-9]{1,4}|10000)$ ]] || die '--lines requires a number from 0 to 10000'
case "$log_service" in
    v2bxss.service|V2bX-audit-test.service|V2bX.service) ;;
    *) die '--service supports only v2bxss.service, V2bX-audit-test.service or V2bX.service' ;;
esac

if [[ "$action" != install ]]; then
    $has_install_option && die 'Install options cannot be used with a management command'
    case "$action" in
        status)
            $apply && die 'status is read-only; omit --apply'
            need_command systemctl
            systemctl status --no-pager --full "$service"
            ;;
        logs)
            $apply && die 'logs is read-only; omit --apply'
            $explicit_dry_run && die 'logs is read-only; omit --dry-run'
            show_logs "$log_service" "$log_lines" "$follow_logs"
            ;;
        start|restart|stop)
            if ! $apply; then
                printf 'DRY RUN: would %s only %s. Add --apply to execute.\n' "$action" "$service"
                exit 0
            fi
            need_linux_root
            need_command systemctl
            systemctl "$action" "$service"
            if [[ "$action" != stop ]]; then systemctl is-active --quiet "$service"; fi
            ;;
    esac
    exit 0
fi

[[ "$commit" =~ ^[a-fA-F0-9]{40}$ ]] || die '--commit requires a full 40-character commit SHA from xcxcadc/V2bXSS'
commit=${commit,,}
[[ "$architecture" == amd64 || "$architecture" == arm64 ]] || die 'Supported targets: amd64 or arm64'
[[ -n "$version" ]] || version="audit-${commit:0:12}"
[[ "$version" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$ ]] || die 'Invalid version identifier'
export GOTOOLCHAIN=local

# Run these checks before fetching source. No toolchain bootstrap or auto switching.
for required in go git sha256sum realpath install cut mkdir mktemp awk bash; do need_command "$required"; done
if ! go_version=$(GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 GOPROXY=off GOSUMDB=off go env GOVERSION); then
    die 'The preinstalled Go must support GOEXPERIMENT=jsonv2; install a suitable Go toolchain separately. Go was not changed'
fi
[[ "$go_version" =~ ^go([0-9]+)\.([0-9]+)(\.[0-9]+)?([a-z][0-9]+)?$ ]] || die "Cannot validate preinstalled Go version: $go_version"
go_major=${BASH_REMATCH[1]}
go_minor=${BASH_REMATCH[2]}
go_patch=${BASH_REMATCH[3]:-.0}
go_patch=${go_patch#.}
[[ "$go_major" -gt 1 || ( "$go_major" -eq 1 && "$go_minor" -ge 25 ) ]] || die 'Go 1.25 or newer with jsonv2 is required; the system Go was not changed'
if $apply; then need_linux_root; need_command systemctl; fi

if [[ -n "$local_source" ]]; then
    local_source=$(realpath -e -- "$local_source")
    [[ -d "$local_source" ]] || die 'Local checkout not found'
    [[ "$local_source" -ef "$(git -C "$local_source" rev-parse --show-toplevel)" ]] || die '--source must name the checkout root'
    [[ "$(git -C "$local_source" rev-parse --verify HEAD)" == "$commit" ]] || die 'Local checkout HEAD does not match --commit'
    [[ -z "$(git -C "$local_source" status --porcelain --untracked-files=normal)" ]] || die 'Local checkout must be clean; commit/review changes before a reproducible install'
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/v2bxss-install.XXXXXXXX")
printf 'Source/build artifacts retained: %s\n' "$work_dir"
trap 'printf "Install failed. Artifacts retained: %s\n" "$work_dir" >&2' ERR
checkout="$work_dir/source"
git init --quiet "$checkout"
git -C "$checkout" config core.autocrlf false
if [[ -n "$local_source" ]]; then
    # Fetch a commit, never copy local configuration or uncommitted working files.
    git -C "$checkout" -c protocol.file.allow=always -c protocol.ext.allow=never \
        fetch --quiet --no-tags --depth 1 "$local_source" "$commit"
else
    git -C "$checkout" -c protocol.file.allow=never -c protocol.ext.allow=never \
        -c http.sslVerify=true -c http.followRedirects=false \
        fetch --quiet --no-tags --depth 1 "$repository" "$commit"
fi
git -C "$checkout" -c core.hooksPath=/dev/null -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD
actual_commit=$(git -C "$checkout" rev-parse --verify HEAD)
[[ "$actual_commit" == "$commit" ]] || die 'Fetched commit does not match the requested commit; nothing was installed'
for file in go.mod go.sum main.go tools/packaging/build-local-bundle.sh tools/packaging/install-test-node.sh; do
    [[ -f "$checkout/$file" && ! -L "$checkout/$file" ]] || die "Selected commit lacks a regular required file: $file"
done
minimum_go=$(awk '$1 == "go" {print $2; exit}' "$checkout/go.mod")
[[ "$minimum_go" =~ ^([0-9]+)\.([0-9]+)(\.[0-9]+)?$ ]] || die 'Cannot read the Go minimum from source go.mod'
minimum_major=${BASH_REMATCH[1]}
minimum_minor=${BASH_REMATCH[2]}
minimum_patch=${BASH_REMATCH[3]:-.0}
minimum_patch=${minimum_patch#.}
if (( go_major < minimum_major || (go_major == minimum_major && go_minor < minimum_minor) || (go_major == minimum_major && go_minor == minimum_minor && go_patch < minimum_patch) )); then
    die "Selected source requires Go >= $minimum_go; found $go_version. Install Go separately; no automatic replacement is performed"
fi
printf 'Verified source: %s @ %s\nToolchain: %s (local only)\n' "$repository" "$actual_commit" "$go_version"

if $download_deps; then
    echo 'Downloading checksum-verified Go modules into the existing module cache (--download-deps).'
    (
        cd -- "$checkout"
        GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 GOSUMDB=sum.golang.org GONOSUMDB='' GOPRIVATE='' \
            go mod download
    )
fi
(
    cd -- "$checkout"
    GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 go mod verify
)
[[ -z "$(git -C "$checkout" status --porcelain --untracked-files=normal)" ]] || die 'Dependency preparation changed the pinned source; review go.mod/go.sum before installation'

bundle="$work_dir/bundle"
bash "$checkout/tools/packaging/build-local-bundle.sh" --source "$checkout" --output "$bundle" --version "$version" --arch "$architecture"
binary_hash=$(sha256sum "$bundle/v2bxss" | cut -d ' ' -f 1)
manifest_hash=$(sha256sum "$bundle/SHA256SUMS" | cut -d ' ' -f 1)
install_args=(--bundle "$bundle" --version "$version" --binary-sha256 "$binary_hash" --manifest-sha256 "$manifest_hash")
if [[ -n "$new_config" ]]; then install_args+=(--config "$new_config"); fi
if $apply; then install_args+=(--apply); fi
if $start_service; then install_args+=(--start); fi
if $explicit_dry_run; then install_args+=(--dry-run); fi
bash "$bundle/install-test-node.sh" "${install_args[@]}"
echo 'A binary replacement takes one explicit service restart. Subsequent supported audit-rule changes sync without restarting this service.'
