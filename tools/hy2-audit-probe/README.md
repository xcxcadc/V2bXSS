# Isolated native HY2 probe

This diagnostic binary is separate from the node binary. It authenticates with
the pinned native HY2 client and tests random echo payloads. Only loopback
servers and targets are accepted. Auth, target, packet contents, raw errors and
tokens are never printed. JSON results include verified byte counts.

Build:

```sh
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags='-s -w' \
  -o hy2-audit-probe-linux-amd64 ./tools/hy2-audit-probe
```

Create a private config (mode 0600), replacing the test UUID locally:

```json
{
  "server": "127.0.0.1:38443",
  "auth": "REPLACE_WITH_TEST_USER_UUID",
  "timeout_ms": 3000,
  "tls": {
    "server_name": "audit-node.example",
    "ca_file": "/etc/V2bX-audit-test/tls.crt",
    "insecure_skip_verify": false
  }
}
```

Run a bounded, loopback echo fixture, supporting TCP and UDP on the same port:

```sh
./hy2-audit-probe-linux-amd64 echo --listen 127.0.0.1:38080
```

Run one phase; an authenticated line precedes the result:

```sh
./hy2-audit-probe-linux-amd64 run --config /private/probe.json \
  --phase baseline --transport tcp --target 127.0.0.1:38080 \
  --expect allow --bytes 65536 --repeat 4
./hy2-audit-probe-linux-amd64 run --config /private/probe.json \
  --phase baseline --transport udp --target 127.0.0.1:38080 \
  --expect allow --bytes 1000 --repeat 4
```

After applying an observe rule for port 38080 and waiting for the node's
`applied_version`, rerun with `--phase observe --expect allow`; check panel
evidence for matching observations. Change action to block, wait for the new
version, then use `--expect block`. Remove or disable that rule, wait for the
new version, then use `--phase restored --expect allow`. The probe does not
create/edit rules or bypass the panel's permissions.

For one authenticated QUIC session across hot updates, use `session --config
/private/probe.json`; send JSON lines on stdin. Each produces one result before
reading the next. The UDP session is reused after successful sends, so a policy
update is tested on the same target/session, not only a new session:

```json
{"phase":"baseline","transport":"tcp","target":"127.0.0.1:38080","expect":"allow","bytes":65536}
{"phase":"baseline","transport":"udp","target":"127.0.0.1:38080","expect":"allow","bytes":1000}
{"phase":"observe","transport":"tcp","target":"127.0.0.1:38080","expect":"allow","bytes":65536}
{"phase":"observe","transport":"udp","target":"127.0.0.1:38080","expect":"allow","bytes":1000}
{"phase":"blocked","transport":"tcp","target":"127.0.0.1:38080","expect":"block"}
{"phase":"blocked","transport":"udp","target":"127.0.0.1:38080","expect":"block","bytes":1000}
{"phase":"restored","transport":"tcp","target":"127.0.0.1:38080","expect":"allow","bytes":65536}
{"phase":"restored","transport":"udp","target":"127.0.0.1:38080","expect":"allow","bytes":1000}
```

Feed each phase only after the corresponding external rule change/acknowledged
policy version. EOF ends the session. An actual audit rejection is required to
pass a blocked TCP check; an unrelated connection error fails it. UDP provides
no target rejection response: its `no_response` result sets
`requires_rule_evidence:true`. A working baseline/restored echo and the matching
panel block evidence are required to conclude UDP policy blocking.

Exit 0: all expectations passed. Exit 1: one or more results failed. Exit 2:
invalid config, input or authentication/handshake failure. Echo reports its
counters on SIGTERM or Ctrl-C. TCP payload limit 1 MiB per exchange, UDP 1200
bytes, repeat limit 100. No secret CLI flags are required.
The loopback echo TCP session has a 30-minute maximum lifetime, allowing a
300-second panel pull interval without the fixture expiring during acceptance.

Local integration test starts a real pinned native HY2 server, verifies its
generated test CA, then checks TCP/UDP baseline, observe, block and restore on
the same authenticated client. It also verifies that nonloopback destinations
are rejected. This local test is separate from testing the deployed panel/node.

## Quota / expiry revocation acceptance

The separate `revocation` command retains an established TCP stream, UDP session
and authenticated QUIC connection across three externally controlled stages:

```sh
./hy2-audit-probe-linux-amd64 revocation --config /private/probe.json \
  --target 127.0.0.1:38080
```

Send each JSON line on stdin only after completing the corresponding panel step.
The probe never changes quota, expiry, users, policy or database contents.

1. While the isolated fixture user is eligible, send `{"phase":"baseline"}`.
   Require `success:true`, `sent_bytes:5096`, `received_bytes:5096`. TCP and UDP
   remain open afterward. Repeating baseline is allowed while still eligible.
2. Externally exhaust only that fixture user's quota OR set its expiry in the
   past. Wait until the node has fetched a new full snapshot excluding that user
   (including the valid empty-list case), without restarting the node service.
   Then send `{"phase":"revoked"}`. Require all four boolean fields true:
   `existing_tcp_revoked`, `existing_udp_revoked`, `existing_quic_revoked`,
   `fresh_auth_rejected`.
3. Restore only that fixture's quota/expiry, wait until it is assigned back to the
   node, then send `{"phase":"restored"}`. Require `success:true`,
   `fresh_auth_restored:true`, and another 5096 bytes in each direction. Send
   `{"phase":"finish"}` or end stdin
   and require `revocation_summary.success:true` plus exit 0.
4. Run a fresh three-stage session for the other case (expiry vs quota). Keep the
   service process running throughout, retain its PID, and check panel flow
   counters/online reports separately before and after each test.

Example for a single shell/SSH session, using a private temporary FIFO to retain
stdin between panel operations (replace the paths; a loopback echo must already
be running):

```sh
umask 077
probe_run_dir=$(mktemp -d /tmp/hy2-revocation.XXXXXX)
mkfifo "$probe_run_dir/control"
exec 3<>"$probe_run_dir/control"
./hy2-audit-probe-linux-amd64 revocation --config /private/probe.json \
  --target 127.0.0.1:38080 <&3 >"$probe_run_dir/results.jsonl" &
probe_pid=$!
printf '%s\n' '{"phase":"baseline"}' >&3
# Read results.jsonl, change only the fixture quota/expiry, wait for user sync.
printf '%s\n' '{"phase":"revoked"}' >&3
# Read results.jsonl, restore the fixture, wait for user sync.
printf '%s\n' '{"phase":"restored"}' >&3
# Read all three successful stage results, then finish and check summary/exit.
printf '%s\n' '{"phase":"finish"}' >&3
wait "$probe_pid"
exec 3>&-
```

The `finish` command produces the summary and exits. A subprocess driver can
instead close the child's stdin pipe after restoration. Stopping the diagnostic
does not restart/stop the node or echo service.

False-positive controls: blocked TCP must expose the remote native account-close
code `0x107` both on the held TCP stream and when opening a new stream through the
old QUIC client. Timeouts, an audit rule rejection, EOF, normal service shutdown
and locally closed sessions do not count. UDP must close, and a fresh connection
must receive an explicit HY2 authentication rejection; network/TLS/handshake
failure does not count. Recovery must establish a new client and verify random
TCP/UDP echo data. A failed or prematurely requested stage stays a failed run;
restart from a fresh eligible baseline after confirming node synchronization.
The probe alone cannot prove why the panel removed a user: preserve the fixture
quota/expiry state, excluded-user snapshot, service PID and matching timestamps.
Every revocation boolean is printed even when false. `tcp_detail`, `udp_detail`
and `quic_detail` contain only safe error categories plus numeric close codes:
remote account revocation is application code 263 (`0x107`), whereas `eof`,
`timeout`, `target_audit_rejected` and normal close code 256 cannot pass. Raw
network errors are never printed. A premature check does not count as success;
restore eligibility and begin a fresh session after confirming actual node user
sync. Directly fetching the panel's user list is insufficient to prove the node
has consumed it; its removal log and unchanged service PID provide that evidence.
