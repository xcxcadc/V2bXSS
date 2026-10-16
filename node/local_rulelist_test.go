package node

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	"github.com/InazumaV/V2bX/limiter"
)

func TestLocalRuleListShippedExampleMatchesDomainBoundaries(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "example", "security-audit-local-rules.txt"))
	if err != nil {
		t.Fatal(err)
	}
	rules, _, err := parseLocalRuleList(data)
	if err != nil || len(rules) != 1 {
		t.Fatalf("invalid shipped local example: %v", err)
	}
	r := regexp.MustCompile(rules[0].Value)
	for target, want := range map[string]bool{
		"malware.example": true, "api.malware.example": true,
		"notmalware.example": false, "malwareXexample": false,
		"malware.example.invalid": false,
	} {
		if got := r.MatchString(target); got != want {
			t.Errorf("shipped example match %q = %t, want %t", target, got, want)
		}
	}
}

func TestLocalRuleListParseBoundsAndComments(t *testing.T) {
	rules, sha, err := parseLocalRuleList([]byte("\ufeff# comment\r\n\n// second\nregexp:^example\\.invalid$\n^example\\.invalid$\nabc#literal\n"))
	if err != nil || len(rules) != 2 || rules[1].Value != "abc#literal" || len(sha) != 64 {
		t.Fatalf("unexpected parse: %#v %q %v", rules, sha, err)
	}
	for input, code := range map[string]string{
		"[": "invalid_regex:line 1", "protocol:tls": "unsupported_prefix:line 1", "regexp:": "invalid_value:line 1", "a\x00b": "invalid_value:line 1", "a\u200bb": "invalid_value:line 1", string([]byte{0xff}): "invalid_utf8", strings.Repeat("a", 513): "invalid_value:line 1", strings.Repeat("a", maxLocalRuleFileBytes+1): "file_too_large",
	} {
		_, _, err = parseLocalRuleList([]byte(input))
		if err == nil || err.Error() != code {
			t.Errorf("expected %q, got %v", code, err)
		}
	}
	var many strings.Builder
	for i := 0; i < 1001; i++ {
		fmt.Fprintf(&many, "^host%d\\.invalid$\n", i)
	}
	if _, _, err = parseLocalRuleList([]byte(many.String())); err == nil || err.Error() != "too_many_rules" {
		t.Fatal("rule bound missing")
	}
	rules, _, err = parseLocalRuleList([]byte("# explicitly empty\n// clear\n"))
	if err != nil || len(rules) != 0 {
		t.Fatal("comment-only clear rejected")
	}
}

func writeRuleFile(t *testing.T, path, data string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
	// Distinct sizes in caller data avoid platform timestamp resolution issues.
}

func TestLocalRuleList304RefreshInventoryAndLastValid(t *testing.T) {
	c, _ := testSnapshotController(t, false)
	c.Options.Core = "xray"
	c.info.Rules = panel.Rules{Regexp: []string{`^panel\.invalid$`}, Protocol: []string{"bittorrent"}}
	if err := c.limiter.UpdateRule(&c.info.Rules); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "rules")
	c.apiClient.RuleListPath = p
	writeRuleFile(t, p, "^local\\.invalid$\n")
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if c.localRules == nil || c.localRules.report.Enabled || len(c.localRules.report.Rules) != 1 || c.limiter.CheckDomainRule("local.invalid") {
		t.Fatal("default RuleListPath must be inventory only")
	}
	c.apiClient.RuleListEnforce = true
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if !c.localRules.report.Enabled || !c.limiter.CheckDomainRule("local.invalid") || !c.limiter.CheckDomainRule("panel.invalid") {
		t.Fatal("304 poll did not enable both sources")
	}
	priorSHA := c.localRules.report.SHA256
	writeRuleFile(t, p, "# replacement\n^next\\.invalid$\n")
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if !c.limiter.CheckDomainRule("next.invalid") || c.limiter.CheckDomainRule("local.invalid") || c.localRules.report.SHA256 == priorSHA {
		t.Fatal("304 failed to reload local policy")
	}
	valid := c.localRules.report
	writeRuleFile(t, p, "# invalid\n[\n")
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if !c.limiter.CheckDomainRule("next.invalid") || c.localRules.report.SHA256 != valid.SHA256 || !c.localRules.report.Enabled || c.localRules.report.Error != "invalid_regex:line 2" {
		t.Fatal("bad file replaced valid policy or lost error")
	}
	if err := os.Remove(p); err != nil {
		t.Fatal(err)
	}
	c.refreshLocalRuleList()
	if c.localRules.report.Error != "open_failed" || !c.limiter.CheckDomainRule("next.invalid") {
		t.Fatal("missing file silently disabled valid policy")
	}
	writeRuleFile(t, p, "# empty clear\n")
	c.refreshLocalRuleList()
	if c.limiter.CheckDomainRule("next.invalid") || !c.limiter.CheckDomainRule("panel.invalid") || !c.limiter.CheckProtocolRule("bittorrent") || c.localRules.report.Error != "" {
		t.Fatal("local clear affected original panel routes")
	}
}

func TestLocalRuleListRejectsNonRegularAndOversizedInventory(t *testing.T) {
	c, _ := testSnapshotController(t, false)
	c.Options.Core = "xray"
	c.apiClient.RuleListPath, c.apiClient.RuleListEnforce = t.TempDir(), true
	c.refreshLocalRuleList()
	if c.localRules.report.Error != "not_regular_file" || c.localRules.report.Enabled {
		t.Fatal("directory accepted as policy")
	}
	p := filepath.Join(t.TempDir(), "rules")
	var large strings.Builder
	for i := 0; i < 150; i++ {
		fmt.Fprintf(&large, "%d%s\n", i, strings.Repeat("<", 400))
	}
	writeRuleFile(t, p, large.String())
	c.apiClient.RuleListPath = p
	c.refreshLocalRuleList()
	if c.localRules.report.Error != "inventory_too_large" || c.localRules.report.Enabled || len(c.localRules.report.Rules) != 0 {
		t.Fatal("unreportable policy was enabled")
	}
	link := filepath.Join(t.TempDir(), "symlink")
	if err := os.Symlink(p, link); err == nil {
		c.apiClient.RuleListPath = link
		c.refreshLocalRuleList()
		if c.localRules.report.Error != "not_regular_file" {
			t.Fatal("symlink accepted")
		}
	} else {
		t.Log("symlink creation unavailable; platform privilege restriction")
	}
}

func TestLocalRuleListDoesNotRestartNodeAndUnknownCoreInventoryOnly(t *testing.T) {
	c, _ := testSnapshotController(t, false)
	c.server = nil   // An unchanged panel must never call any core reload method.
	c.userList = nil // no user removal is needed for the empty snapshot.
	p := filepath.Join(t.TempDir(), "rules")
	writeRuleFile(t, p, "^local\\.invalid$\n")
	c.apiClient.RuleListPath, c.apiClient.RuleListEnforce = p, true
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if c.localRules.report.Enabled || c.localRules.report.EnforcementSupported {
		t.Fatal("unknown core enforcement claimed")
	}
	c.Options.Core = "sing"
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if !c.limiter.CheckDomainRule("local.invalid") {
		t.Fatal("supported core did not apply unchanged file")
	}
}

func TestNativeInvalidPanelRulesRetainRunningNodeBeforeTeardown(t *testing.T) {
	c, _ := testSnapshotController(t, false)
	old := c.info
	c.server = nil // Any teardown/reload method call would panic this test.
	if err := c.limiter.UpdateRule(&panel.Rules{Regexp: []string{`^valid\.invalid$`}}); err != nil {
		t.Fatal(err)
	}
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/server/UniProxy/config":
			_, _ = w.Write([]byte(`{"server_port":39001,"cipher":"aes-128-gcm","routes":[{"action":"block","match":["regexp:["]}],"base_config":{"push_interval":9,"pull_interval":3}}`))
		case "/api/v1/server/UniProxy/user":
			_, _ = w.Write([]byte(`{"users":[]}`))
		case "/api/v1/server/UniProxy/alivelist":
			_, _ = w.Write([]byte(`{"alive":{}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	defer s.Close()
	api, err := panel.New(&conf.ApiConfig{APIHost: s.URL, Key: "test", NodeType: "shadowsocks", NodeID: 1})
	if err != nil {
		t.Fatal(err)
	}
	c.apiClient = api
	if err = c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if c.info != old || len(c.userList) != 1 || !c.limiter.CheckDomainRule("valid.invalid") {
		t.Fatal("invalid new panel rule mutated running service")
	}
}

func TestLocalRuleListRefreshBeforePanelOutage(t *testing.T) {
	c, _ := testSnapshotController(t, false)
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(403) }))
	defer s.Close()
	api, err := panel.New(&conf.ApiConfig{APIHost: s.URL, Key: "test", NodeType: "shadowsocks", NodeID: 1})
	if err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(t.TempDir(), "rules")
	writeRuleFile(t, p, "^outage\\.invalid$\n")
	c.apiClient, c.Options.Core = api, "xray"
	api.RuleListPath, api.RuleListEnforce = p, true
	if err = c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if !c.limiter.CheckDomainRule("outage.invalid") || !c.localRules.report.Enabled {
		t.Fatal("panel API outage prevented independent local refresh")
	}
}

type localRuleCoreType struct {
	snapshotCore
	name string
}

func (c *localRuleCoreType) Type() string { return c.name }

func TestLocalRuleListCoreTypeFallback(t *testing.T) {
	c := &Controller{Options: &conf.Options{}, server: &localRuleCoreType{name: "xray"}}
	if !c.localEnforcementSupported() {
		t.Fatal("direct core fallback missed")
	}
	c.server = &localRuleCoreType{name: "Selector(xray sing)"}
	if c.localEnforcementSupported() {
		t.Fatal("unresolved selector claimed support")
	}
}

func BenchmarkLocalRuleListUnchangedPoll(b *testing.B) {
	p := filepath.Join(b.TempDir(), "rules")
	data := []byte(strings.Repeat("# comment\n", 10000) + "^example\\.invalid$\n")
	if err := os.WriteFile(p, data, 0600); err != nil {
		b.Fatal(err)
	}
	c := &Controller{apiClient: &panel.Client{RuleListPath: p, RuleListEnforce: true}, Options: &conf.Options{Core: "xray"}, info: &panel.NodeInfo{}, limiter: &limiter.Limiter{}}
	c.refreshLocalRuleList()
	if c.localRules.report.Error != "" {
		b.Fatal(c.localRules.report.Error)
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		c.refreshLocalRuleList()
	}
}
