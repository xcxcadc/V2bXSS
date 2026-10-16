# Pinned Hysteria core patch

Source: github.com/apernet/hysteria/core/v2 v2.6.4 (upstream module checksum remains in the parent go.sum).
The upstream LICENSE.md is retained. This is a local replacement, not a claimed upstream release.

The vendored `internal/integration_tests/test.crt` and `test.key` are unchanged
public upstream test fixtures. They are not deployment credentials. New V2bX
adapter/probe tests generate temporary certificates. Never install the upstream
test fixture key on a service or commit actual node certificates.

Changes: add optional `server.Config.RequestFilter`, carrying the authenticated ID and requested target before TCP connect, before UDP initial dial, and before a changed UDP destination is sent. A nil filter keeps the original paths. Existing RequestHook/sniff, authenticator, traffic counters and event logging remain independent.

The R2 patch indexes authenticated QUIC sessions and exposes optional
`DisconnectUser(string)` on the concrete server without changing the upstream
`Server` interface. User removal can close all existing TCP/UDP streams for that
identity. A filter may additionally implement `ValidateUser(string) bool` to
close the authentication/registration revocation race. Server Close also closes
indexed sessions. Native V2bX account validation remains independent of audit
policy, and each node owns a separate authorization map.

The V2bX adapter provides hostname, literal target IP/CIDR and port security rules. Native Hysteria does not expose the detected application protocol here; protocol rules are explicitly unsupported. No packet bodies or unmatched connection history are sent to the panel. Future core updates must port and re-test this small callback.
