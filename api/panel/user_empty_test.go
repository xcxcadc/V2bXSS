package panel

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/InazumaV/V2bX/conf"
)

func TestUserListEmptySnapshotDiffersFrom304(t *testing.T) {
	unchanged := false
	s := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if unchanged {
			w.WriteHeader(http.StatusNotModified)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"users":[]}`))
	}))
	defer s.Close()
	c, err := New(&conf.ApiConfig{APIHost: s.URL, Key: "test", NodeType: "hysteria2", NodeID: 1})
	if err != nil {
		t.Fatal(err)
	}
	users, err := c.GetUserList()
	if err != nil || users == nil || len(users) != 0 {
		t.Fatalf("empty snapshot must be nonnil: users=%v nil=%v err=%v", users, users == nil, err)
	}
	unchanged = true
	users, err = c.GetUserList()
	if err != nil || users != nil {
		t.Fatal("304 must mean no snapshot change")
	}
}
