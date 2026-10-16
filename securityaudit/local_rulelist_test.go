package securityaudit

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

func TestLocalRuleListIndependentImmutableAndBoundedReport(t *testing.T) {
	a, client := testAgent(t, 100)
	s := LocalRuleList{Source: "local_rulelist", Configured: true, ReadOnly: true, SHA256: strings.Repeat("a", 64), LastCheckedAt: 1, LastLoadedAt: 1,
		Rules: []LocalRule{{Type: "domain_regex", Value: `^local\.invalid$`, Action: "block", ReadOnly: true}}}
	a.UpdateLegacyRules([]LegacyRule{{Type: "domain_regex", Value: `^panel\.invalid$`, Source: "panel_routes", Action: "block"}})
	if err := a.UpdateLocalRuleList(s); err != nil {
		t.Fatal(err)
	}
	s.Rules[0].Value = "mutated"
	a.flush(context.Background())
	r := client.reports[0]
	if r.LocalRuleList == nil || r.LocalRuleList.Rules[0].Value != `^local\.invalid$` || len(*r.LegacyRules) != 1 || (*r.LegacyRules)[0].Source != "panel_routes" {
		t.Fatal("inventory sources mixed or caller mutation changed snapshot")
	}
	if a.Check("authenticated-key", "local.invalid", 443, "tls") {
		t.Fatal("inventory accidentally enabled enforcement")
	}
	// A caller receiving a report cannot mutate the agent's stored inventory.
	r.LocalRuleList.Rules[0].Value = "also-mutated"
	a.flush(context.Background())
	if client.reports[1].LocalRuleList.Rules[0].Value != `^local\.invalid$` {
		t.Fatal("report aliases stored inventory")
	}
	before := a.localRules.Load()
	for _, modify := range []func(*LocalRuleList){
		func(n *LocalRuleList) { n.Error = "/private/local/path" },
		func(n *LocalRuleList) { n.Enabled = true },
		func(n *LocalRuleList) { n.SHA256 = "bad" },
		func(n *LocalRuleList) { n.Rules[0].ReadOnly = false },
		func(n *LocalRuleList) { n.Rules = make([]LocalRule, 1001) },
		func(n *LocalRuleList) {
			n.Rules = nil
			for i := 0; i < 150; i++ {
				n.Rules = append(n.Rules, LocalRule{Type: "domain_regex", Value: strings.Repeat("<", 400), Action: "block", ReadOnly: true})
			}
		},
	} {
		next := cloneLocalRuleList(*before)
		modify(&next)
		if a.UpdateLocalRuleList(next) == nil || a.localRules.Load() != before {
			t.Fatal("invalid inventory replaced valid report")
		}
	}
	encoded, _ := json.Marshal(client.reports[1])
	if strings.Contains(string(encoded), "path") || len(encoded) >= 256<<10 {
		t.Fatal("private path leaked or oversized report")
	}
}

func TestLocalRuleListErrorsRetainValidSnapshotContract(t *testing.T) {
	s := LocalRuleList{Source: "local_rulelist", Configured: true, Enabled: true, EnforcementRequested: true, EnforcementSupported: true, ReadOnly: true, SHA256: strings.Repeat("b", 64), LastLoadedAt: 12, LastCheckedAt: 14, Error: "invalid_regex:line 3", Rules: []LocalRule{{Type: "domain_regex", Value: "^example.invalid$", Action: "block", ReadOnly: true}}}
	if err := ValidateLocalRuleList(s); err != nil {
		t.Fatal(err)
	}
	s.SHA256 = ""
	if ValidateLocalRuleList(s) == nil {
		t.Fatal("enabled without a valid snapshot")
	}
}
