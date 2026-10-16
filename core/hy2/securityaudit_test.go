package hy2

import (
	"context"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/securityaudit"
)

type auditTestClient struct{}

func (auditTestClient) FetchSecurityAudit(context.Context) (securityaudit.Config, error) {
	return securityaudit.Config{Version: "test-v1", Enabled: true, Rules: []securityaudit.Rule{{ID: "r1", Type: "domain_exact", Value: "blocked.test", Action: "block"}}}, nil
}
func (auditTestClient) ReportSecurityAudit(context.Context, securityaudit.Report) error { return nil }

func TestSecurityAuditNativeHy2PassesExactAuthenticatedIdentity(t *testing.T) {
	// Engine matching and async transport are exercised independently. This
	// verifies adapter validation and that absent/unmapped users remain no-op.
	f := &auditRequestFilter{tag: "hy2-test"}
	if err := f.CheckRequest("uuid-user", "tcp", "blocked.test:443"); err != nil {
		t.Fatal("unconfigured node changed")
	}
	a := securityaudit.NewAgent(auditTestClient{}, securityaudit.Options{NodeID: 7, NodeType: "hysteria2", Core: "hysteria2"})
	a.UpdateUsers(map[string]int{"uuid-user": 42})
	securityaudit.Register("hy2-test", a)
	defer securityaudit.Unregister("hy2-test")
	a.Start()
	defer a.Close()
	deadline := time.Now().Add(time.Second)
	for securityaudit.Version("hy2-test") == "" && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if securityaudit.Version("hy2-test") == "" {
		t.Fatal("test policy failed to load")
	}
	if err := f.CheckRequest("uuid-user", "tcp", "blocked.test:443"); err == nil {
		t.Fatal("authenticated TCP target not blocked")
	}
	if err := f.CheckRequest("uuid-user", "udp", "blocked.test:443"); err == nil {
		t.Fatal("authenticated UDP target not blocked")
	}
	if err := f.CheckRequest("uuid-user", "tcp", "allowed.test:443"); err != nil {
		t.Fatal("unmatched TCP target blocked")
	}
	// Invalid target follows upstream error handling; no panic or broad block.
	for _, addr := range []string{"not-a-host-port", "blocked.test:0", "blocked.test:noport"} {
		if err := f.CheckRequest("uuid-user", "tcp", addr); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.CheckRequest("other-user", "udp", "blocked.test:443"); err != nil {
		t.Fatal("unknown user unexpectedly blocked")
	}
}
