//go:build sing && xray && hysteria2 && with_quic

// These tests open real protocol listeners on loopback only. The panel is an
// authenticated HTTP fixture, not a production database or a real user account.
package protocolcheck

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/format"
	"github.com/InazumaV/V2bX/conf"
	"github.com/InazumaV/V2bX/core"
	_ "github.com/InazumaV/V2bX/core/imports"
	"github.com/InazumaV/V2bX/limiter"
	"github.com/InazumaV/V2bX/securityaudit"
	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
	SJSON "github.com/sagernet/sing/common/json"
	M "github.com/sagernet/sing/common/metadata"
)

const fixtureUUID = "55c3e997-6efa-4f83-b624-71b8c704eac7"
const fixtureUser = 42

type fixturePanel struct {
	mu      sync.Mutex
	config  securityaudit.Config
	reports []securityaudit.Report
	traffic map[int][]int64
	online  map[int][]string
	kind    string
}

func (f *fixturePanel) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("token") != "fixture-key" || r.URL.Query().Get("node_id") != "7" || r.URL.Query().Get("node_type") != f.kind {
		http.Error(w, "fixture node auth rejected", 403)
		return
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	w.Header().Set("Content-Type", "application/json")
	switch r.Method + " " + r.URL.Path {
	case "GET /api/v1/server/UniProxy/securityAudit/config":
		json.NewEncoder(w).Encode(f.config)
	case "POST /api/v1/server/UniProxy/securityAudit/events":
		var report securityaudit.Report
		if json.NewDecoder(r.Body).Decode(&report) != nil {
			http.Error(w, "invalid report", 422)
			return
		}
		f.reports = append(f.reports, report)
		w.Write([]byte(`{"data":{"rejected":[]}}`))
	case "POST /api/v1/server/UniProxy/push":
		if json.NewDecoder(r.Body).Decode(&f.traffic) != nil {
			http.Error(w, "invalid traffic", 422)
			return
		}
		w.Write([]byte(`{"data":true}`))
	case "POST /api/v1/server/UniProxy/alive":
		if json.NewDecoder(r.Body).Decode(&f.online) != nil {
			http.Error(w, "invalid online", 422)
			return
		}
		w.Write([]byte(`{"data":true}`))
	default:
		http.NotFound(w, r)
	}
}

func (f *fixturePanel) policy(action, ruleType, value string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	rules := []securityaudit.Rule{}
	if action != "off" {
		rules = append(rules, securityaudit.Rule{ID: "fixture-rule", Type: ruleType, Value: value, Action: action})
	}
	data, _ := json.Marshal(rules)
	sum := sha256.Sum256(data)
	f.config = securityaudit.Config{Version: hex.EncodeToString(sum[:]), Enabled: action != "off", Rules: rules}
	return f.config.Version
}

func (f *fixturePanel) hasEvent(version, action, target string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, report := range f.reports {
		if report.Version != version {
			continue
		}
		for _, e := range report.Events {
			if e.NodeID == 7 && e.NodeType == f.kind && e.UserID == fixtureUser && e.RuleID == "fixture-rule" && e.Action == action && e.Target == target {
				return true
			}
		}
	}
	return false
}

func eventually(t *testing.T, label string, check func() bool) {
	t.Helper()
	deadline := time.Now().Add(6 * time.Second)
	for time.Now().Before(deadline) {
		if check() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("timed out: " + label)
}

func certificate(t *testing.T) (string, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "localhost"}, DNSNames: []string{"localhost"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1")}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	private, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	cert, keyPath := filepath.Join(dir, "cert.pem"), filepath.Join(dir, "key.pem")
	if err = os.WriteFile(cert, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}), 0600); err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(keyPath, pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: private}), 0600); err != nil {
		t.Fatal(err)
	}
	return cert, keyPath
}

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := l.Addr().(*net.TCPAddr).Port
	l.Close()
	return p
}

func echoTargets(t *testing.T) (string, string) {
	t.Helper()
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { tcp.Close() })
	go func() {
		for {
			c, err := tcp.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); c.SetDeadline(time.Now().Add(12 * time.Second)); io.Copy(c, c) }()
		}
	}()
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { udp.Close() })
	go func() {
		b := make([]byte, 65536)
		for {
			n, a, err := udp.ReadFrom(b)
			if err != nil {
				return
			}
			udp.WriteTo(b[:n], a)
		}
	}()
	return tcp.Addr().String(), udp.LocalAddr().String()
}

func serverNode(t *testing.T, kind, coreType string, port int, cert, key string) (core.Core, *panel.NodeInfo, *conf.Options) {
	t.Helper()
	cc := conf.CoreConfig{Type: coreType, XrayConfig: conf.NewXrayConfig(), SingConfig: conf.NewSingConfig(), Hysteria2Config: conf.NewHysteria2Config()}
	cc.SingConfig.NtpConfig.Enable = false
	c, err := core.NewCore([]conf.CoreConfig{cc})
	if err != nil {
		t.Fatal(err)
	}
	if err = c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	common := panel.CommonNode{Host: "127.0.0.1", ServerPort: port, ServerName: "localhost"}
	n := &panel.NodeInfo{
		Id: 7, Type: kind, Common: &common,
		VAllss:      &panel.VAllssNode{CommonNode: common, Network: "tcp", NetworkSettings: json.RawMessage(`{}`)},
		Shadowsocks: &panel.ShadowsocksNode{CommonNode: common, Cipher: "aes-128-gcm"},
		Trojan:      &panel.TrojanNode{CommonNode: common, Network: "tcp", NetworkSettings: json.RawMessage(`{}`)},
		Tuic:        &panel.TuicNode{CommonNode: common, CongestionControl: "cubic"},
		AnyTls:      &panel.AnyTlsNode{CommonNode: common},
		Hysteria:    &panel.HysteriaNode{CommonNode: common, UpMbps: 100, DownMbps: 100},
		Hysteria2:   &panel.Hysteria2Node{CommonNode: common, UpMbps: 100, DownMbps: 100},
	}
	certConfig := &conf.CertConfig{CertMode: "none"}
	if kind != "vmess" && kind != "vless" && kind != "shadowsocks" {
		n.Security = panel.Tls
		certConfig = &conf.CertConfig{CertMode: "file", CertDomain: "localhost", CertFile: cert, KeyFile: key}
	}
	o := &conf.Options{Core: coreType, ListenIP: "127.0.0.1", SendIP: "0.0.0.0", CertConfig: certConfig, XrayOptions: conf.NewXrayOptions(), SingOptions: conf.NewSingOptions()}
	return c, n, o
}

func client(t *testing.T, kind string, port int, cert string) (*box.Box, adapter.Outbound) {
	t.Helper()
	ob := map[string]any{"type": kind, "tag": "probe", "server": "127.0.0.1", "server_port": port}
	switch kind {
	case "vmess":
		ob["uuid"] = fixtureUUID
		ob["security"] = "auto"
	case "vless":
		ob["uuid"] = fixtureUUID
	case "shadowsocks":
		ob["method"] = "aes-128-gcm"
		ob["password"] = fixtureUUID
	case "trojan", "anytls", "hysteria2":
		ob["password"] = fixtureUUID
	case "tuic":
		ob["uuid"] = fixtureUUID
		ob["password"] = fixtureUUID
		ob["congestion_control"] = "cubic"
	case "hysteria":
		ob["auth_str"] = fixtureUUID
		ob["up_mbps"] = 100
		ob["down_mbps"] = 100
	}
	if kind != "vmess" && kind != "vless" && kind != "shadowsocks" {
		ob["tls"] = map[string]any{"enabled": true, "server_name": "localhost", "certificate_path": cert}
	}
	data, _ := json.Marshal(map[string]any{"log": map[string]any{"disabled": true}, "outbounds": []any{ob}})
	ctx := box.Context(context.Background(), include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry(), include.DNSTransportRegistry(), include.ServiceRegistry())
	opts, err := SJSON.UnmarshalExtendedContext[option.Options](ctx, data)
	if err != nil {
		t.Fatal(err)
	}
	b, err := box.New(box.Options{Context: ctx, Options: opts})
	if err != nil {
		t.Fatal(err)
	}
	if err = b.Start(); err != nil {
		b.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { b.Close() })
	out, ok := b.Outbound().Outbound("probe")
	if !ok {
		t.Fatal("probe outbound missing")
	}
	return b, out
}

func exchange(out adapter.Outbound, network, target string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, err := out.DialContext(ctx, network, M.ParseSocksaddr(target))
	if err != nil {
		return err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	payload := bytes.Repeat([]byte("audit-echo-fixture|"), 16)
	if _, err = c.Write(payload); err != nil {
		return err
	}
	var got []byte
	if network == "udp" {
		// Datagram adapters may need space for the encrypted wire frame before
		// returning the payload. Read one whole datagram, never stream fragments.
		buf := make([]byte, 65536)
		n, err := c.Read(buf)
		if err != nil {
			return err
		}
		got = buf[:n]
	} else {
		got = make([]byte, len(payload))
		if _, err = io.ReadFull(c, got); err != nil {
			return err
		}
	}
	if !bytes.Equal(got, payload) {
		return fmt.Errorf("payload mismatch")
	}
	return nil
}

func TestProtocolAuditRoundTrip(t *testing.T) {
	limiter.Init()
	for _, coreType := range []string{"xray", "sing", "hysteria2"} {
		kinds := []string{"vmess", "vless", "shadowsocks", "trojan"}
		if coreType == "sing" {
			kinds = append(kinds, "hysteria", "hysteria2", "tuic", "anytls")
		}
		if coreType == "hysteria2" {
			kinds = []string{"hysteria2"}
		}
		for _, kind := range kinds {
			t.Run(coreType+"/"+kind, func(t *testing.T) {
				cert, key := certificate(t)
				tcpTarget, udpTarget := echoTargets(t)
				c, info, opts := serverNode(t, kind, coreType, freePort(t), cert, key)
				tag := "fixture-" + coreType + "-" + kind
				users := []panel.UserInfo{{Id: fixtureUser, Uuid: fixtureUUID}}
				lim := limiter.AddLimiter(tag, &conf.LimitConfig{}, users, map[int]int{})
				t.Cleanup(func() { limiter.DeleteLimiter(tag) })
				if err := c.AddNode(tag, info, opts); err != nil {
					t.Fatal(err)
				}
				if _, err := c.AddUsers(&core.AddUsersParams{Tag: tag, Users: users, NodeInfo: info}); err != nil {
					t.Fatal(err)
				}
				f := &fixturePanel{kind: kind}
				f.policy("off", "", "")
				s := httptest.NewServer(f)
				t.Cleanup(s.Close)
				api, err := panel.New(&conf.ApiConfig{APIHost: s.URL, Key: "fixture-key", NodeType: kind, NodeID: 7})
				if err != nil {
					t.Fatal(err)
				}
				a := securityaudit.NewAgent(api, securityaudit.Options{NodeID: 7, NodeType: kind, Core: coreType, PollInterval: time.Second, ReportInterval: time.Second})
				a.UpdateUsers(map[string]int{fixtureUUID: fixtureUser, format.UserTag(tag, fixtureUUID): fixtureUser})
				securityaudit.Register(tag, a)
				a.Start()
				t.Cleanup(func() { securityaudit.Unregister(tag); a.Close() })
				_, out := client(t, kind, info.Common.ServerPort, cert)
				for _, phase := range []string{"baseline", "observe", "block", "restored"} {
					action := phase
					if phase == "baseline" || phase == "restored" {
						action = "off"
					}
					version := f.policy(action, "ip_cidr", "127.0.0.1/32")
					eventually(t, "policy applied", func() bool { return securityaudit.Version(tag) == version })
					for network, target := range map[string]string{"tcp": tcpTarget, "udp": udpTarget} {
						err := exchange(out, network, target)
						if phase == "block" {
							if err == nil {
								t.Fatalf("%s bypassed block", network)
							}
						} else if err != nil {
							t.Fatalf("%s %s: %v", phase, network, err)
						}
					}
					if phase == "observe" || phase == "block" {
						eventually(t, "authenticated match report", func() bool { return f.hasEvent(version, action, "127.0.0.1") })
					}
					t.Logf("%s TCP/UDP passed", phase)
				}
				// Domain rules are verified before DNS; no public DNS/network request.
				version := f.policy("block", "domain_suffix", "example.invalid")
				eventually(t, "domain policy applied", func() bool { return securityaudit.Version(tag) == version })
				_, port, _ := net.SplitHostPort(tcpTarget)
				if err := exchange(out, "tcp", "sub.example.invalid:"+port); err == nil {
					t.Fatal("domain rule did not reject")
				}
				eventually(t, "domain rule report", func() bool { return f.hasEvent(version, "block", "sub.example.invalid") })
				version = f.policy("off", "", "")
				eventually(t, "final release applied", func() bool { return securityaudit.Version(tag) == version })
				if err := exchange(out, "tcp", tcpTarget); err != nil {
					t.Fatalf("final restore: %v", err)
				}
				traffic, err := c.GetUserTrafficSlice(tag, false)
				if err != nil || len(traffic) != 1 || traffic[0].UID != fixtureUser || traffic[0].Upload <= 0 || traffic[0].Download <= 0 {
					t.Fatalf("traffic identity/counters invalid: %+v, %v", traffic, err)
				}
				if err = api.ReportUserTraffic(traffic); err != nil {
					t.Fatal(err)
				}
				online, err := lim.GetOnlineDevice()
				if err != nil || len(*online) == 0 {
					t.Fatalf("online identity missing: %v", err)
				}
				ips := map[int][]string{}
				for _, u := range *online {
					if u.UID != fixtureUser {
						t.Fatal("wrong online user")
					}
					ips[u.UID] = append(ips[u.UID], u.IP)
				}
				if err = api.ReportNodeOnlineUsers(&ips); err != nil {
					t.Fatal(err)
				}
				f.mu.Lock()
				storedTraffic := f.traffic[fixtureUser]
				storedIPs := f.online[fixtureUser]
				f.mu.Unlock()
				if len(storedTraffic) != 2 || storedTraffic[0] != traffic[0].Upload || storedTraffic[1] != traffic[0].Download || len(storedIPs) == 0 {
					t.Fatal("HTTP traffic/online report did not preserve identity and amounts")
				}
				t.Logf("domain block/release, traffic HTTP report up=%d down=%d and online HTTP report passed", traffic[0].Upload, traffic[0].Download)
				// A fresh client must not authenticate once eligibility has been removed.
				if err = c.DelUsers(users, tag, info); err != nil {
					t.Fatal(err)
				}
				lim.UpdateUser(tag, nil, users)
				a.UpdateUsers(nil)
				_, revoked := client(t, kind, info.Common.ServerPort, cert)
				if err = exchange(revoked, "tcp", tcpTarget); err == nil {
					t.Fatal("removed user still authenticates")
				}
				t.Log("fresh-client eligibility revocation passed")
			})
		}
	}
}
