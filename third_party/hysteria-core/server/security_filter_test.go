package server

import (
	"errors"
	"net"
	"testing"
)

type filterCall struct{ id, protocol, address string }
type testRequestFilter struct {
	calls            []filterCall
	blocked, version string
}

func (f *testRequestFilter) Version() string { return f.version }
func (f *testRequestFilter) CheckRequest(id, protocol, address string) error {
	f.calls = append(f.calls, filterCall{id, protocol, address})
	if address == f.blocked {
		return errors.New("test block")
	}
	return nil
}

type testFilterUDP struct{ writes []string }

func (c *testFilterUDP) ReadFrom([]byte) (int, string, error) { return 0, "", nil }
func (c *testFilterUDP) WriteTo(b []byte, address string) (int, error) {
	c.writes = append(c.writes, address)
	return len(b), nil
}
func (c *testFilterUDP) Close() error { return nil }

type testFilterOutbound struct {
	udp      *testFilterUDP
	dials    []string
	tcpDials int
}

func (o *testFilterOutbound) TCP(string) (net.Conn, error) {
	o.tcpDials++
	return nil, errors.New("test outbound sentinel")
}
func (o *testFilterOutbound) UDP(addr string) (UDPConn, error) {
	o.dials = append(o.dials, addr)
	return o.udp, nil
}

func TestAuthenticatedUDPFilterBlocksBeforeDialAndKeepsNilCompatibility(t *testing.T) {
	ob := &testFilterOutbound{udp: &testFilterUDP{}}
	io := &udpIOImpl{AuthID: "exact-user-42", Outbound: ob}
	c, err := io.UDP("allowed.test:443")
	if err != nil || c != ob.udp || len(ob.dials) != 1 {
		t.Fatal("nil filter changed upstream UDP path")
	}
	f := &testRequestFilter{blocked: "blocked.test:443"}
	io.RequestFilter = f
	if _, err := io.UDP("blocked.test:443"); err == nil {
		t.Fatal("blocked target dialed")
	}
	if len(ob.dials) != 1 {
		t.Fatal("blocked UDP reached outbound")
	}
	if f.calls[0] != (filterCall{"exact-user-42", "udp", "blocked.test:443"}) {
		t.Fatalf("lost identity %+v", f.calls)
	}
	c, err = io.UDP("allowed.test:443")
	if err != nil {
		t.Fatal(err)
	}
	if _, err = c.WriteTo([]byte("ok"), "allowed.test:443"); err != nil {
		t.Fatal(err)
	}
	if _, err = c.WriteTo([]byte("bad"), "blocked.test:443"); err == nil {
		t.Fatal("full-cone changed target bypassed filter")
	}
	if len(ob.udp.writes) != 1 {
		t.Fatal("blocked target received UDP")
	}
	if _, err = c.WriteTo([]byte("ok"), "other.test:443"); err != nil {
		t.Fatal(err)
	}
	if len(ob.udp.writes) != 2 || ob.udp.writes[1] != "other.test:443" {
		t.Fatal("allowed changed target not sent")
	}
	f.blocked = "other.test:443"
	f.version = "new-policy"
	if _, err = c.WriteTo([]byte("now blocked"), "other.test:443"); err == nil {
		t.Fatal("same UDP target bypassed updated rules")
	}
	if len(ob.udp.writes) != 2 {
		t.Fatal("updated blocked target received data")
	}
}

func TestAuthenticatedTCPFilterBlocksBeforeDialAndKeepsNilCompatibility(t *testing.T) {
	ob := &testFilterOutbound{}
	h := &h3sHandler{authID: "exact-user-42", config: &Config{Outbound: ob}}
	h.dialTargetTCP("allowed.test:443")
	if ob.tcpDials != 1 {
		t.Fatal("nil filter changed TCP outbound path")
	}
	f := &testRequestFilter{blocked: "blocked.test:443"}
	h.config.RequestFilter = f
	if _, err := h.dialTargetTCP("blocked.test:443"); err == nil {
		t.Fatal("TCP target not blocked")
	}
	if ob.tcpDials != 1 {
		t.Fatal("blocked TCP reached outbound")
	}
	if f.calls[0] != (filterCall{"exact-user-42", "tcp", "blocked.test:443"}) {
		t.Fatalf("lost TCP identity %+v", f.calls)
	}
	h.dialTargetTCP("allowed.test:443")
	if ob.tcpDials != 2 {
		t.Fatal("allowed TCP not forwarded")
	}
}
