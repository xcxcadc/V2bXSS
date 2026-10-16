package hy2

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"math/big"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/counter"
	"github.com/InazumaV/V2bX/common/format"
	"github.com/InazumaV/V2bX/conf"
	vCore "github.com/InazumaV/V2bX/core"
	"github.com/InazumaV/V2bX/limiter"
	"github.com/apernet/hysteria/core/v2/client"
	"github.com/apernet/hysteria/core/v2/server"
	"go.uber.org/zap"
)

func TestTrafficRevocationRejectsRemovedUser(t *testing.T) {
	limiter.Init()
	users := []panel.UserInfo{{Id: 7, Uuid: "revoked-user"}}
	l := limiter.AddLimiter("revoke-test", &conf.LimitConfig{}, users, make(map[int]int))
	defer limiter.DeleteLimiter("revoke-test")
	hook := &HookServer{Tag: "revoke-test", logger: zap.NewNop()}
	if !hook.LogTraffic("revoked-user", 100, 100) {
		t.Fatal("active user's traffic failed")
	}
	l.UpdateUser("revoke-test", nil, users)
	if hook.LogTraffic("revoked-user", 100, 100) {
		t.Fatal("removed user's old authenticated stream still passes traffic")
	}
}

func TestConcurrentNativeTrafficReportsPreserveEveryByte(t *testing.T) {
	limiter.Init()
	users := []panel.UserInfo{{Id: 7, Uuid: "count-user"}}
	limiter.AddLimiter("count-test", &conf.LimitConfig{}, users, make(map[int]int))
	defer limiter.DeleteLimiter("count-test")
	hook := &HookServer{Tag: "count-test", logger: zap.NewNop()}
	h := &Hysteria2{Hy2nodes: map[string]Hysteria2node{"count-test": {Auth: &V2bX{usersMap: map[string]int{"count-user": 7}}, TrafficLogger: hook}}}
	var writers sync.WaitGroup
	const workers, iterations = 8, 10000
	writers.Add(workers)
	for i := 0; i < workers; i++ {
		go func() {
			defer writers.Done()
			for j := 0; j < iterations; j++ {
				if !hook.LogTraffic("count-user", 1, 1) {
					panic("active traffic rejected")
				}
			}
		}()
	}
	done := make(chan struct{})
	go func() { writers.Wait(); close(done) }()
	var up, down int64
	for {
		traffic, err := h.GetUserTrafficSlice("count-test", true)
		if err != nil {
			t.Fatal(err)
		}
		for _, v := range traffic {
			up += v.Upload
			down += v.Download
		}
		select {
		case <-done:
			goto final
		default:
		}
	}
final:
	traffic, _ := h.GetUserTrafficSlice("count-test", true)
	for _, v := range traffic {
		up += v.Upload
		down += v.Download
	}
	if up != workers*iterations || down != workers*iterations {
		t.Fatalf("lost concurrent bytes: up=%d down=%d", up, down)
	}
}

func TestNativeRemovedUserDisconnectsExistingTCPUDPAndCannotReauthenticate(t *testing.T) {
	limiter.Init()
	const tag, uuid = "native-revoke-live", "test-native-uuid"
	users := []panel.UserInfo{{Id: 7, Uuid: uuid}}
	lim := limiter.AddLimiter(tag, &conf.LimitConfig{}, users, make(map[int]int))
	defer limiter.DeleteLimiter(tag)
	auth := &V2bX{usersMap: map[string]int{uuid: 7}}
	h := &Hysteria2{Hy2nodes: make(map[string]Hysteria2node)}
	hook := &HookServer{Tag: tag, logger: zap.NewNop()}
	filter := &auditRequestFilter{tag: tag, authorized: func(id string) bool {
		auth.mutex.RLock()
		_, ok := auth.usersMap[id]
		auth.mutex.RUnlock()
		_, assigned := lim.UserLimitInfo.Load(format.UserTag(tag, id))
		return ok && assigned
	}}
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	srv, err := server.NewServer(&server.Config{Conn: packet, TLSConfig: server.TLSConfig{Certificates: []tls.Certificate{revocationCert(t)}}, Authenticator: auth, TrafficLogger: hook, RequestFilter: filter})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	go srv.Serve()
	h.Hy2nodes[tag] = Hysteria2node{Auth: auth, Hy2server: srv, TrafficLogger: hook}
	tcp, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer tcp.Close()
	go func() {
		for {
			c, err := tcp.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); _, _ = io.Copy(c, c) }()
		}
	}()
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	go func() {
		data := make([]byte, 2048)
		for {
			n, addr, err := udp.ReadFrom(data)
			if err != nil {
				return
			}
			_, _ = udp.WriteTo(data[:n], addr)
		}
	}()
	cfg := &client.Config{ServerAddr: packet.LocalAddr(), Auth: uuid, TLSConfig: client.TLSConfig{ServerName: "revoke.test", InsecureSkipVerify: true}}
	cli, _, err := client.NewClient(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer cli.Close()
	stream, err := cli.TCP(tcp.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	_ = stream.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err = stream.Write([]byte("before")); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 6)
	if _, err = io.ReadFull(stream, reply); err != nil || string(reply) != "before" {
		t.Fatal("TCP baseline failed")
	}
	u, err := cli.UDP()
	if err != nil {
		t.Fatal(err)
	}
	defer u.Close()
	if err = u.Send([]byte("udp-before"), udp.LocalAddr().String()); err != nil {
		t.Fatal(err)
	}
	got := make(chan error, 1)
	go func() {
		p, _, err := u.Receive()
		if err == nil && string(p) != "udp-before" {
			err = io.ErrUnexpectedEOF
		}
		got <- err
	}()
	select {
	case err = <-got:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("UDP baseline timeout")
	}
	traffic, err := h.GetUserTrafficSlice(tag, true)
	if err != nil || len(traffic) != 1 || traffic[0].Upload <= 0 || traffic[0].Download <= 0 {
		t.Fatal("native counters not reported")
	}
	if err = h.DelUsers(users, tag, nil); err != nil {
		t.Fatal(err)
	}
	lim.UpdateUser(tag, nil, users)
	if filter.ValidateUser(uuid) || hook.LogTraffic(uuid, 1, 1) {
		t.Fatal("removed eligibility retained")
	}
	if err = filter.CheckRequest(uuid, "tcp", tcp.Addr().String()); err == nil {
		t.Fatal("new target on old session allowed")
	}
	_ = stream.SetDeadline(time.Now().Add(time.Second))
	_, writeErr := stream.Write([]byte("after"))
	if writeErr == nil {
		_, err = stream.Read(make([]byte, 5))
		if err == nil {
			t.Fatal("existing TCP stream survived revocation")
		}
	}
	udpClosed := make(chan error, 1)
	go func() { _, _, err := u.Receive(); udpClosed <- err }()
	select {
	case err = <-udpClosed:
		if err == nil {
			t.Fatal("existing UDP session survived revocation")
		}
	case <-time.After(time.Second):
		t.Fatal("UDP session was not actively closed")
	}
	if cli2, _, err := client.NewClient(cfg); err == nil {
		cli2.Close()
		t.Fatal("removed user reauthenticated")
	}
	if v, ok := hook.Counter.Load(tag); ok && v.(*counter.TrafficCounter).Len() != 0 {
		t.Fatal("removed user traffic counter retained")
	}
}

func TestNativeNodeAuthRevocationDoesNotAffectOtherNode(t *testing.T) {
	first := &V2bX{usersMap: make(map[string]int)}
	second := &V2bX{usersMap: make(map[string]int)}
	h := &Hysteria2{Hy2nodes: map[string]Hysteria2node{
		"first":  {Auth: first, TrafficLogger: &HookServer{}},
		"second": {Auth: second, TrafficLogger: &HookServer{}},
	}}
	users := []panel.UserInfo{{Id: 7, Uuid: "shared-user"}}
	for _, tag := range []string{"first", "second"} {
		if _, err := h.AddUsers(&vCore.AddUsersParams{Tag: tag, Users: users}); err != nil {
			t.Fatal(err)
		}
	}
	if err := h.DelUsers(users, "first", nil); err != nil {
		t.Fatal(err)
	}
	if ok, _ := first.Authenticate(nil, "shared-user", 0); ok {
		t.Fatal("revoked node still authenticates user")
	}
	if ok, _ := second.Authenticate(nil, "shared-user", 0); !ok {
		t.Fatal("revoking one node revoked another node's authorized user")
	}
}

func revocationCert(t *testing.T) tls.Certificate {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "revoke.test"}, DNSNames: []string{"revoke.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return tls.Certificate{Certificate: [][]byte{der}, PrivateKey: key}
}
