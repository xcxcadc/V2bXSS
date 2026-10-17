package panel

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/InazumaV/V2bX/conf"
	"github.com/InazumaV/V2bX/securityaudit"
)

func TestSecurityAuditAPIUsesExistingNodeAuthAndSeparateEndpoints(t *testing.T) {
	var received securityaudit.Report
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("node_type") != "vmess" || r.URL.Query().Get("node_id") != "7" || r.URL.Query().Get("token") != "test-api-key" {
			t.Error("audit call did not preserve node authentication")
			w.WriteHeader(403)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/server/UniProxy/securityAudit/config":
			if r.Method != http.MethodGet {
				t.Error("config is not GET")
			}
			json.NewEncoder(w).Encode(securityaudit.Config{Version: "test-v1", Enabled: true, Rules: []securityaudit.Rule{{ID: "safe1", Type: "domain_exact", Value: "malware.example", Action: "observe"}}})
		case "/api/v1/server/UniProxy/securityAudit/events":
			if r.Method != http.MethodPost {
				t.Error("events is not POST")
			}
			if err := json.NewDecoder(r.Body).Decode(&received); err != nil {
				t.Error(err)
			}
			w.Write([]byte(`{"data":{"accepted":1,"inserted":1,"duplicates":0,"rejected":[]}}`))
		default:
			t.Errorf("unexpected endpoint %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer s.Close()
	c, err := New(&conf.ApiConfig{APIHost: s.URL, Key: "test-api-key", NodeType: "vmess", NodeID: 7})
	if err != nil {
		t.Fatal(err)
	}
	cfg, err := c.FetchSecurityAudit(context.Background())
	if err != nil || cfg.Version != "test-v1" || len(cfg.Rules) != 1 {
		t.Fatalf("config=%+v err=%v", cfg, err)
	}
	report := securityaudit.Report{Version: "test-v1", AppliedVersion: "test-v1", Events: []securityaudit.Event{{EventID: "abc_1234567890123456", UserID: 42, NodeID: 7, NodeType: "vmess", Target: "malware.example", Port: 443, RuleID: "safe1", Action: "observe"}}}
	if err := c.ReportSecurityAudit(context.Background(), report); err != nil {
		t.Fatal(err)
	}
	if len(received.Events) != 1 || received.Events[0].UserID != 42 || received.AppliedVersion != "test-v1" {
		t.Fatal("event body changed")
	}
}

func TestSecurityAuditMissingEndpointIsOptional(t *testing.T) {
	s := httptest.NewServer(http.NotFoundHandler())
	defer s.Close()
	c, err := New(&conf.ApiConfig{APIHost: s.URL, Key: "test", NodeType: "vmess", NodeID: 7})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := c.FetchSecurityAudit(context.Background()); !errors.Is(err, securityaudit.ErrUnavailable) {
		t.Fatalf("missing optional config: %v", err)
	}
	if err := c.ReportSecurityAudit(context.Background(), securityaudit.Report{}); !errors.Is(err, securityaudit.ErrUnavailable) {
		t.Fatalf("missing optional events: %v", err)
	}
}

// This checks the node API contract for every supported NodeType. It is not
// evidence of a real client handshake or of a particular core's forwarding hook.
func TestSecurityAuditProtocolAuthMatrix(t *testing.T) {
	for _, kind := range []string{"vmess", "v2ray", "vless", "shadowsocks", "trojan", "hysteria", "hysteria2", "tuic", "anytls"} {
		t.Run(kind, func(t *testing.T) {
			expected := kind
			if kind == "v2ray" {
				expected = "vmess"
			}
			gets, posts := 0, 0
			s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Query().Get("node_type") != expected || r.URL.Query().Get("node_id") != "7" || r.URL.Query().Get("token") != "fixture-api-key" {
					t.Error("protocol-specific node authentication was changed")
					w.WriteHeader(http.StatusForbidden)
					return
				}
				w.Header().Set("Content-Type", "application/json")
				switch r.Method + " " + r.URL.Path {
				case "GET /api/v1/server/UniProxy/securityAudit/config":
					gets++
					json.NewEncoder(w).Encode(securityaudit.Config{Version: "fixture-v1", Enabled: true})
				case "POST /api/v1/server/UniProxy/securityAudit/events":
					posts++
					var report securityaudit.Report
					if err := json.NewDecoder(r.Body).Decode(&report); err != nil || len(report.Events) != 1 || report.Events[0].NodeType != expected || report.Events[0].UserID != 42 {
						t.Error("protocol-specific match identity was lost")
					}
					w.Write([]byte(`{"data":{"accepted":1,"rejected":[]}}`))
				default:
					t.Error("unexpected audit endpoint")
					w.WriteHeader(http.StatusNotFound)
				}
			}))
			defer s.Close()
			c, err := New(&conf.ApiConfig{APIHost: s.URL, Key: "fixture-api-key", NodeType: kind, NodeID: 7})
			if err != nil {
				t.Fatal(err)
			}
			if cfg, err := c.FetchSecurityAudit(context.Background()); err != nil || cfg.Version != "fixture-v1" {
				t.Fatalf("config=%+v err=%v", cfg, err)
			}
			report := securityaudit.Report{Version: "fixture-v1", AppliedVersion: "fixture-v1", Events: []securityaudit.Event{{UserID: 42, NodeID: 7, NodeType: c.NodeType}}}
			if err := c.ReportSecurityAudit(context.Background(), report); err != nil {
				t.Fatal(err)
			}
			if gets != 1 || posts != 1 {
				t.Fatalf("expected one config and one event call; got %d, %d", gets, posts)
			}
		})
	}
	t.Run("v2node-is-not-a-v2bx-protocol", func(t *testing.T) {
		if _, err := New(&conf.ApiConfig{APIHost: "http://127.0.0.1", NodeType: "v2node", NodeID: 7}); err == nil {
			t.Fatal("V2node must not be advertised as a supported V2bX NodeType")
		}
	})
}
