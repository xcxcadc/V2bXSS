# Optional node security audit

This extension records only authenticated users' connections that match an
administrator-configured security rule. It does not collect unmatched browsing
history, packet bodies, URL paths, or HTTP credentials. `observe` records the
match; `block` rejects that target connection. Neither changes account state.

## Panel interface

Requests reuse existing node authentication (`node_type`, `node_id`, `token`):

- `GET /api/v1/server/UniProxy/securityAudit/config`
- `POST /api/v1/server/UniProxy/securityAudit/events`

Config example (no rules are installed by default):

```json
{
  "version": "administrator-policy-hash",
  "enabled": true,
  "rules": [
    {"id":"test_observe","type":"domain_exact","value":"malware.example","action":"observe"}
  ]
}
```

Supported types: `domain_exact`, `domain_suffix`, `domain_regex`, `ip_cidr`,
`port` (number or inclusive range), and detected application `protocol`.
Protocol names: `http`, `tls`, `quic`, `bittorrent`, `stun`, `ssh`.
Domain suffixes respect DNS label boundaries. Regex uses a restricted common
Go RE2/PHP PCRE subset, not arbitrary PCRE or Xray routing syntax.

The agent polls every 30 seconds and reports every 5 seconds, independently of
traffic and user quota reporting. Updates replace the complete immutable policy
without restarting the node. Invalid or unavailable updates retain the last
valid policy. An optional cache path restores that policy after process restart.
Use a unique cache file for each node. A panel without the extension starts with
the engine inactive; explicit `enabled:false` disables an existing policy.

The report queue is bounded to 2048 matches by default and batches at most 100.
When full, evidence is dropped with a visible count; connection handling never
waits for HTTP or disk. Retries retain event IDs for panel deduplication. Events
are grouped by their original policy version; `applied_version` separately
identifies the current policy. Invalid-event rejections are visible and do not
permanently stall later valid evidence.

`legacy_rules` is a read-only, deduplicated inventory of existing panel-supplied
route blocks. It does not change those routes or silently import them. Inventory
is bounded to 1000 entries/80 KiB encoded JSON and reports truncation. External
Xray routing JSON/native Hysteria ACL files are not represented by this inventory.
The upstream `RuleListPath` option is declared but not implemented by upstream;
setting that option does not import a rule file.

## Core coverage and limits

| Core | Host/domain | Literal IP/CIDR | Port | Detected application protocol |
| --- | --- | --- | --- | --- |
| Xray | Yes, when requested or sniffed | Yes | Yes | When available from sniffing |
| sing-box | Yes, when requested or sniffed | Yes | Yes | When available from sniffing |
| Native Hysteria 2 | Requested hostname | Yes | Yes | Unsupported at this hook |

Xray/sing preserve an original literal destination alongside a sniffed domain,
so domain matching does not erase literal-IP CIDR matching. A hostname is not
resolved a second time for audit CIDR matching. ECH/encryption and absent sniff
results limit domain/protocol visibility. Sniffing is not automatically enabled
or reconfigured by this extension.

Rules check new connections, not retroactive termination of established TCP
streams. Native Hysteria checks new TCP connects, initial UDP targets, changed
UDP destinations, and subsequent UDP datagrams after a policy version change.
No application protocol is inferred from UDP transport alone. Each node reports
its actual core capabilities for the panel to display.

Account eligibility is separate from target-rule updates: when a full user
snapshot removes an expired/exhausted user, native Hysteria actively disconnects
that user's authenticated QUIC sessions and rejects further traffic/requests.
An empty full snapshot revokes the final user; HTTP 304 alone means no change.
Authorization maps are isolated per native node. Traffic counter drains use
atomic swaps to preserve concurrently arriving bytes. These R2 repairs also fix
the upstream push-cadence typo during node configuration updates.

Existing reporting limitations remain outside this extension: upstream removes
traffic counters before/while removing users, and its report task resets before
HTTP succeeds. An abrupt stop, user removal or failed flow report can lose a
pending usage delta. Drain/confirm successful reports before replacing the test
service. The security evidence retry queue does not change flow-report delivery.

Native Hysteria uses a pinned, licensed local core patch documented in
`third_party/hysteria-core/AUDIT_PATCH.md`. Future core upgrades must preserve
and retest that optional callback.

## Build and installation

Chinese deployment and acceptance details: [DEPLOYMENT.md](DEPLOYMENT.md).

```sh
GOEXPERIMENT=jsonv2 CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
  -tags 'xray sing hysteria2 with_quic with_utls with_gvisor with_wireguard with_acme' \
  -trimpath -ldflags='-s -w' -o V2bX-audit-linux-amd64 .
```

The upstream one-line installer does not install this fork's extension. Use
the offline build, isolated installer and rollback tools in
[`tools/packaging`](../tools/packaging/README.zh-CN.md). Install/rollback default
to verification only; explicit `--apply` writes and `--start` starts the separate
test service. Preserve `/etc/V2bX` and any existing V2bX service. The legacy
`V2bX update` command is disabled in this build because it downloads an upstream
installer that would overwrite the custom extension. No public upstream push
is required for installation.

Verification: engine/agent tests, HTTP adapter tests, native Hysteria adapter
tests, patched upstream Hysteria server suite, and package compilation with all
cores enabled. Local microbenchmarks are not live-node latency or throughput
guarantees. Actual node protocol, quota expiry, flow report, online counts and
panel operations still require the isolated integration checks before release.
