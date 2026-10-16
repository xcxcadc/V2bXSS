package securityaudit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"testing"
)

type fakeClient struct {
	config               Config
	configErr, reportErr error
	reports              []Report
}

func TestLegacyInventoryIsReadOnlyDeduplicatedBoundedAndCanClear(t *testing.T) {
	a, f := testAgent(t, 100)
	rules := []LegacyRule{
		{Type: "protocol", Value: "bittorrent", Action: "block", Source: "panel_routes"},
		{Type: "protocol", Value: "bittorrent", Action: "block", Source: "panel_routes"},
	}
	a.UpdateLegacyRules(rules)
	a.flush(context.Background())
	if f.reports[0].LegacyRules == nil || len(*f.reports[0].LegacyRules) != 1 {
		t.Fatal("inventory lost or not deduplicated")
	}
	if a.Check("authenticated-key", "normal.test", 443, "bittorrent") {
		t.Fatal("inventory changed enforcement")
	}
	for i := 0; i < 1000; i++ {
		rules = append(rules, LegacyRule{Type: "domain_regex", Value: fmt.Sprintf("%d%s", i, strings.Repeat("<", 450)), Action: "block", Source: "panel_routes"})
	}
	a.UpdateLegacyRules(rules)
	for i := 0; i < 100; i++ {
		a.Check("authenticated-key", "abuse.test", 443, "tls")
	}
	a.flush(context.Background())
	report := f.reports[1]
	encoded, err := json.Marshal(report)
	if err != nil || len(encoded) >= 256<<10 || report.SyncError == "" || report.LegacyRules == nil || len(*report.LegacyRules) >= 1000 {
		t.Fatal("inventory not bounded or truncation not visible")
	}
	a.UpdateLegacyRules(nil)
	a.flush(context.Background())
	if f.reports[2].LegacyRules == nil || len(*f.reports[2].LegacyRules) != 0 {
		t.Fatal("empty inventory must explicitly clear panel directory")
	}
}

func (f *fakeClient) FetchSecurityAudit(context.Context) (Config, error) {
	return f.config, f.configErr
}
func (f *fakeClient) ReportSecurityAudit(_ context.Context, r Report) error {
	f.reports = append(f.reports, r)
	return f.reportErr
}

func testAgent(t *testing.T, size int) (*Agent, *fakeClient) {
	t.Helper()
	f := &fakeClient{config: Config{Version: "v1", Enabled: true, Rules: []Rule{{ID: "r1", Type: "domain_exact", Value: "abuse.test", Action: "block"}}}}
	a := NewAgent(f, Options{NodeID: 2, NodeType: "vmess", Core: "xray", QueueSize: size})
	a.UpdateUsers(map[string]int{"authenticated-key": 42})
	a.syncConfig(context.Background())
	return a, f
}

func TestBoundedQueueDoesNotDisableBlockingAndRetriesStableIDs(t *testing.T) {
	a, f := testAgent(t, 2)
	for i := 0; i < 3; i++ {
		if !a.Check("authenticated-key", "abuse.test", 443, "tls") {
			t.Fatal("queue overflow must not disable block")
		}
	}
	if len(a.queue) != 2 || a.dropped.Load() != 1 {
		t.Fatalf("queue=%d dropped=%d", len(a.queue), a.dropped.Load())
	}
	f.reportErr = errors.New("offline")
	a.flush(context.Background())
	if len(a.queue) != 2 {
		t.Fatal("failed report lost events")
	}
	firstID := f.reports[0].Events[0].EventID
	f.reportErr = nil
	a.flush(context.Background())
	if len(a.queue) != 0 || f.reports[1].Events[0].EventID != firstID {
		t.Fatal("retry was not idempotent")
	}
	e := f.reports[1].Events[0]
	if e.UserID != 42 || e.NodeID != 2 || e.RuleID != "r1" || e.Target != "abuse.test" {
		t.Fatalf("wrong identity/evidence: %+v", e)
	}
}

func TestNoUnmatchedCollectionAndUserSnapshotReplacement(t *testing.T) {
	a, _ := testAgent(t, 10)
	a.Check("authenticated-key", "normal.test", 443, "tls")
	a.Check("unknown", "abuse.test", 443, "tls")
	if len(a.queue) != 0 {
		t.Fatal("collected unmatched or unknown-user browsing")
	}
	a.UpdateUsers(map[string]int{})
	if a.Check("authenticated-key", "abuse.test", 443, "tls") || len(a.queue) != 0 {
		t.Fatal("removed user still mapped")
	}
}

func TestPermanentRejectionDoesNotPoisonQueue(t *testing.T) {
	a, f := testAgent(t, 10)
	a.Check("authenticated-key", "abuse.test", 443, "tls")
	f.reportErr = &RejectedReport{Count: 1, Status: 200}
	a.flush(context.Background())
	if len(a.queue) != 0 || a.dropped.Load() != 1 || a.lastError.Load() == nil {
		t.Fatal("rejected event stalled queue or rejection hidden")
	}
}

func TestBatchLimitAndVersionIsolation(t *testing.T) {
	a, f := testAgent(t, 200)
	for i := 0; i < 110; i++ {
		a.Check("authenticated-key", "abuse.test", 443, "tls")
	}
	f.config.Version = "v2"
	a.syncConfig(context.Background())
	a.Check("authenticated-key", "abuse.test", 443, "tls")
	a.flush(context.Background())
	a.flush(context.Background())
	a.flush(context.Background())
	if len(f.reports[0].Events) != 100 || len(f.reports[1].Events) != 10 || len(f.reports[2].Events) != 1 {
		t.Fatal("batches not bounded or mixed versions")
	}
	if f.reports[0].Version != "v1" || f.reports[0].AppliedVersion != "v2" || f.reports[2].Version != "v2" {
		t.Fatal("batch/snapshot version mismatch")
	}
}

func TestConfigOutageKeepsPolicyAnd404IsOptionalBeforeFirstConfig(t *testing.T) {
	a, f := testAgent(t, 10)
	f.configErr = errors.New("temporary outage")
	a.syncConfig(context.Background())
	if !a.Check("authenticated-key", "abuse.test", 443, "tls") {
		t.Fatal("outage removed last valid policy")
	}
	f.configErr = ErrUnavailable
	a.syncConfig(context.Background())
	if !a.Check("authenticated-key", "abuse.test", 443, "tls") {
		t.Fatal("missing API removed last valid policy")
	}
	b := NewAgent(f, Options{})
	b.UpdateUsers(map[string]int{"authenticated-key": 42})
	b.syncConfig(context.Background())
	if b.Check("authenticated-key", "abuse.test", 443, "tls") {
		t.Fatal("unextended panel unexpectedly blocks")
	}
	f.configErr = nil
	f.config.Enabled = false
	a.syncConfig(context.Background())
	if a.Check("authenticated-key", "abuse.test", 443, "tls") {
		t.Fatal("explicit disable was not applied")
	}
}

func TestLastValidCacheRestoresOfflineAndInvalidUpdateDoesNotReplace(t *testing.T) {
	a, f := testAgent(t, 10)
	a.options.CachePath = filepath.Join(t.TempDir(), "node-2.json")
	a.syncConfig(context.Background())
	f.config.Rules[0].Type = "domain_regex"
	f.config.Rules[0].Value = "["
	a.syncConfig(context.Background())
	b := NewAgent(f, a.options)
	b.UpdateUsers(map[string]int{"authenticated-key": 42})
	if err := b.loadCache(); err != nil {
		t.Fatal(err)
	}
	if !b.Check("authenticated-key", "abuse.test", 443, "tls") {
		t.Fatal("last valid cache not retained")
	}
}

func TestNativeHy2CapabilitiesDoNotClaimApplicationSniffing(t *testing.T) {
	a := NewAgent(&fakeClient{}, Options{Core: "hysteria2"})
	c := a.capabilities()
	if !c["native_hy2_match_events"] || !c["native_hy2_connection_block"] || c["native_hy2_application_protocol"] || c["xray_match_events"] || c["account_punishment"] {
		t.Fatal("wrong native hy2 capability report")
	}
}
