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

menu_item() {
    local green='' plain=''
    if [[ -t 1 && ! ${NO_COLOR+x} ]]; then green='\033[0;32m'; plain='\033[0m'; fi
    printf ' %b%s.%b %s\n' "$green" "$1" "$plain" "$2"
}

menu_heading() { printf '\n---------- %s ----------\n' "$1"; }

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
    if { [[ -f "$menu_base/v2bxss" ]] && ! cmp -s "$source" "$menu_base/v2bxss"; } ||
       { [[ -f /usr/local/bin/v2bxss ]] && ! grep -Fxq 'manager=/etc/v2bxss/v2bxss' /usr/local/bin/v2bxss; }; then
        backup="/var/backups/v2bxss/manager-$(date -u +%Y%m%dT%H%M%SZ)-$$"
        for target in /var /var/backups /var/backups/v2bxss "$backup"; do
            [[ ! -L "$target" ]] || die "备份路径不能是符号链接：$target"
        done
        install -d -m 0700 "$backup"
        [[ ! -f "$menu_base/v2bxss" ]] || cp -a "$menu_base/v2bxss" "$backup/v2bxss"
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
    local helper="$(dirname -- "$source")/tools/packaging/configure-node.py"
    if [[ -f "$helper" && ! -L "$helper" ]]; then
        install -d -m 0700 "$menu_base/manager"
        install -m 0600 "$helper" "$menu_base/manager/configure-node.py"
    fi
    # Shadow the original command through PATH, preserving /usr/bin/v2bx and
    # /usr/bin/V2bX. Never overwrite an unrelated /usr/local/bin command.
    if [[ ! -e /usr/local/bin/v2bx && ! -L /usr/local/bin/v2bx ]] ||
       { [[ -f /usr/local/bin/v2bx && ! -L /usr/local/bin/v2bx ]] && grep -Fxq '# V2bXSS menu launcher' /usr/local/bin/v2bx; }; then
        staged=$(mktemp /usr/local/bin/.v2bx.XXXXXXXX)
        install -m 0755 /usr/local/bin/v2bxss "$staged"
        mv -Tf "$staged" /usr/local/bin/v2bx
    else
        echo '保留现有 /usr/local/bin/v2bx；请使用 v2bxss 打开本二开菜单。'
    fi
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
    while true; do
        menu_heading '安装 · 配置方式'
        menu_item 1 '按提示填写面板 / 节点信息（可添加多个节点）'
        menu_item 2 '导入已有 JSON 配置文件'
        menu_item 0 '取消并返回主菜单'
        read -r -p '请选择 [1]：' choice || return 1
        case "${choice:-1}" in
            1) python3 "$menu_source/tools/packaging/configure-node.py" wizard --output "$menu_work/config.json"; return ;;
            2)
                read -r -p '配置文件的绝对路径（0 返回）：' config_path || return 1
                [[ "$config_path" != 0 ]] || continue
                python3 "$menu_source/tools/packaging/configure-node.py" import --input "$config_path" --output "$menu_work/config.json"
                return ;;
            0) echo '已取消安装'; return 1 ;;
            *) echo '请输入 0-2。' ;;
        esac
    done
}

menu_check_install_mode() {
    if [[ "$1" == install ]]; then
        [[ ! -e "$menu_base/current" && ! -L "$menu_base/current" && ! -e /etc/systemd/system/v2bxss.service ]] ||
            die '已经安装二开；更新请选择菜单 2，不重复安装'
        [[ ! -f /etc/v2bx-audit-test/config.json && ! -f /etc/V2bX/config.json ]] ||
            die '检测到旧版/原版节点，请选择菜单 12 迁移，避免重复节点'
    else
        [[ -f "$menu_config" && -x "$menu_base/current/v2bxss" ]] ||
            die '没有找到独立二开安装；新装请选择 1，原版迁移请选择 12'
    fi
}

menu_install_latest() {
    local mode=$1 was_active=false
    menu_check_install_mode "$mode"
    if systemctl is-active --quiet "$service"; then was_active=true; fi
    menu_fetch_source
    local args=() installed_commit=''
    if [[ -f "$menu_config" ]]; then
        echo '已存在配置：将完整保留，包括证书、混淆和多节点设置。'
    else
        menu_new_config
        menu_config_draft "$menu_work/config.json"
        args+=(--config "$menu_draft/config.json")
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
    if [[ "$mode" == install || "$was_active" == true ]]; then args+=(--start); fi
    bash "$menu_source/install.sh" install --source "$menu_source" --commit "$menu_commit" \
        --arch "$menu_arch" --version "audit-${menu_commit:0:12}-$(date -u +%Y%m%d%H%M%S)" \
        --download-deps --apply "${args[@]}"
    menu_save_manager
    if [[ "$mode" == install && -n ${menu_draft:-} ]]; then echo applied > "$menu_draft/state"; fi
    if [[ "$mode" == install ]]; then systemctl enable "$service"; fi
    echo '操作完成。更新保留原运行/开机自启状态；以后输入 v2bxss 打开菜单。'
    echo '后台托管审计规则自动同步，无需每次修改规则后重启节点。'
}

menu_migrate() {
    local answer kind
    if [[ -f /etc/V2bX/config.json && -f /etc/v2bx-audit-test/config.json ]]; then
        die '同时发现两套旧安装，请先审查端口与服务，不自动选择'
    elif [[ -f /etc/V2bX/config.json ]]; then
        kind=upstream
    elif [[ -f /etc/v2bx-audit-test/config.json ]]; then
        kind=independent
    else
        die '没有找到原版 /etc/V2bX 或旧版独立安装'
    fi
    echo '将完整迁移到 /etc/v2bxss，保留原文件和回滚资料。服务切换会短暂中断连接。'
    echo '原版迁移构建最新二开，保留全部节点、证书、混淆、路由及原运行/自启状态。'
    read -r -p '输入 MIGRATE 确认，输入 0 或直接回车取消返回：' answer || { echo '已取消'; return 0; }
    [[ "$answer" == MIGRATE ]] || { echo '已取消'; return 0; }
    menu_fetch_source
    if [[ "$kind" == upstream ]]; then
        bash "$menu_source/tools/packaging/migrate-upstream.sh"
        menu_prepare_go
        export GOMODCACHE="$menu_base/build-cache/modules" GOCACHE="$menu_base/build-cache/go"
        export GOMAXPROCS="${GOMAXPROCS:-2}" GOMEMLIMIT="${GOMEMLIMIT:-384MiB}" GOFLAGS='-p=2'
        (cd "$menu_source"; GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 GOSUMDB=sum.golang.org \
            GONOSUMDB='' GOPRIVATE='' GOPROXY=https://proxy.golang.org,direct go mod download
            GOTOOLCHAIN=local GOEXPERIMENT=jsonv2 GOPROXY=off GOSUMDB=off go mod verify)
        [[ -z "$(git -C "$menu_source" status --porcelain)" ]] || die '依赖改变源码，拒绝继续迁移'
        local bundle="$menu_work/bundle" version="audit-${menu_commit:0:12}-$(date -u +%Y%m%d%H%M%S)"
        bash "$menu_source/tools/packaging/build-local-bundle.sh" --source "$menu_source" --output "$bundle" --version "$version" --arch "$menu_arch"
        bash "$menu_source/tools/packaging/migrate-upstream.sh" --bundle "$bundle" --version "$version" \
            --binary-sha256 "$(sha256sum "$bundle/v2bxss" | cut -d ' ' -f 1)" \
            --manifest-sha256 "$(sha256sum "$bundle/SHA256SUMS" | cut -d ' ' -f 1)" --apply
    else
        bash "$menu_source/tools/packaging/migrate-layout.sh" --apply
    fi
    menu_save_manager
}

menu_config_tool() {
    menu_tool="$menu_base/manager/configure-node.py"
    [[ ! -L "$menu_tool" ]] || die '配置工具不能是符号链接'
    if [[ ! -f "$menu_tool" ]] || ! grep -Fxq 'MENU_CONFIG_VERSION = 2' "$menu_tool"; then
        menu_fetch_source
        install -m 0600 "$menu_source/tools/packaging/configure-node.py" "$menu_tool"
    fi
}

menu_config_draft() {
    local source=$1 target
    for target in "$menu_base/manager/drafts"; do
        [[ ! -L "$target" ]] || die '草稿目录不能是符号链接'
    done
    install -d -m 0700 "$menu_base/manager/drafts"
    menu_draft=$(mktemp -d "$menu_base/manager/drafts/config-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
    if [[ -f "$menu_config" ]]; then install -m 0600 "$menu_config" "$menu_draft/previous.json"; fi
    install -m 0600 "$source" "$menu_draft/config.json"
    if systemctl is-active --quiet "$service"; then echo true > "$menu_draft/was-active"; else echo false > "$menu_draft/was-active"; fi
    echo staged > "$menu_draft/state"
    printf '已保留本次配置：%s/config.json\n' "$menu_draft"
    [[ ! -f "$menu_draft/previous.json" ]] || printf '修改前配置：%s/previous.json\n' "$menu_draft"
}

menu_edit_config() {
    local file=$1 editor
    # Do not evaluate shell text from EDITOR or expose a config in terminal logs.
    for editor in "${VISUAL:-${EDITOR:-}}" nano vi; do
        [[ -n "$editor" ]] || continue
        if command -v "$editor" >/dev/null; then "$editor" "$file"; return; fi
    done
    echo "没有找到编辑器。请安装 nano/vi 或直接编辑：$file" >&2
    return 1
}

menu_try_config() {
    local draft=$1
    # Syntax/field errors stay in the editable draft, never replace the live file.
    if ! python3 "$menu_tool" validate --input "$draft/config.json"; then
        echo failed > "$draft/state"
        echo '配置检查失败，草稿完整保留；修正后可重试。'
        return 1
    fi
    install -m 0600 "$draft/config.json" "${menu_config}.next" || return 1
    mv -Tf "${menu_config}.next" "$menu_config" || return 1
    echo failed > "$draft/state"
    if ! systemctl restart "$service" || ! menu_stable_service; then
        echo '新配置启动失败；已保留当前新配置，没有自动覆盖回旧配置。'
        echo '该服务可能不可用；可在下面修改重试，或主动恢复修改前配置。'
        return 1
    fi
    echo applied > "$draft/state"
    echo '配置已应用，服务启动稳定。请在后台确认节点回执和用户/流量上报。'
}

menu_config_recovery() {
    local draft=$1 choice answer target
    for target in "$draft" "$draft/config.json" "$draft/previous.json" "$draft/state" "$draft/was-active"; do
        [[ ! -L "$target" ]] || die '草稿或恢复文件不能是符号链接'
    done
    [[ -f "$draft/config.json" ]] || die '配置草稿不存在'
    while true; do
        menu_heading '配置修正 · 保留本次输入'
        printf '草稿：%s/config.json\n' "$draft"
        menu_item 1 '修改此配置（编辑器打开，密钥不输出到日志）'
        menu_item 2 '应用此配置并重试启动'
        menu_item 3 '查看最近运行错误日志'
        menu_item 4 '恢复修改前配置和原运行状态（需确认）'
        menu_item 0 '保留本次配置，返回主菜单'
        read -r -p '请选择 [0-4]：' choice || return 0
        case "$choice" in
            1) menu_edit_config "$draft/config.json" || echo '编辑未完成；文件仍保留。' ;;
            2) if menu_try_config "$draft"; then return 0; fi ;;
            3) show_logs "$service" 80 false || echo '日志查询失败。' ;;
            4)
                [[ -f "$draft/previous.json" ]] || { echo '首次配置没有旧文件可恢复。'; continue; }
                read -r -p '输入 y 恢复修改前配置；0 或回车取消：' answer || return 0
                [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消恢复'; continue; }
                install -m 0600 "$draft/previous.json" "${menu_config}.next"
                mv -Tf "${menu_config}.next" "$menu_config"
                if [[ -f "$draft/was-active" && $(<"$draft/was-active") == true ]]; then
                    if ! systemctl restart "$service" || ! menu_stable_service; then echo '旧配置也未启动成功，请检查日志。'; continue; fi
                else
                    systemctl stop "$service"
                fi
                echo restored > "$draft/state"
                echo '已主动恢复修改前配置；本次新配置仍保留在草稿中。'
                return 0 ;;
            0) echo '已保留本次配置；主菜单 3 → 3 可以继续修正。'; return 0 ;;
            *) echo '请输入 0-4。' ;;
        esac
    done
}

menu_resume_config() {
    local draft choice count=0
    local drafts=()
    menu_heading '选择待修正配置'
    for draft in "$menu_base"/manager/drafts/config-*; do
        [[ -d "$draft" && ! -L "$draft" && -f "$draft/state" && ! -L "$draft/state" ]] || continue
        [[ $(<"$draft/state") == failed || $(<"$draft/state") == staged ]] || continue
        drafts+=("$draft"); count=$((count + 1))
        menu_item "$count" "$(basename "$draft")（$(<"$draft/state")）"
    done
    ((count > 0)) || { echo '没有待修正草稿。'; return 0; }
    menu_item 0 '返回配置菜单'
    read -r -p '请选择草稿序号：' choice || return 0
    [[ "$choice" != 0 ]] || return 0
    [[ "$choice" =~ ^[1-9][0-9]{0,5}$ ]] && ((10#$choice <= count)) || { echo '无效选择'; return 1; }
    menu_config_recovery "${drafts[$((10#$choice - 1))]}"
}

menu_configure() {
    local choice import_path answer
    menu_config_tool
    if [[ "$1" == 3 ]]; then
        while true; do
            menu_heading '配置管理'
            menu_item 1 '修改当前配置（保留原文件备份）'
            menu_item 2 '导入 / 替换配置（保留原文件备份）'
            menu_item 3 '继续修正失败 / 待应用配置'
            menu_item 0 '返回主菜单'
            read -r -p '请选择 [0-3]：' choice || return 0
            case "$choice" in
                0) return 0 ;;
                3) menu_resume_config; continue ;;
                1|2) break ;;
                *) echo '请输入 0-3。' ;;
            esac
        done
    else
        choice=11
    fi
    [[ -f "$menu_config" ]] || die '请先选择 1 完成安装；已有草稿可用配置菜单 3 继续修正'
    case "$choice" in
        11)
            menu_config_draft "$menu_config"
            python3 "$menu_tool" wizard --existing "$menu_config" --output "$menu_draft/append.json"
            mv -Tf "$menu_draft/append.json" "$menu_draft/config.json" ;;
        1)
            menu_config_draft "$menu_config"
            menu_edit_config "$menu_draft/config.json" ;;
        2)
            read -r -p '导入配置的绝对路径（0 返回）：' import_path || return 0
            [[ "$import_path" != 0 ]] || return 0
            read -r -p '将替换当前配置（先备份），确认？[y/N]：' answer || return 0
            [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消'; return 0; }
            menu_config_draft "$import_path" ;;
    esac
    if ! menu_try_config "$menu_draft"; then menu_config_recovery "$menu_draft"; fi
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
    echo '回滚将恢复上一版程序及该备份中的配置，并重启服务。'
    read -r -p '第一次确认 [y/N]（0 取消返回）：' answer || { echo '已取消'; return 0; }
    [[ "$answer" == y || "$answer" == Y ]] || { echo '已取消'; return 0; }
    read -r -p '第二次确认：输入 ROLLBACK 执行；0 或回车取消返回：' answer || { echo '已取消'; return 0; }
    [[ "$answer" == ROLLBACK ]] || { echo '已取消'; return 0; }
    bash "$selected/rollback-test-node.sh" --backup "$selected" --apply --start
}

# Recoverable removal of this independent layout only. No download or compiler.
uninstall_fork() (
    local apply_uninstall=$1 answer unit=/etc/systemd/system/v2bxss.service
    local launcher=/usr/local/bin/v2bxss backup='' active=false enabled=false
    local base_moved=false unit_moved=false launcher_moved=false alias_moved=false changing=false
    local alias_path=/usr/local/bin/v2bx alias_owned=false
    local fragment='' dropins='' effective='' target
    printf '卸载范围：仅 %s、/etc/v2bxss 和 /usr/local/bin/v2bxss。\n' "$service"
    echo '同时移走属于本二开的 /usr/local/bin/v2bx 快捷入口；上游 /usr/bin 入口保留。'
    echo '将中断该二开节点连接；原版 V2bX、面板、其他服务、防火墙和外部证书不变。'
    echo '配置、证书、程序、构建缓存会移入 /var/backups/v2bxss/uninstall-*，不永久删除。'
    echo '卸载前请确认节点流量已成功上报；不能保证进程内待报增量零损失。'
    if [[ "$apply_uninstall" != true ]]; then
        echo 'DRY RUN：未修改文件或服务。执行卸载：v2bxss uninstall --apply（仍需确认）。'
        return 0
    fi
    manager_require_target
    if [[ -f "$alias_path" && ! -L "$alias_path" ]] && grep -Fxq '# V2bXSS menu launcher' "$alias_path"; then alias_owned=true; fi
    for target in systemctl install mktemp mv cp cmp stat realpath flock grep; do need_command "$target"; done
    [[ -d /run/systemd/system ]] || die '需要使用 systemd 的 Linux 服务器'
    [[ -d "$menu_base" && -f "$menu_base/v2bxss" ]] || die '没有找到此二开的独立安装；不处理原版或旧目录'
    for target in /etc/systemd /etc/systemd/system "$unit" "$unit.d" /var /var/backups /var/backups/v2bxss \
                  "$menu_base/layout.lock" "$menu_base/manager/operation.lock"; do
        [[ ! -L "$target" ]] || die "卸载路径不能是符号链接：$target"
    done
    [[ ! -e "$unit.d" ]] || die '检测到自定义服务 drop-in；请先人工审查，不自动卸载'
    fragment=$(systemctl show "$service" --property=FragmentPath --value 2>/dev/null || true)
    if [[ -f "$unit" ]]; then
        [[ "$fragment" == "$unit" ]] || die '有效服务路径不是本二开的标准 unit'
        dropins=$(systemctl show "$service" --property=DropInPaths --value)
        [[ -z "$dropins" ]] || die '检测到自定义服务 drop-in；请先人工审查'
        effective=$(systemctl show "$service" --property=ExecStart --value)
        [[ "$effective" == *"path=$menu_base/current/v2bxss "* ]] || die '有效服务指向其他程序，拒绝卸载'
        if systemctl is-active --quiet "$service"; then active=true; fi
        if systemctl is-enabled --quiet "$service"; then enabled=true; fi
    else
        [[ -z "$fragment" ]] || die '检测到其他位置的同名服务，拒绝卸载'
    fi
    read -r -p '输入 UNINSTALL 确认卸载（其他输入取消）：' answer || { echo '已取消卸载'; return 0; }
    [[ "$answer" == UNINSTALL ]] || { echo '已取消卸载'; return 0; }
    install -d -m 0700 "$menu_base/manager" /var/backups/v2bxss
    exec 9>"$menu_base/manager/operation.lock"
    flock -n 9 || die '另一个安装/配置操作正在进行，未卸载'
    exec 8>"$menu_base/layout.lock"
    flock -n 8 || die '另一个迁移/回滚操作正在进行，未卸载'
    # Atomic rename: never partially copy/remove a large installation.
    [[ $(stat -c %d "$menu_base") == $(stat -c %d /var/backups/v2bxss) ]] ||
        die '安装和备份目录不在同一文件系统，无法原子保留全部文件；未停止服务'
    backup=$(mktemp -d "/var/backups/v2bxss/uninstall-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXXXX")
    install -m 0700 "${BASH_SOURCE[0]}" "$backup/manager.sh"
    printf '%s\n' "$active" > "$backup/was-active"
    printf '%s\n' "$enabled" > "$backup/was-enabled"
    cat > "$backup/restore.sh" <<'RESTORE'
#!/usr/bin/env bash
set -euo pipefail
umask 077
backup=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
base=/etc/v2bxss
unit=/etc/systemd/system/v2bxss.service
launcher=/usr/local/bin/v2bxss
alias_path=/usr/local/bin/v2bx
service=v2bxss.service
fail() { printf '恢复失败：%s\n' "$*" >&2; exit 1; }
[[ $# == 1 && $1 == --apply ]] || { echo '恢复将移动备份回标准目录并还原服务状态；加 --apply 后仍需输入 RESTORE 确认。'; exit 0; }
[[ $(id -u) == 0 && $(uname -s) == Linux ]] || fail '需要 Linux root'
[[ $(dirname -- "$backup") == /var/backups/v2bxss && $(basename -- "$backup") == uninstall-* ]] || fail '非标准卸载备份'
for target in /etc /etc/systemd /etc/systemd/system /usr /usr/local /usr/local/bin /var /var/backups /var/backups/v2bxss "$backup" \
              "$backup/installation" "$backup/was-active" "$backup/was-enabled" "$backup/complete" "$backup/unit" "$backup/launcher" "$backup/alias"; do
    [[ ! -L "$target" ]] || fail "拒绝符号链接路径：$target"
done
if [[ -f "$backup/alias" ]]; then
    [[ ! -e "$alias_path" && ! -L "$alias_path" ]] || fail 'v2bx 入口已被其他程序使用，拒绝覆盖'
fi
[[ -d "$backup/installation" && -f "$backup/complete" ]] || fail '备份不完整或已经恢复'
[[ $(<"$backup/was-active") =~ ^(true|false)$ && $(<"$backup/was-enabled") =~ ^(true|false)$ ]] || fail '原服务状态无效'
for target in "$base" "$unit" "$unit.d" "$launcher"; do
    [[ ! -e "$target" && ! -L "$target" ]] || fail "目标已存在，拒绝覆盖：$target"
done
[[ -z $(systemctl show "$service" --property=FragmentPath --value 2>/dev/null || true) ]] || fail '已经存在同名服务'
[[ $(stat -c %d "$backup/installation") == $(stat -c %d /etc) ]] || fail '无法原子恢复到另一文件系统'
read -r -p '输入 RESTORE 确认恢复此二开及原运行状态：' answer || exit 0
[[ "$answer" == RESTORE ]] || { echo '已取消恢复'; exit 0; }
exec 9>"$backup/restore.lock"
flock -n 9 || fail '另一个恢复正在进行'
moved=false; unit_written=false; launcher_written=false; alias_written=false; success=false
recover() {
    result=$?
    trap - EXIT
    if [[ "$success" != true ]]; then
        echo '恢复未完成，正在退回卸载状态；所有文件仍保留。' >&2
        systemctl stop "$service" 2>/dev/null || true
        systemctl disable "$service" 2>/dev/null || true
        if $launcher_written; then mv -T -- "$launcher" "$backup/restore-failed-launcher-$$" || true; fi
        if $alias_written; then mv -T -- "$alias_path" "$backup/restore-failed-alias-$$" || true; fi
        if $unit_written; then mv -T -- "$unit" "$backup/restore-failed-unit-$$" || true; fi
        if $moved; then mv -T -- "$base" "$backup/installation" || true; fi
        systemctl daemon-reload || true
    fi
    exit "$result"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
mv -T -- "$backup/installation" "$base"; moved=true
if [[ -f "$backup/unit" ]]; then install -m 0644 "$backup/unit" "$unit"; unit_written=true; fi
if [[ -f "$backup/launcher" ]]; then install -m 0755 "$backup/launcher" "$launcher"; launcher_written=true; fi
if [[ -f "$backup/alias" ]]; then install -m 0755 "$backup/alias" "$alias_path"; alias_written=true; fi
systemctl daemon-reload
if [[ $(<"$backup/was-enabled") == true ]]; then systemctl enable "$service"; fi
if [[ $(<"$backup/was-active") == true ]]; then
    systemctl start "$service"
    systemctl is-active --quiet "$service" || fail '服务未启动'
fi
success=true
echo '已恢复原目录和服务状态；备份资料仍保留。'
RESTORE
    chmod 0700 "$backup/restore.sh"
    printf '卸载备份：%s\n恢复命令：bash %q --apply\n' "$backup" "$backup/restore.sh"
    recover_uninstall() {
        local result=$?
        trap - EXIT
        if $changing; then
            echo '卸载未完成，正在恢复原文件及服务状态。' >&2
            if $base_moved; then mv -T -- "$backup/installation" "$menu_base" || true; fi
            if $unit_moved; then mv -T -- "$backup/unit" "$unit" || true; fi
            if $launcher_moved; then mv -T -- "$backup/launcher" "$launcher" || true; fi
            if $alias_moved; then mv -T -- "$backup/alias" "$alias_path" || true; fi
            systemctl daemon-reload || true
            if $enabled; then systemctl enable "$service" || true; fi
            if $active; then systemctl start "$service" || true; fi
            echo "若自动恢复失败，请检查保留的卸载备份：$backup" >&2
        fi
        exit "$result"
    }
    trap recover_uninstall EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    changing=true
    if [[ -f "$unit" ]]; then
        systemctl stop "$service"
        if systemctl is-active --quiet "$service"; then die '服务仍在运行，取消卸载'; fi
        systemctl disable "$service"
        mv -T -- "$unit" "$backup/unit"; unit_moved=true
    fi
    if [[ -f "$launcher" ]]; then mv -T -- "$launcher" "$backup/launcher"; launcher_moved=true; fi
    if $alias_owned; then mv -T -- "$alias_path" "$backup/alias"; alias_moved=true; fi
    mv -T -- "$menu_base" "$backup/installation"; base_moved=true
    systemctl daemon-reload
    systemctl reset-failed "$service" 2>/dev/null || true
    printf 'complete\n' > "$backup/complete"
    changing=false
    echo 'V2bXSS 已卸载；完整文件已保留在上述备份目录，未卸载原版或其他程序。'
)

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
        8) show_logs "$service" 100 true; return ;;
        13) uninstall_fork true; return ;;
    esac
    menu_require_host
    case "$1" in
        1) menu_check_install_mode install; menu_dependencies ;;
        2) menu_check_install_mode update; menu_dependencies ;;
        3|11|12) menu_dependencies ;;
    esac
    case "$1" in
        1) menu_install_latest install ;;
        2) menu_install_latest update ;;
        3|11) menu_configure "$1" ;;
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
    local choice pause state autostart
    # Ctrl+C during the live viewer ends journalctl and returns to this menu.
    # The viewer runs in its own shell and installs its own INT handler.
    trap ':' INT
    while true; do
        printf '\n========== V2bXSS 二开管理菜单 ==========\n'
        printf '仓库：xcxcadc/V2bXSS · dev_new\n'
        printf '%s\n' '----------------------------------------'
        menu_item 1 '安装最新二开版本'
        menu_item 2 '更新到最新二开版本（保留配置）'
        menu_item 3 '配置管理 / 导入 / 修正失败配置'
        printf '%s\n' '----------------------------------------'
        menu_item 4 '启动服务'
        menu_item 5 '停止服务'
        menu_item 6 '重启服务'
        menu_item 7 '查看运行状态'
        menu_item 8 '查看实时运行 / 连接日志（Ctrl+C 返回）'
        menu_item 9 '开启 / 关闭开机自启'
        printf '%s\n' '----------------------------------------'
        menu_item 10 '回滚上一版本（二次确认，0 取消）'
        menu_item 11 '添加对接节点（保留已有节点）'
        menu_item 12 '迁移原版 / 旧版独立安装到 /etc/v2bxss'
        menu_item 13 '卸载 V2bXSS（确认后执行，保留完整备份）'
        menu_item 0 '退出'
        printf '管理服务：%s\n' "$service"
        if [[ -t 0 && -t 1 ]] && command -v systemctl >/dev/null; then
            state=$(systemctl is-active "$service" 2>/dev/null || true)
            autostart=$(systemctl is-enabled "$service" 2>/dev/null || true)
            printf '运行状态：%s ｜ 开机自启：%s\n' "${state:-未安装}" "${autostart:-未设置}"
        fi
        read -r -p '请选择 [0-13]：' choice || return 0
        case "$choice" in
            0) return 0 ;;
            [1-9]|10|11|12|13)
                # A separate shell preserves errexit inside every action even
                # when the menu catches its exit code to stay open on failure.
                bash "${BASH_SOURCE[0]}" __menu_action "$choice" || echo '操作未完成；请查看上方错误。菜单仍可继续使用。'
                if [[ "$choice" == 13 && ! -e /etc/v2bxss/v2bxss && ! -e /usr/local/bin/v2bxss ]]; then return 0; fi
                if [[ -t 0 ]]; then read -r -p '按回车返回主菜单：' pause || return 0; fi
                ;;
            *) echo '请输入 0-13。' ;;
        esac
    done
}

usage() {
    cat <<'USAGE'
Build this V2bXSS fork and manage the independent v2bxss.service.

Interactive (recommended): bash install.sh
Reopen after installation: v2bx (or v2bxss)
Repair only the menu/shortcut, with no build, network or service restart:
  bash install.sh repair
All new fork files use /etc/v2bxss; the node executable is current/v2bxss.
Menu: 1 install, 2 update, 3 config/edit/import/recover, 8 live logs, 10 rollback (two confirmations),
11 append node, 12 migrate upstream/old independent layout, 13 uninstall.
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
  bash install.sh uninstall [--apply | --dry-run]
Uninstall/menu option 13 requires typing UNINSTALL, then stops/disables only
v2bxss.service and moves its files into /var/backups/v2bxss/uninstall-*.
Configuration/certificates/binaries are retained, not permanently erased.
The printed restore.sh command restores the old files and service state after
typing RESTORE; it refuses to overwrite a later installation.
Installed shortcut: v2bxss logs -f (menu option 8). Ctrl+C stops viewing only.
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
    echo '管理入口已修复：v2bx / v2bxss；脚本：/etc/v2bxss/v2bxss。未重启或修改节点配置。'
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
    install|status|logs|start|restart|stop|uninstall) ;;
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
        uninstall) uninstall_fork "$apply" ;;
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
