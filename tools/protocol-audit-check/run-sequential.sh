#!/usr/bin/env bash
# Run only in an isolated remote Linux environment, never with live panel data.
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo 'Run this integration suite on the isolated remote Linux test host.' >&2
  exit 2
fi
if [[ ${AUDIT_TEST_WORKDIR:-} != /* || ${AUDIT_TEST_WORKDIR:-} == / ]]; then
  echo 'Set AUDIT_TEST_WORKDIR to a dedicated directory on a disk with enough space (not /tmp tmpfs).' >&2
  exit 2
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd -- "$script_dir/../.."
export GOMAXPROCS=${GOMAXPROCS:-1}
export GOMEMLIMIT=${GOMEMLIMIT:-800MiB}
export GOGC=${GOGC:-20}
export GOEXPERIMENT=${GOEXPERIMENT:-jsonv2}
export GOTOOLCHAIN=local
export GOPROXY=${GOPROXY:-off}
export GOSUMDB=${GOSUMDB:-off}
export GOTMPDIR=${GOTMPDIR:-"$AUDIT_TEST_WORKDIR/tmp"}
export GOCACHE=${GOCACHE:-"$AUDIT_TEST_WORKDIR/cache"}
export GOMODCACHE=${GOMODCACHE:-"$AUDIT_TEST_WORKDIR/modules"}
mkdir -p -- "$GOTMPDIR" "$GOCACHE" "$GOMODCACHE" "$AUDIT_TEST_WORKDIR/results"
results=$(mktemp -d "$AUDIT_TEST_WORKDIR/results/run.XXXXXXXX")
printf 'Results: %s\n' "$results"
go version

if [[ $# == 0 ]]; then
  set -- xray/vmess xray/vless xray/shadowsocks xray/trojan \
    sing/vmess sing/vless sing/shadowsocks sing/trojan \
    sing/hysteria sing/hysteria2 sing/tuic sing/anytls hysteria2/hysteria2
fi
failed=0
for item in "$@"; do
  case "$item" in
    xray/vmess|xray/vless|xray/shadowsocks|xray/trojan|sing/vmess|sing/vless|sing/shadowsocks|sing/trojan|sing/hysteria|sing/hysteria2|sing/tuic|sing/anytls|hysteria2/hysteria2) ;;
    *) printf 'Unknown core/protocol: %s\n' "$item" >&2; exit 2 ;;
  esac
  available=$(df -Pk "$GOTMPDIR" | awk 'NR == 2 { print $4 }')
  if [[ $available -lt 1048576 ]]; then
    echo 'Stopping before the next test: less than 1 GiB free on the build filesystem.' >&2
    exit 2
  fi
  core=${item%/*}; protocol=${item#*/}
  printf '\nSTART %s %s\n' "$item" "$(date -Is)"
  if go test -p 1 -parallel 1 -buildvcs=false \
    -tags 'sing xray hysteria2 with_quic with_grpc with_utls with_wireguard with_acme with_gvisor' \
    ./tools/protocol-audit-check -run "^TestProtocolAuditRoundTrip$/^${core}$/^${protocol}$" \
    -v -count=1 -timeout=2m 2>&1 | tee "$results/$core-$protocol.log"; then
    printf '%s\tPASS\n' "$item" | tee -a "$results/summary.tsv"
  else
    printf '%s\tFAIL\n' "$item" | tee -a "$results/summary.tsv"
    failed=1
  fi
  df -h -- "$GOTMPDIR"
done
exit "$failed"
