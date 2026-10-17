#!/usr/bin/env bash
# Fixture services/binaries, real copy/install/rollback in a private namespace.
set -euo pipefail
for root in /etc /usr/local /var/backups; do
    [[ $(findmnt -n -o FSTYPE --mountpoint "$root") == tmpfs ]] || {
        echo 'Use a disposable mount namespace masking /etc /usr/local /var/backups.' >&2; exit 2;
    }
done
scenario=${1:?scenario required}
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
fixture=$(mktemp -d /tmp/v2bxss-upstream-check.XXXXXXXX)
export MIGRATE_FIXTURE=$fixture
mkdir -p "$fixture/bin" /etc/V2bX/nodes /etc/systemd/system /usr/local/V2bX /usr/local/bin /etc/ssl/fixture
cat > /etc/systemd/system/V2bX.service <<'UNIT'
[Unit]
Description=V2bX Service
After=network.target nss-lookup.target
Wants=network.target

[Service]
User=root
Group=root
Type=simple
LimitAS=infinity
LimitRSS=infinity
LimitCORE=infinity
LimitNOFILE=999999
WorkingDirectory=/usr/local/V2bX/
ExecStart=/usr/local/V2bX/V2bX server
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
cat > "$fixture/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MIGRATE_FIXTURE/calls"
action=$1; shift
service=new
for arg in "$@"; do [[ "$arg" != V2bX.service ]] || service=old; done
case "$action" in
    daemon-reload) : ;;
    show)
        case "$*" in
            *FragmentPath*) echo /etc/systemd/system/V2bX.service ;;
            *DropInPaths*) [[ ${MIGRATE_DROPIN:-0} != 1 ]] || echo override.conf ;;
            *ExecStart*) echo '{ path=/usr/local/V2bX/V2bX ; argv[]=/usr/local/V2bX/V2bX server ; }' ;;
            *MainPID*) echo 456 ;;
        esac ;;
    is-active)
        value=inactive
        [[ ! -f "$MIGRATE_FIXTURE/$service-active" ]] || value=$(<"$MIGRATE_FIXTURE/$service-active")
        [[ "$*" == *--quiet* ]] || echo "$value"
        [[ "$value" == active ]] ;;
    is-enabled) [[ -f "$MIGRATE_FIXTURE/$service-enabled" ]] && grep -Fxq true "$MIGRATE_FIXTURE/$service-enabled" ;;
    start|restart)
        [[ "$service" != new || ${MIGRATE_FAIL_NEW:-0} != 1 ]] || exit 42
        echo active > "$MIGRATE_FIXTURE/$service-active" ;;
    stop) echo inactive > "$MIGRATE_FIXTURE/$service-active" ;;
    enable) echo true > "$MIGRATE_FIXTURE/$service-enabled" ;;
    disable) echo false > "$MIGRATE_FIXTURE/$service-enabled" ;;
    *) exit 90 ;;
esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$fixture/bin/sleep"
chmod 0755 "$fixture/bin/"*
export PATH="$fixture/bin:$PATH"
printf '#!/usr/bin/env bash\necho original-fixture\n' > /usr/local/V2bX/V2bX
chmod 0755 /usr/local/V2bX/V2bX
printf 'geo fixture\n' > /usr/local/V2bX/geosite.dat
printf 'external certificate fixture\n' > /etc/ssl/fixture/cert.pem
ln -s /etc/ssl/fixture/cert.pem /etc/V2bX/external-cert.pem
ln -s /etc/V2bX/nodes /etc/V2bX/linked-nodes
cat > /etc/V2bX/config.json <<'CONFIG'
{ // Preserve comments, unknown options, Includes and both old path forms.
  "Cores": [{"Type":"xray"},{"Type":"sing"},{"Type":"hysteria2"}],
  "Nodes": [
CONFIG
for protocol in vmess vless trojan shadowsocks hysteria hysteria2 tuic anytls; do
    printf '    {"Include":"/etc/V2bX/nodes/%s.json5"},\n' "$protocol" >> /etc/V2bX/config.json
done
cat >> /etc/V2bX/config.json <<'CONFIG'
    {"Include":"relative.json"}],
  "UnknownOption": {"tls":"/etc/V2bX/tls.crt","geo":"/usr/local/V2bX/geosite.dat"}
}
CONFIG
printf 'TLS fixture\n' > /etc/V2bX/tls.crt
printf '{"NodeType":"vmess","NodeID":90,"UnknownOption":"keep"}\n' > /usr/local/V2bX/relative.json
for protocol in vmess vless trojan shadowsocks hysteria hysteria2 tuic anytls; do
    printf '{"NodeType":"%s","NodeID":%s,"ObfsPassword":"fixture-only","UnknownFlag":true}\n' "$protocol" 9 > "/etc/V2bX/nodes/$protocol.json5"
done
find /etc/V2bX /usr/local/V2bX -type f -print0 | sort -z | xargs -0 sha256sum > "$fixture/original.sha"
echo active > "$fixture/old-active"; echo true > "$fixture/old-enabled"
if [[ "$scenario" == stopped ]]; then echo inactive > "$fixture/old-active"; echo false > "$fixture/old-enabled"; fi
bundle="$fixture/bundle"
mkdir "$bundle"
printf '#!/usr/bin/env bash\necho fork-fixture\n' > "$bundle/v2bxss"
chmod 0755 "$bundle/v2bxss"
printf 'version=fixture-1\ngoos=linux\ngoarch=amd64\n' > "$bundle/BUILD-INFO"
cp "$script_dir/"{install-test-node.sh,rollback-test-node.sh,v2bxss.service} "$bundle/"
cp "$script_dir/../../install.sh" "$bundle/v2bxss-manager"
(cd "$bundle"; sha256sum --binary v2bxss BUILD-INFO install-test-node.sh rollback-test-node.sh v2bxss.service v2bxss-manager > SHA256SUMS)
binary_hash=$(sha256sum "$bundle/v2bxss" | cut -d ' ' -f 1)
manifest_hash=$(sha256sum "$bundle/SHA256SUMS" | cut -d ' ' -f 1)
run_migration() {
    bash "$script_dir/migrate-upstream.sh" --bundle "$bundle" --version fixture-1 \
        --binary-sha256 "$binary_hash" --manifest-sha256 "$manifest_hash" "$@"
}
case "$scenario" in
    custom-unit) echo 'Environment=UNREVIEWED=true' >> /etc/systemd/system/V2bX.service ;;
    dropin) export MIGRATE_DROPIN=1 ;;
    occupied) mkdir -p /etc/v2bxss; echo '{}' > /etc/v2bxss/config.json ;;
    wrong-hash) binary_hash=$(printf '%064d' 0) ;;
    failed-start) export MIGRATE_FAIL_NEW=1 ;;
esac
case "$scenario" in
    custom-unit|dropin|occupied|wrong-hash)
        if run_migration --apply > "$fixture/result.log" 2>&1; then exit 1; fi
        ! grep -Eq '^(stop|start|restart|disable|enable) ' "$fixture/calls" 2>/dev/null
        ;;
    dry-run)
        run_migration > "$fixture/result.log"
        [[ ! -e /etc/v2bxss ]]
        ! grep -Eq '^(stop|start|restart|disable|enable) ' "$fixture/calls"
        ;;
    failed-start)
        if run_migration --apply > "$fixture/result.log" 2>&1; then exit 1; fi
        grep -Fxq active "$fixture/old-active"
        grep -Fxq inactive "$fixture/new-active"
        ;;
    active|stopped|rollback|update|stale-rollback)
        run_migration --apply > "$fixture/result.log"
        grep -Fq '/etc/v2bxss/nodes/vmess.json5' /etc/v2bxss/config.json
        grep -Fq '"UnknownOption"' /etc/v2bxss/config.json
        grep -Fq 'Include":"relative.json' /etc/v2bxss/config.json
        for protocol in vmess vless trojan shadowsocks hysteria hysteria2 tuic anytls; do
            cmp "/etc/V2bX/nodes/$protocol.json5" "/etc/v2bxss/nodes/$protocol.json5"
        done
        cmp /usr/local/V2bX/geosite.dat /etc/v2bxss/legacy-runtime/geosite.dat
        cmp /usr/local/V2bX/relative.json /etc/v2bxss/legacy-runtime/relative.json
        cmp /etc/V2bX/tls.crt /etc/v2bxss/tls.crt
        [[ $(readlink /etc/v2bxss/linked-nodes) == /etc/v2bxss/nodes ]]
        [[ $(readlink /etc/v2bxss/external-cert.pem) == /etc/ssl/fixture/cert.pem ]]
        grep -Fxq 'WorkingDirectory=/etc/v2bxss/legacy-runtime/' /etc/systemd/system/v2bxss.service
        grep -Fxq 'ExecStart=/etc/v2bxss/current/v2bxss server --config /etc/v2bxss/config.json' /etc/systemd/system/v2bxss.service
        [[ -x /etc/v2bxss/current/v2bxss && -f /etc/v2bxss/v2bxss ]]
        if [[ "$scenario" == stopped ]]; then
            ! grep -Eq '^(stop|start|restart) ' "$fixture/calls"
            [[ ! -f "$fixture/new-enabled" ]]
        else
            grep -Fxq inactive "$fixture/old-active"
            grep -Fxq active "$fixture/new-active"
        fi
        backup=$(sed -n 's/^迁移备份：//p' "$fixture/result.log")
        if [[ "$scenario" == rollback ]]; then
            bash "$backup/rollback-upstream.sh" --rollback "$backup" --apply
            grep -Fxq active "$fixture/old-active"
            grep -Fxq inactive "$fixture/new-active"
        elif [[ "$scenario" == update || "$scenario" == stale-rollback ]]; then
            cp /etc/systemd/system/v2bxss.service "$fixture/preserved-unit"
            printf 'version=fixture-2\ngoos=linux\ngoarch=amd64\n' > "$bundle/BUILD-INFO"
            (cd "$bundle"; sha256sum --binary v2bxss BUILD-INFO install-test-node.sh rollback-test-node.sh v2bxss.service v2bxss-manager > SHA256SUMS)
            manifest_hash=$(sha256sum "$bundle/SHA256SUMS" | cut -d ' ' -f 1)
            bash "$bundle/install-test-node.sh" --bundle "$bundle" --version fixture-2 \
                --binary-sha256 "$binary_hash" --manifest-sha256 "$manifest_hash" --apply > "$fixture/update.log"
            cmp "$fixture/preserved-unit" /etc/systemd/system/v2bxss.service
            cmp /usr/local/V2bX/relative.json /etc/v2bxss/legacy-runtime/relative.json
            if [[ "$scenario" == stale-rollback ]]; then
                if bash "$backup/rollback-upstream.sh" --rollback "$backup" --apply > "$fixture/stale.log" 2>&1; then exit 1; fi
                grep -Fq '已更新到其他版本' "$fixture/stale.log"
            fi
        fi
        ;;
    *) echo 'Unknown scenario' >&2; exit 2 ;;
esac
sha256sum --check "$fixture/original.sha" > /dev/null
echo "PASS: upstream migration $scenario (all 8 node types/resources preserved; fixture services only)"
