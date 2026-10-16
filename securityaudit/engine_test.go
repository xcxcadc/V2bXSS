package securityaudit

import (
	"fmt"
	"sync"
	"testing"
)

func TestRuleBoundariesAndTypes(t *testing.T) {
	cases := []struct {
		name, kind, value, target, protocol string
		port                                uint16
		want                                bool
	}{
		{"exact case and trailing dot", "domain_exact", "Example.test", "EXAMPLE.test.", "tls", 443, true},
		{"exact does not include subdomain", "domain_exact", "example.test", "a.example.test", "tls", 443, false},
		{"suffix root", "domain_suffix", "example.test", "example.test", "tls", 443, true},
		{"suffix subdomain", "domain_suffix", "example.test", "a.example.test", "tls", 443, true},
		{"suffix label boundary", "domain_suffix", "example.test", "notexample.test", "tls", 443, false},
		{"suffix path disallowed", "domain_suffix", "example.test", "example.test/private", "tls", 443, false},
		{"regex domain", "domain_regex", `^abuse[0-9]+\.test$`, "abuse12.test", "tls", 443, true},
		{"regex cannot turn into IP rule", "domain_regex", `.*`, "192.0.2.1", "tls", 443, false},
		{"CIDR masks host bits", "ip_cidr", "192.0.2.17/24", "192.0.2.200", "tls", 443, true},
		{"CIDR outside", "ip_cidr", "192.0.2.0/24", "192.0.3.1", "tls", 443, false},
		{"literal IP", "ip_cidr", "2001:db8::1", "2001:db8::1", "tls", 443, true},
		{"mapped v4", "ip_cidr", "192.0.2.0/24", "::ffff:192.0.2.1", "tls", 443, true},
		{"port start inclusive", "port", "22-25", "example.test", "ssh", 22, true},
		{"port end inclusive", "port", "22-25", "example.test", "ssh", 25, true},
		{"port outside", "port", "22-25", "example.test", "ssh", 26, false},
		{"application protocol", "protocol", "bittorrent", "example.test", "bittorrent", 443, true},
		{"transport not application", "protocol", "quic", "example.test", "udp", 443, false},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			var e Engine
			if err := e.Apply(Config{Version: "v1", Enabled: true, Rules: []Rule{{ID: "r1", Type: tt.kind, Value: tt.value, Action: "block"}}}); err != nil {
				t.Fatal(err)
			}
			_, matches, block := e.Evaluate(Connection{UserID: 7, Target: tt.target, Port: tt.port, Protocol: tt.protocol})
			if block != tt.want || (len(matches) > 0) != tt.want {
				t.Fatalf("block=%v matches=%v want=%v", block, matches, tt.want)
			}
		})
	}
}

func TestSniffedDomainKeepsOriginalIPAndOneEventPerRule(t *testing.T) {
	var e Engine
	if err := e.Apply(Config{Version: "v1", Enabled: true, Rules: []Rule{
		{ID: "domain", Type: "domain_exact", Value: "abuse.test", Action: "observe"},
		{ID: "ip", Type: "ip_cidr", Value: "192.0.2.0/24", Action: "block"},
		{ID: "port", Type: "port", Value: "443", Action: "observe"},
	}}); err != nil {
		t.Fatal(err)
	}
	_, matches, block := e.Evaluate(Connection{UserID: 7, Target: "192.0.2.1", Domain: "ABUSE.test.", Port: 443})
	if !block || len(matches) != 3 || matches[0].Target != "abuse.test" || matches[1].Target != "192.0.2.1" || matches[2].Target != "192.0.2.1" {
		t.Fatalf("wrong sniffed-domain/IP evidence: %+v", matches)
	}
	_, matches, _ = e.Evaluate(Connection{UserID: 7, Target: "192.0.2.1", Domain: "https://abuse.test/path", Port: 443})
	if len(matches) != 2 {
		t.Fatal("invalid sniffed target was accepted")
	}
}

func TestPortableRegexRejectsAmbiguousExpensiveAndEngineSpecificSyntax(t *testing.T) {
	for _, expression := range []string{`(a+)+$`, `(a|aa)+$`, `(?=a)`, `(x)\1`, `[[:alpha:]]`, `a+?`, `a++`} {
		var e Engine
		if err := e.Apply(Config{Version: "v1", Enabled: true, Rules: []Rule{{ID: "regex", Type: "domain_regex", Value: expression, Action: "observe"}}}); err == nil {
			t.Fatalf("unsafe or nonportable expression accepted: %q", expression)
		}
	}
}

func BenchmarkEvaluateUnmatched(b *testing.B) {
	for _, count := range []int{0, 100, 1000} {
		b.Run(fmt.Sprintf("rules_%d", count), func(b *testing.B) {
			var e Engine
			c := Config{Version: "v1", Enabled: true}
			for i := 0; i < count; i++ {
				c.Rules = append(c.Rules, Rule{ID: fmt.Sprintf("r%d", i), Type: "domain_suffix", Value: fmt.Sprintf("abuse%d.test", i), Action: "observe"})
			}
			if err := e.Apply(c); err != nil {
				b.Fatal(err)
			}
			conn := Connection{UserID: 1, Target: "normal.test", Port: 443, Protocol: "tls"}
			b.ReportAllocs()
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				e.Evaluate(conn)
			}
		})
	}
}

func BenchmarkAgentUnmatched(b *testing.B) {
	a := NewAgent(&fakeClient{}, Options{NodeID: 1, NodeType: "vmess", Core: "xray"})
	a.UpdateUsers(map[string]int{"key": 1})
	if err := a.engine.Apply(Config{Version: "v1", Enabled: true, Rules: []Rule{{ID: "r1", Type: "domain_suffix", Value: "abuse.test", Action: "block"}}}); err != nil {
		b.Fatal(err)
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		a.Check("key", "normal.test", 443, "tls")
	}
}

func TestInvalidUpdateRetainsLastValidRulesAndUnconfiguredAllows(t *testing.T) {
	var e Engine
	conn := Connection{UserID: 7, Target: "abuse.test", Port: 443, Protocol: "tls"}
	if _, m, b := e.Evaluate(conn); b || len(m) > 0 {
		t.Fatal("unconfigured engine must not affect traffic")
	}
	good := Config{Version: "stable", Enabled: true, Rules: []Rule{{ID: "r1", Type: "domain_exact", Value: "abuse.test", Action: "block"}}}
	if err := e.Apply(good); err != nil {
		t.Fatal(err)
	}
	bad := []Rule{
		{ID: "r1", Type: "domain_regex", Value: "[", Action: "block"},
		{ID: "r1", Type: "domain_exact", Value: "https://abuse.test/path", Action: "block"},
		{ID: "r1", Type: "ip_cidr", Value: "192.0.2.0/99", Action: "block"},
		{ID: "r1", Type: "port", Value: "90-20", Action: "block"},
		{ID: "r1", Type: "protocol", Value: "unknown", Action: "block"},
		{ID: "r1", Type: "domain_exact", Value: "abuse.test", Action: "ban_account"},
	}
	for _, rule := range bad {
		if err := e.Apply(Config{Version: "broken", Enabled: true, Rules: []Rule{rule}}); err == nil {
			t.Fatalf("accepted invalid rule %+v", rule)
		}
		if v, _, b := e.Evaluate(conn); v != "stable" || !b {
			t.Fatal("invalid update changed active policy")
		}
	}
	if err := e.Apply(Config{Version: "off", Enabled: false}); err != nil {
		t.Fatal(err)
	}
	if v, m, b := e.Evaluate(conn); v != "off" || b || len(m) > 0 {
		t.Fatal("disable did not replace active policy")
	}
}

func TestObserveDoesNotBlockAndUnknownUsersDoNotEmit(t *testing.T) {
	var e Engine
	if err := e.Apply(Config{Version: "v1", Enabled: true, Rules: []Rule{{ID: "r1", Type: "domain_suffix", Value: "example.test", Action: "observe"}}}); err != nil {
		t.Fatal(err)
	}
	if _, m, b := e.Evaluate(Connection{UserID: 1, Target: "example.test", Port: 443}); b || len(m) != 1 {
		t.Fatal("observe rule blocked or missed")
	}
	if _, m, b := e.Evaluate(Connection{UserID: 0, Target: "example.test", Port: 443}); b || len(m) != 0 {
		t.Fatal("unknown user emitted")
	}
	if _, m, b := e.Evaluate(Connection{UserID: 1, Target: "https://example.test", Port: 443}); b || len(m) != 0 {
		t.Fatal("URL emitted")
	}
}

func TestAtomicReplacementUnderConcurrentConnections(t *testing.T) {
	var e Engine
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 1000; j++ {
				e.Evaluate(Connection{UserID: 1, Target: "example.test", Port: 443})
			}
		}()
	}
	for i := 0; i < 500; i++ {
		if err := e.Apply(Config{Version: "v1", Enabled: true, Rules: []Rule{{ID: "r1", Type: "domain_exact", Value: "example.test", Action: "observe"}}}); err != nil {
			t.Fatal(err)
		}
	}
	wg.Wait()
}
