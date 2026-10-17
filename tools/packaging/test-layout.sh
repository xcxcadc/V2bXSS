#!/usr/bin/env bash
# Never run against host /etc. The caller must supply a private mount namespace
# masking all four roots below with tmpfs. No network or compiler is used.
set -euo pipefail
for path in /etc /opt /var/backups /usr/local/bin; do
    [[ $(findmnt -n -o FSTYPE --mountpoint "$path") == tmpfs ]] || {
        echo 'Run only in a disposable mount namespace with four tmpfs roots.' >&2; exit 2;
    }
done
scenario=${1:?scenario required}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d "${TMPDIR:-/tmp}/v2bxss-layout-check.XXXXXXXX")
mkdir -p "$fixture/bin" "$fixture/source/tools/packaging" /etc/systemd/system
export LAYOUT_FIXTURE=$fixture
cp "$script_dir/../../install.sh" "$fixture/source/install.sh"
cp "$script_dir/"{install-test-node.sh,rollback-test-node.sh,v2bxss.service} "$fixture/source/tools/packaging/"
sed "s|^proc_root=/proc$|proc_root=$fixture/proc|" "$script_dir/migrate-layout.sh" > "$fixture/source/tools/packaging/migrate-layout.sh"
cat > "$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >> "$LAYOUT_FIXTURE/calls"
action=$1; shift
service=''
for arg in "$@"; do
    case "$arg" in V2bX-audit-test.service) service=old ;; v2bxss.service) service=new ;; esac
done
case "$action" in
    daemon-reload) exit 0 ;;
    show)
        case "$*" in
            *DropInPaths*) : ;;
            *ExecStart*) echo '{ path=/opt/v2bx-audit-test/current/V2bX ; argv[]=V2bX server ; }' ;;
            *MainPID*) echo 123 ;;
        esac ;;
    is-active)
        state=inactive
        [[ ! -f "$LAYOUT_FIXTURE/$service-active" ]] || state=$(<"$LAYOUT_FIXTURE/$service-active")
        [[ "$*" == *--quiet* ]] || echo "$state"
        [[ "$state" == active ]] ;;
    is-enabled) [[ -f "$LAYOUT_FIXTURE/$service-enabled" ]] && grep -Fxq true "$LAYOUT_FIXTURE/$service-enabled" ;;
    start|restart)
        if [[ "$service" == new && ${LAYOUT_FAIL_NEW:-0} == 1 ]]; then exit 42; fi
        echo active > "$LAYOUT_FIXTURE/$service-active" ;;
    stop) echo inactive > "$LAYOUT_FIXTURE/$service-active" ;;
    enable) echo true > "$LAYOUT_FIXTURE/$service-enabled" ;;
    disable) echo false > "$LAYOUT_FIXTURE/$service-enabled" ;;
    *) echo 'Unexpected fixture service call' >&2; exit 91 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/sleep"
chmod 0755 "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
entry="$fixture/source/install.sh"
migrator="$fixture/source/tools/packaging/migrate-layout.sh"
make_bundle() {
    bundle="$fixture/bundle-$1"
    mkdir "$bundle"
    printf '#!/usr/bin/env bash\necho fixture-%s\n' "$1" > "$bundle/v2bxss"
    chmod 0755 "$bundle/v2bxss"
    printf 'version=%s\ngoos=linux\ngoarch=amd64\n' "$1" > "$bundle/BUILD-INFO"
    cp "$entry" "$bundle/v2bxss-manager"
    cp "$script_dir/"{install-test-node.sh,rollback-test-node.sh,v2bxss.service} "$bundle/"
    (cd "$bundle"; sha256sum --binary v2bxss BUILD-INFO install-test-node.sh rollback-test-node.sh v2bxss.service v2bxss-manager > SHA256SUMS)
    binary_hash=$(sha256sum "$bundle/v2bxss" | awk '{print $1}')
    manifest_hash=$(sha256sum "$bundle/SHA256SUMS" | awk '{print $1}')
}
apply_bundle() {
    bash "$bundle/install-test-node.sh" --bundle "$bundle" --version "$1" \
        --binary-sha256 "$binary_hash" --manifest-sha256 "$manifest_hash" --apply "${@:2}"
}
if [[ "$scenario" == repair || "$scenario" == fresh || "$scenario" == install-failed-start ]]; then
    bash "$entry" repair
    printf '0\n' | v2bxss > "$fixture/menu.log"
    grep -Fq 'V2bXSS 二开管理菜单' "$fixture/menu.log"
    grep -Fq '/etc/v2bxss/v2bxss' /usr/local/bin/v2bxss
    [[ ! -e "$fixture/calls" ]]
    mv /etc/v2bxss/v2bxss "$fixture/saved-manager"
    if v2bxss > "$fixture/missing.log" 2>&1; then exit 1; fi
    grep -Fq 'bash install.sh repair' "$fixture/missing.log"
    bash "$entry" repair
    printf '0\n' | v2bxss > /dev/null
    [[ ! -e "$fixture/calls" ]]
    if [[ "$scenario" != repair ]]; then
        printf '{"fixture":"preserve"}\n' > "$fixture/config.json"
        make_bundle fixture-1
        apply_bundle fixture-1 --config "$fixture/config.json" > "$fixture/install.log"
        [[ -x /etc/v2bxss/current/v2bxss && -f /etc/v2bxss/v2bxss ]]
        cmp "$fixture/config.json" /etc/v2bxss/config.json
        grep -Fq '/etc/v2bxss/current/v2bxss' /etc/systemd/system/v2bxss.service
        ! grep -Eq '^(start|restart) ' "$fixture/calls"
        if [[ "$scenario" == install-failed-start ]]; then
            previous=$(realpath -e /etc/v2bxss/current)
            make_bundle fixture-2
            if LAYOUT_FAIL_NEW=1 apply_bundle fixture-2 --start > "$fixture/failed.log" 2>&1; then exit 1; fi
            [[ $(realpath -e /etc/v2bxss/current) == "$previous" ]]
            cmp "$fixture/config.json" /etc/v2bxss/config.json
            printf '0\n' | v2bxss > /dev/null
        fi
    fi
else
    mkdir -p /etc/v2bx-audit-test /opt/v2bx-audit-test/releases/old
    printf '#!/usr/bin/env bash\necho old-fixture\n' > /opt/v2bx-audit-test/releases/old/V2bX
    chmod 0755 /opt/v2bx-audit-test/releases/old/V2bX
    ln -s /opt/v2bx-audit-test/releases/old /opt/v2bx-audit-test/current
    sed -e 's#/etc/v2bxss/current/v2bxss#/opt/v2bx-audit-test/current/V2bX#g' \
        -e 's#/etc/v2bxss#/etc/v2bx-audit-test#g' "$script_dir/v2bxss.service" > /etc/systemd/system/V2bX-audit-test.service
    printf '{ // preserve JSON5\n"tls":"/etc/v2bx-audit-test/tls.crt","extra":"unchanged"}\n' > /etc/v2bx-audit-test/config.json
    printf 'fixture-cert\n' > /etc/v2bx-audit-test/tls.crt
    sha256sum /etc/v2bx-audit-test/* > "$fixture/old-config.sha"
    echo active > "$fixture/old-active"
    echo true > "$fixture/old-enabled"
    if [[ "$scenario" == missing-binary ]]; then
        mkdir -p "$fixture/proc/123"
        mv /opt/v2bx-audit-test/releases/old/V2bX "$fixture/proc/123/exe"
        # Model the reported missing /opt installation without deleting data.
        mv /opt/v2bx-audit-test/current "$fixture/old-current"
    fi
    if [[ "$scenario" == stopped ]]; then echo inactive > "$fixture/old-active"; echo false > "$fixture/old-enabled"; fi
    if [[ "$scenario" == custom-unit ]]; then
        printf '\nEnvironment=FIXTURE_CUSTOM=true\n' >> /etc/systemd/system/V2bX-audit-test.service
        if bash "$migrator" --apply > "$fixture/migrate.log" 2>&1; then exit 1; fi
        grep -Fq '旧服务含自定义参数' "$fixture/migrate.log"
        ! grep -Eq '^(start|stop|restart|disable|enable) ' "$fixture/calls"
        [[ ! -e /etc/v2bxss/config.json ]]
    elif [[ "$scenario" == failed-switch ]]; then
        if LAYOUT_FAIL_NEW=1 bash "$migrator" --apply > "$fixture/migrate.log" 2>&1; then exit 1; fi
        grep -Fxq active "$fixture/old-active"
        grep -Fxq inactive "$fixture/new-active"
    else
        bash "$migrator" --apply > "$fixture/migrate.log"
        [[ -x /etc/v2bxss/current/v2bxss ]]
        cmp /etc/v2bx-audit-test/tls.crt /etc/v2bxss/tls.crt
        grep -Fq '/etc/v2bxss/tls.crt' /etc/v2bxss/config.json
        grep -Fq '"extra":"unchanged"' /etc/v2bxss/config.json
        printf '0\n' | v2bxss > /dev/null
        if [[ "$scenario" == stopped ]]; then
            ! grep -Eq '^(start|stop|restart) ' "$fixture/calls"
            grep -Fxq false "$fixture/old-enabled"
        else
            grep -Fxq inactive "$fixture/old-active"
            grep -Fxq active "$fixture/new-active"
            backup=$(sed -n 's/^迁移备份：//p' "$fixture/migrate.log")
            bash "$backup/rollback-layout.sh" --rollback "$backup" --apply > "$fixture/rollback.log"
            grep -Fxq active "$fixture/old-active"
            grep -Fxq inactive "$fixture/new-active"
        fi
    fi
    sha256sum --check "$fixture/old-config.sha" >/dev/null
fi
echo "PASS: layout scenario $scenario (service and binary fixtures, no live node changed)"
