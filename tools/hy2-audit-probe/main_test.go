package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"errors"
	"io"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync/atomic"
	"testing"
	"time"

	"github.com/apernet/hysteria/core/v2/server"
	"github.com/apernet/hysteria/extras/v2/obfs"
)

type testAuth struct{}

func (testAuth) Authenticate(_ net.Addr, auth string, _ uint64) (bool, string) {
	return auth == "local-test-auth", "test-user"
}

type testFilter struct {
	mode atomic.Int32
	hits atomic.Int64
}

func (f *testFilter) Version() string { return strconv.Itoa(int(f.mode.Load())) }
func (f *testFilter) CheckRequest(id, _, _ string) error {
	if id != "test-user" {
		return errors.New("test identity lost")
	}
	f.hits.Add(1)
	if f.mode.Load() == 2 {
		return errors.New("target rejected by security rule")
	}
	return nil
}

func TestProbeRejectsNonLoopbackTargets(t *testing.T) {
	for _, addr := range []string{"192.0.2.1:80", "example.test:80", "127.0.0.1:0", "127.0.0.1", "127.0.0.1:65536"} {
		if loopbackEndpoint(addr) {
			t.Fatalf("accepted nonlocal/invalid endpoint %q", addr)
		}
	}
	for _, addr := range []string{"127.0.0.1:80", "[::1]:80", "localhost:80"} {
		if !loopbackEndpoint(addr) {
			t.Fatalf("rejected loopback endpoint %q", addr)
		}
	}
}

func TestNativeProbeAllowedObservedBlockedHotRestoredTCPUDP(t *testing.T) {
	testNativeProbe(t, "")
}

func TestNativeProbeSalamanderAllowedObservedBlockedHotRestoredTCPUDP(t *testing.T) {
	testNativeProbe(t, "fixture-obfs-password")
}

func testNativeProbe(t *testing.T, password string) {
	cert, caPath := testCert(t)
	packet, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	if password != "" {
		obfuscator, err := obfs.NewSalamanderObfuscator([]byte(password))
		if err != nil {
			t.Fatal(err)
		}
		packet = obfs.WrapPacketConn(packet, obfuscator)
	}
	filter := &testFilter{}
	srv, err := server.NewServer(&server.Config{Conn: packet, TLSConfig: server.TLSConfig{Certificates: []tls.Certificate{cert}}, Authenticator: testAuth{}, RequestFilter: filter})
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
	cfg := config{Server: packet.LocalAddr().String(), Auth: "local-test-auth", TimeoutMS: 2000, Obfs: password}
	cfg.TLS.ServerName, cfg.TLS.CAFile = "probe.test", caPath
	cli, udpEnabled, err := connect(cfg)
	if err != nil || !udpEnabled {
		t.Fatalf("handshake err=%v UDP=%v", err, udpEnabled)
	}
	defer cli.Close()
	state := &probeState{c: cli, timeout: 500 * time.Millisecond}
	defer state.closeUDP()
	for _, phase := range []struct {
		name   string
		mode   int32
		expect string
	}{{"baseline", 0, "allow"}, {"observe", 1, "allow"}, {"blocked", 2, "block"}, {"restored", 3, "allow"}} {
		filter.mode.Store(phase.mode)
		for _, proto := range []string{"tcp", "udp"} {
			target, size := tcp.Addr().String(), 65536
			if proto == "udp" {
				target, size = udp.LocalAddr().String(), 1000
			}
			r := state.execute(action{Phase: phase.name, Transport: proto, Target: target, Expect: phase.expect, Bytes: size, Repeat: 1})
			if !r.Success {
				t.Fatalf("phase=%s proto=%s result=%+v", phase.name, proto, r)
			}
			if phase.expect == "allow" && (r.SentBytes != size || r.ReceivedBytes != size) {
				t.Fatal("transferred byte count mismatch")
			}
			if phase.expect == "block" && proto == "tcp" && r.Outcome != "audit_rejected" {
				t.Fatal("TCP failure was not an explicit audit rejection")
			}
			if phase.expect == "block" && proto == "udp" && !r.RequiresRuleEvidence {
				t.Fatal("UDP timeout must require corroborating rule evidence")
			}
		}
	}
	if filter.hits.Load() < 8 {
		t.Fatalf("missing filter checks %d", filter.hits.Load())
	}
}

func testCert(t *testing.T) (tls.Certificate, string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "probe.test"}, DNSNames: []string{"probe.test"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), KeyUsage: x509.KeyUsageDigitalSignature | x509.KeyUsageCertSign, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, IsCA: true, BasicConstraintsValid: true}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "ca.crt")
	if err := os.WriteFile(path, certPEM, 0600); err != nil {
		t.Fatal(err)
	}
	return cert, path
}
