package main

import (
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"sync/atomic"
	"testing"

	coreerrors "github.com/apernet/hysteria/core/v2/errors"
	"github.com/apernet/hysteria/core/v2/server"
	"github.com/apernet/quic-go"
)

type mutableAuth struct{ active atomic.Bool }

func (a *mutableAuth) Authenticate(_ net.Addr, auth string, _ uint64) (bool, string) {
	return a.active.Load() && auth == "local-test-auth", "test-user"
}

func TestRevocationDiagnosticsShowFalseAndOnlySafeClosureCategories(t *testing.T) {
	encoded, err := json.Marshal(revocationResult{Event: "revocation", Phase: "revoked"})
	if err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"existing_tcp_revoked", "existing_udp_revoked", "existing_quic_revoked", "fresh_auth_rejected"} {
		if !strings.Contains(string(encoded), `"`+field+`":false`) {
			t.Fatalf("false boolean hidden: %s", field)
		}
	}
	d := describeClosure(&quic.ApplicationError{Remote: true, ErrorCode: 0x107, ErrorMessage: "secret-target.invalid"})
	if d.Category != "quic_application_close" || !d.Remote || d.ApplicationCode != 263 {
		t.Fatal("account close code lost")
	}
	diagnostic, _ := json.Marshal(d)
	if strings.Contains(string(diagnostic), "secret") {
		t.Fatal("raw message leaked")
	}
	if describeClosure(io.EOF).Category != "eof" || describeClosure(coreerrors.DialError{Message: "target rejected by security rule"}).Category != "target_audit_rejected" {
		t.Fatal("safe failure diagnosis lost")
	}
}

func TestAccountClosureRequiresRemoteQuotaCode(t *testing.T) {
	if !accountClosure(&quic.ApplicationError{Remote: true, ErrorCode: 0x107}) {
		t.Fatal("quota closure not recognized")
	}
	for _, err := range []error{nil, errors.New("timeout"), io.EOF, coreerrors.DialError{Message: "target rejected by security rule"}, &quic.ApplicationError{Remote: true, ErrorCode: 0x100}, &quic.ApplicationError{Remote: false, ErrorCode: 0x107}} {
		if accountClosure(err) {
			t.Fatal("unrelated failure misclassified as quota revocation")
		}
	}
}

func TestRevocationProbeRequiresBaselineRejectsFalsePositiveAndVerifiesRecovery(t *testing.T) {
	cert, caPath := testCert(t)
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	auth := &mutableAuth{}
	auth.active.Store(true)
	srv, err := server.NewServer(&server.Config{Conn: packet, TLSConfig: server.TLSConfig{Certificates: []tls.Certificate{cert}}, Authenticator: auth})
	if err != nil {
		t.Fatal(err)
	}
	defer srv.Close()
	go srv.Serve()
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
	udp, err := net.ListenPacket("udp", tcp.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	go func() {
		buf := make([]byte, 2048)
		for {
			n, addr, err := udp.ReadFrom(buf)
			if err != nil {
				return
			}
			_, _ = udp.WriteTo(buf[:n], addr)
		}
	}()
	cfg := config{Server: packet.LocalAddr().String(), Auth: "local-test-auth", TimeoutMS: 500}
	cfg.TLS.ServerName, cfg.TLS.CAFile = "probe.test", caPath
	bad := &revocationState{cfg: cfg, target: tcp.Addr().String()}
	if r := bad.execute("revoked"); r.Success || r.Code != "working_baseline_required" {
		t.Fatal("no-baseline check passed")
	}
	if r := bad.execute("baseline"); !r.Success {
		t.Fatalf("negative test baseline failed: %+v", r)
	}
	if r := bad.execute("revoked"); r.Success || r.ExistingTCPRevoked || r.ExistingQUICRevoked || r.FreshAuthRejected {
		t.Fatalf("active account misclassified revoked: %+v", r)
	}
	bad.close()
	state := &revocationState{cfg: cfg, target: tcp.Addr().String()}
	defer state.close()
	for i := 0; i < 2; i++ {
		if r := state.execute("baseline"); !r.Success || r.SentBytes != 5096 || r.ReceivedBytes != 5096 {
			t.Fatalf("held baseline failed %+v", r)
		}
	}
	auth.active.Store(false)
	srv.(interface{ DisconnectUser(string) }).DisconnectUser("test-user")
	if r := state.execute("revoked"); !r.Success || !r.ExistingTCPRevoked || !r.ExistingUDPRevoked || !r.ExistingQUICRevoked || !r.FreshAuthRejected {
		t.Fatalf("real revocation failed %+v", r)
	}
	auth.active.Store(true)
	if r := state.execute("restored"); !r.Success || !r.FreshAuthRestored || r.SentBytes != 5096 || r.ReceivedBytes != 5096 {
		t.Fatalf("recovery failed %+v", r)
	}
}
