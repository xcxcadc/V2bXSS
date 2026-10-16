package node

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/task"
	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/limiter"
)

type snapshotCore struct {
	vCore.Core
	deleted []panel.UserInfo
}

func (s *snapshotCore) DelUsers(users []panel.UserInfo, _ string, _ *panel.NodeInfo) error {
	s.deleted = append(s.deleted, users...)
	return nil
}
func (*snapshotCore) AddUsers(p *vCore.AddUsersParams) (int, error)        { return len(p.Users), nil }
func (*snapshotCore) DelNode(string) error                                 { return nil }
func (*snapshotCore) AddNode(string, *panel.NodeInfo, *conf.Options) error { return nil }

func testSnapshotController(t *testing.T, nodeChanged bool) (*Controller, *snapshotCore) {
	t.Helper()
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/api/v1/server/UniProxy/config":
			if !nodeChanged {
				w.WriteHeader(http.StatusNotModified)
				return
			}
			_, _ = w.Write([]byte(`{"server_port":39001,"cipher":"aes-128-gcm","routes":[],"base_config":{"push_interval":9,"pull_interval":3}}`))
		case "/api/v1/server/UniProxy/user":
			_, _ = w.Write([]byte(`{"users":[]}`))
		case "/api/v1/server/UniProxy/alivelist":
			_, _ = w.Write([]byte(`{"alive":{}}`))
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(s.Close)
	api, err := panel.New(&conf.ApiConfig{APIHost: s.URL, Key: "test", NodeType: "shadowsocks", NodeID: 1})
	if err != nil {
		t.Fatal(err)
	}
	users := []panel.UserInfo{{Id: 7, Uuid: "final-user"}}
	limiter.Init()
	lim := limiter.AddLimiter("snapshot-test", &conf.LimitConfig{}, users, make(map[int]int))
	t.Cleanup(func() { limiter.DeleteLimiter("snapshot-test") })
	core := &snapshotCore{}
	c := &Controller{server: core, apiClient: api, tag: "snapshot-test", userList: users, limiter: lim,
		info: &panel.NodeInfo{Type: "shadowsocks"}, Options: &conf.Options{Name: "snapshot-test", CertConfig: conf.NewCertConfig()},
		nodeInfoMonitorPeriodic: &task.Task{Interval: 3 * time.Second, Execute: func() error { return nil }},
		userReportPeriodic:      &task.Task{Interval: time.Second, Execute: func() error { return nil }},
	}
	t.Cleanup(c.nodeInfoMonitorPeriodic.Close)
	t.Cleanup(c.userReportPeriodic.Close)
	return c, core
}

func TestEmptyUserSnapshotRemovesFinalUser(t *testing.T) {
	c, core := testSnapshotController(t, false)
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if len(core.deleted) != 1 || core.deleted[0].Id != 7 || len(c.userList) != 0 {
		t.Fatal("final expired/exhausted user survived empty snapshot")
	}
}

func TestReportCadenceUsesPushIntervalAfterNodeUpdate(t *testing.T) {
	c, _ := testSnapshotController(t, true)
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if c.userReportPeriodic.Interval != 9*time.Second {
		t.Fatalf("report uses %v, want push=9s", c.userReportPeriodic.Interval)
	}
}

func TestEmptySnapshotDuringNamedNodeReloadRevokesAuthAndLimiter(t *testing.T) {
	c, core := testSnapshotController(t, true)
	if err := c.nodeInfoMonitor(); err != nil {
		t.Fatal(err)
	}
	if len(core.deleted) != 1 || len(c.userList) != 0 {
		t.Fatal("reload retained removed auth identity")
	}
	count := 0
	c.limiter.UserLimitInfo.Range(func(_, _ any) bool { count++; return true })
	if count != 0 {
		t.Fatal("named node limiter retained removed users")
	}
}
