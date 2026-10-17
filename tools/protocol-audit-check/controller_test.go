//go:build sing && xray && hysteria2 && with_quic

package protocolcheck

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/conf"
	"github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/limiter"
	"github.com/InazumaV/V2bX/node"
)

// Exercise the actual controller startup/poll/report path, rather than adding
// users directly to a core. Empty lists must reject auth, not stop the process.
type controllerPanel struct {
	fixturePanel
	nodeBody any
	users    []panel.UserInfo
	pulls    int
}

func (f *controllerPanel) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.URL.Query().Get("token") != "fixture-key" || r.URL.Query().Get("node_id") != "7" || r.URL.Query().Get("node_type") != f.kind {
		http.Error(w, "fixture auth rejected", 403)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	switch r.Method + " " + r.URL.Path {
	case "GET /api/v1/server/UniProxy/config":
		json.NewEncoder(w).Encode(f.nodeBody)
	case "GET /api/v1/server/UniProxy/user":
		f.mu.Lock()
		defer f.mu.Unlock()
		f.pulls++
		json.NewEncoder(w).Encode(panel.UserListBody{Users: f.users})
	case "GET /api/v1/server/UniProxy/alivelist":
		w.Write([]byte(`{"alive":{}}`))
	default:
		f.fixturePanel.ServeHTTP(w, r)
	}
}

func controllerFixture(t *testing.T, kind string, info *panel.NodeInfo) (*controllerPanel, *panel.Client, conf.ApiConfig) {
	t.Helper()
	common := *info.Common
	common.Routes = []panel.Route{}
	common.BaseConfig = &panel.BaseConfig{PushInterval: 1, PullInterval: 1}
	var body any
	switch kind {
	case "tuic":
		n := *info.Tuic
		n.CommonNode = common
		body = n
	case "hysteria2":
		n := *info.Hysteria2
		n.CommonNode = common
		body = n
	case "vmess":
		n := *info.VAllss
		n.CommonNode = common
		body = n
	default:
		t.Fatal("unsupported lifecycle fixture")
	}
	f := &controllerPanel{fixturePanel: fixturePanel{kind: kind}, nodeBody: body, users: []panel.UserInfo{}}
	f.policy("off", "", "")
	s := httptest.NewServer(f)
	t.Cleanup(s.Close)
	a := conf.ApiConfig{APIHost: s.URL, Key: "fixture-key", NodeType: kind, NodeID: 7}
	api, err := panel.New(&a)
	if err != nil {
		t.Fatal(err)
	}
	return f, api, a
}

func (f *controllerPanel) setEligible(eligible bool) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.users = []panel.UserInfo{}
	if eligible {
		f.users = []panel.UserInfo{{Id: fixtureUser, Uuid: fixtureUUID}}
	}
	return f.pulls
}

func (f *controllerPanel) waitPoll(t *testing.T, before int) {
	t.Helper()
	eventually(t, "controller fetched updated user snapshot", func() bool {
		f.mu.Lock()
		defer f.mu.Unlock()
		return f.pulls > before
	})
	// The response counter is incremented before the controller applies it.
	time.Sleep(150 * time.Millisecond)
}

func TestControllerEmptyUserLifecycle(t *testing.T) {
	for _, pair := range [][2]string{{"hysteria2", "hysteria2"}, {"sing", "tuic"}, {"xray", "vmess"}} {
		t.Run(pair[0]+"/"+pair[1], func(t *testing.T) {
			limiter.Init()
			cert, key := certificate(t)
			c, info, opts := serverNode(t, pair[1], pair[0], freePort(t), cert, key)
			f, api, _ := controllerFixture(t, pair[1], info)
			controller := node.NewController(c, api, opts)
			if err := controller.Start(); err != nil {
				t.Fatalf("zero-user controller must start: %v", err)
			}
			t.Cleanup(func() { controller.Close() })
			tcpTarget, udpTarget := echoTargets(t)
			probe, unauthorized := client(t, pair[1], info.Common.ServerPort, cert)
			if err := exchange(unauthorized, "tcp", tcpTarget); err == nil {
				t.Fatal("empty authorized list accepted a user")
			}
			probe.Close()
			f.waitPoll(t, f.setEligible(true))
			probe, authorized := client(t, pair[1], info.Common.ServerPort, cert)
			for network, target := range map[string]string{"tcp": tcpTarget, "udp": udpTarget} {
				if err := exchange(authorized, network, target); err != nil {
					t.Fatalf("newly eligible %s: %v", network, err)
				}
			}
			eventually(t, "automatic controller traffic/online HTTP report", func() bool {
				f.mu.Lock()
				defer f.mu.Unlock()
				traffic := f.traffic[fixtureUser]
				return len(traffic) == 2 && traffic[0] > 0 && traffic[1] > 0 && len(f.online[fixtureUser]) > 0
			})
			probe.Close()
			f.waitPoll(t, f.setEligible(false))
			probe, revoked := client(t, pair[1], info.Common.ServerPort, cert)
			if err := exchange(revoked, "tcp", tcpTarget); err == nil {
				t.Fatal("last revoked user still authenticates")
			}
			probe.Close()
			f.waitPoll(t, f.setEligible(true))
			_, restored := client(t, pair[1], info.Common.ServerPort, cert)
			if err := exchange(restored, "tcp", tcpTarget); err != nil {
				t.Fatalf("restored user without restarting controller: %v", err)
			}
			t.Log("empty start rejects auth; polling grants, revokes and restores; real TCP/UDP and automatic HTTP traffic/online reports passed")
		})
	}
}

func TestEmptyHY2DoesNotPreventTUICStartup(t *testing.T) {
	limiter.Init()
	cert, key := certificate(t)
	// Use one selector with both cores, as in the operator's two-node config.
	cc := []conf.CoreConfig{{Type: "hysteria2", Hysteria2Config: conf.NewHysteria2Config()}, {Type: "sing", SingConfig: conf.NewSingConfig()}}
	cc[1].SingConfig.NtpConfig.Enable = false
	c, err := core.NewCore(cc)
	if err != nil {
		t.Fatal(err)
	}
	if err = c.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	configs := []conf.NodeConfig{}
	var tuicPort int
	for _, pair := range [][2]string{{"hysteria2", "hysteria2"}, {"sing", "tuic"}} {
		port := freePort(t)
		common := panel.CommonNode{Host: "127.0.0.1", ServerPort: port, ServerName: "localhost"}
		info := &panel.NodeInfo{Common: &common, Hysteria2: &panel.Hysteria2Node{CommonNode: common}, Tuic: &panel.TuicNode{CommonNode: common, CongestionControl: "bbr"}}
		f, _, api := controllerFixture(t, pair[1], info)
		if pair[1] == "tuic" {
			tuicPort = port
			f.setEligible(true)
		}
		configs = append(configs, conf.NodeConfig{ApiConfig: api, Options: conf.Options{Core: pair[0], ListenIP: "127.0.0.1", SendIP: "0.0.0.0", CertConfig: &conf.CertConfig{CertMode: "file", CertDomain: "localhost", CertFile: cert, KeyFile: key}, SingOptions: conf.NewSingOptions()}})
	}
	nodes := node.New()
	if err = nodes.Start(configs, c); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(nodes.Close)
	tcp, udp := echoTargets(t)
	_, out := client(t, "tuic", tuicPort, cert)
	for network, target := range map[string]string{"tcp": tcp, "udp": udp} {
		if err = exchange(out, network, target); err != nil {
			t.Fatalf("TUIC behind empty HY2: %s: %v", network, err)
		}
	}
}
