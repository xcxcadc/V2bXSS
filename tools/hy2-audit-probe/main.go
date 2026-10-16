// hy2-audit-probe is an isolated loopback test client, never a node service.
package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"io"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/apernet/hysteria/core/v2/client"
	coreerrors "github.com/apernet/hysteria/core/v2/errors"
)

type config struct {
	Server    string `json:"server"`
	Auth      string `json:"auth"`
	TimeoutMS int    `json:"timeout_ms"`
	TLS       struct {
		ServerName string `json:"server_name"`
		CAFile     string `json:"ca_file"`
		Insecure   bool   `json:"insecure_skip_verify"`
	} `json:"tls"`
}

type action struct {
	Phase     string `json:"phase"`
	Transport string `json:"transport"`
	Target    string `json:"target"`
	Expect    string `json:"expect"`
	Bytes     int    `json:"bytes"`
	Repeat    int    `json:"repeat"`
}

type result struct {
	Event                string `json:"event"`
	Phase                string `json:"phase,omitempty"`
	Transport            string `json:"transport,omitempty"`
	Expect               string `json:"expect,omitempty"`
	Outcome              string `json:"outcome,omitempty"`
	Success              bool   `json:"success"`
	SentBytes            int    `json:"sent_bytes"`
	ReceivedBytes        int    `json:"received_bytes"`
	ElapsedMS            int64  `json:"elapsed_ms"`
	RequiresRuleEvidence bool   `json:"requires_rule_evidence,omitempty"`
	Code                 string `json:"code,omitempty"`
}

func emit(v any) { _ = json.NewEncoder(os.Stdout).Encode(v) }

func fail(code string) {
	emit(result{Event: "error", Code: code})
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		fail("usage_echo_or_run_or_session_or_revocation")
	}
	if os.Args[1] == "echo" {
		echo(os.Args[2:])
		return
	}
	if os.Args[1] != "run" && os.Args[1] != "session" && os.Args[1] != "revocation" {
		fail("unknown_command")
	}
	fs := flag.NewFlagSet("probe", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	configPath := fs.String("config", "", "Private JSON config file")
	phase := fs.String("phase", "check", "Nonsecret phase label")
	transport := fs.String("transport", "tcp", "tcp or udp")
	target := fs.String("target", "127.0.0.1:38080", "Loopback echo target")
	expect := fs.String("expect", "allow", "allow or block")
	byteCount := fs.Int("bytes", 4096, "Payload bytes per exchange")
	repeat := fs.Int("repeat", 1, "Exchange count")
	if fs.Parse(os.Args[2:]) != nil || *configPath == "" {
		fail("invalid_arguments")
	}
	cfg, err := readConfig(*configPath)
	if err != nil {
		fail(err.Error())
	}
	if os.Args[1] == "revocation" {
		if !loopbackEndpoint(*target) {
			fail("revocation_requires_loopback_echo")
		}
		if !runRevocation(cfg, *target, os.Stdin, emit) {
			os.Exit(1)
		}
		return
	}
	c, udpEnabled, err := connect(cfg)
	if err != nil {
		fail(err.Error())
	}
	defer c.Close()
	emit(map[string]any{"event": "authenticated", "success": true, "udp_enabled": udpEnabled, "tls_verified": !cfg.TLS.Insecure})
	state := &probeState{c: c, timeout: time.Duration(cfg.TimeoutMS) * time.Millisecond}
	defer state.closeUDP()
	failed := false
	if os.Args[1] == "run" {
		r := state.execute(action{Phase: *phase, Transport: *transport, Target: *target, Expect: *expect, Bytes: *byteCount, Repeat: *repeat})
		emit(r)
		failed = !r.Success
	} else {
		// Reuses authenticated QUIC and UDP sessions for policy hot-update tests.
		// Caller updates policy separately and sends the next JSON action after
		// the node has acknowledged its new version. The probe never edits policy.
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 4096), 16384)
		for scanner.Scan() {
			if strings.TrimSpace(scanner.Text()) == "" {
				continue
			}
			var a action
			if err := json.Unmarshal(scanner.Bytes(), &a); err != nil {
				emit(result{Event: "result", Code: "invalid_action_json"})
				failed = true
				continue
			}
			r := state.execute(a)
			emit(r)
			failed = failed || !r.Success
		}
		if scanner.Err() != nil {
			fail("action_input_failed")
		}
	}
	if failed {
		os.Exit(1)
	}
}

func readConfig(path string) (config, error) {
	var c config
	f, err := os.Open(path)
	if err != nil {
		return c, errors.New("config_open_failed")
	}
	defer f.Close()
	if err = json.NewDecoder(io.LimitReader(f, 65536)).Decode(&c); err != nil {
		return c, errors.New("config_json_invalid")
	}
	if !loopbackEndpoint(c.Server) || len(c.Auth) == 0 || len(c.Auth) > 4096 {
		return c, errors.New("config_requires_loopback_server_and_auth")
	}
	if c.TimeoutMS == 0 {
		c.TimeoutMS = 5000
	}
	if c.TimeoutMS < 500 || c.TimeoutMS > 30000 {
		return c, errors.New("timeout_out_of_range")
	}
	if c.TLS.ServerName == "" {
		return c, errors.New("tls_server_name_required")
	}
	return c, nil
}

type packetFactory struct {
	mu   sync.Mutex
	conn net.PacketConn
}

func (p *packetFactory) New(addr net.Addr) (net.PacketConn, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	listen := "127.0.0.1:0"
	if remote, ok := addr.(*net.UDPAddr); ok && remote.IP.To4() == nil {
		listen = "[::1]:0"
	}
	c, err := net.ListenPacket("udp", listen)
	p.conn = c
	return c, err
}
func (p *packetFactory) close() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.conn != nil {
		_ = p.conn.Close()
	}
}

func connect(c config) (client.Client, bool, error) {
	addr, err := net.ResolveUDPAddr("udp", c.Server)
	if err != nil {
		return nil, false, errors.New("server_address_invalid")
	}
	tls := client.TLSConfig{ServerName: c.TLS.ServerName, InsecureSkipVerify: c.TLS.Insecure}
	if c.TLS.CAFile != "" {
		data, err := os.ReadFile(c.TLS.CAFile)
		if err != nil {
			return nil, false, errors.New("ca_read_failed")
		}
		tls.RootCAs = x509.NewCertPool()
		if !tls.RootCAs.AppendCertsFromPEM(data) {
			return nil, false, errors.New("ca_pem_invalid")
		}
	}
	pf := &packetFactory{}
	completed := make(chan struct{})
	timer := time.AfterFunc(time.Duration(c.TimeoutMS)*time.Millisecond, func() {
		select {
		case <-completed:
		default:
			pf.close()
		}
	})
	defer timer.Stop()
	cli, info, err := client.NewClient(&client.Config{ServerAddr: addr, Auth: c.Auth, TLSConfig: tls, ConnFactory: pf})
	close(completed)
	if err != nil {
		var authErr coreerrors.AuthError
		if errors.As(err, &authErr) {
			return nil, false, errors.New("authentication_rejected")
		}
		return nil, false, errors.New("handshake_failed")
	}
	return cli, info.UDPEnabled, nil
}

func loopbackEndpoint(value string) bool {
	host, portText, err := net.SplitHostPort(value)
	if err != nil {
		return false
	}
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 {
		return false
	}
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

type probeState struct {
	c       client.Client
	udp     client.HyUDPConn
	timeout time.Duration
}

func (s *probeState) closeUDP() {
	if s.udp != nil {
		_ = s.udp.Close()
		s.udp = nil
	}
}

func (s *probeState) execute(a action) result {
	started := time.Now()
	r := result{Event: "result", Phase: a.Phase, Transport: a.Transport, Expect: a.Expect}
	if len(a.Phase) > 80 || strings.ContainsAny(a.Phase, "\r\n\t") || !loopbackEndpoint(a.Target) || (a.Transport != "tcp" && a.Transport != "udp") || (a.Expect != "allow" && a.Expect != "block") {
		r.Code = "invalid_action"
		return r
	}
	if a.Bytes == 0 {
		a.Bytes = 4096
	}
	if a.Repeat == 0 {
		a.Repeat = 1
	}
	if a.Bytes < 1 || a.Bytes > 1048576 || a.Repeat < 1 || a.Repeat > 100 || (a.Transport == "udp" && a.Bytes > 1200) {
		r.Code = "payload_or_repeat_out_of_range"
		return r
	}
	for i := 0; i < a.Repeat; i++ {
		payload := make([]byte, a.Bytes)
		if _, err := rand.Read(payload); err != nil {
			r.Code = "payload_generation_failed"
			return r
		}
		var outcome string
		var sent, received int
		if a.Transport == "tcp" {
			outcome, sent, received = s.tcp(a.Target, payload)
		} else {
			outcome, sent, received = s.datagram(a.Target, payload)
		}
		r.Outcome = outcome
		r.SentBytes += sent
		r.ReceivedBytes += received
		if a.Expect == "allow" && outcome != "echo_verified" || a.Expect == "block" && outcome != "audit_rejected" && outcome != "no_response" {
			r.ElapsedMS = time.Since(started).Milliseconds()
			return r
		}
		if outcome == "no_response" {
			// UDP has no per-target rejection response. Only corroborating node
			// audit evidence plus a working baseline establish policy blocking.
			r.RequiresRuleEvidence = true
		}
	}
	r.Success = true
	r.ElapsedMS = time.Since(started).Milliseconds()
	return r
}

func (s *probeState) tcp(target string, payload []byte) (string, int, int) {
	type completed struct {
		conn net.Conn
		err  error
	}
	ch := make(chan completed, 1)
	go func() { conn, err := s.c.TCP(target); ch <- completed{conn, err} }()
	var c net.Conn
	select {
	case done := <-ch:
		if done.err != nil {
			var dial coreerrors.DialError
			if errors.As(done.err, &dial) && dial.Message == "target rejected by security rule" {
				return "audit_rejected", 0, 0
			}
			return "connect_failed", 0, 0
		}
		c = done.conn
	case <-time.After(s.timeout):
		_ = s.c.Close()
		return "connect_timeout", 0, 0
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(s.timeout))
	sent64, err := io.Copy(c, bytes.NewReader(payload))
	sent := int(sent64)
	if err != nil || sent != len(payload) {
		return "write_failed", sent, 0
	}
	reply := make([]byte, len(payload))
	received, err := io.ReadFull(c, reply)
	if err != nil {
		return "read_failed", sent, received
	}
	if !bytes.Equal(payload, reply) {
		return "payload_mismatch", sent, received
	}
	return "echo_verified", sent, received
}

func (s *probeState) datagram(target string, payload []byte) (string, int, int) {
	if s.udp == nil {
		var err error
		s.udp, err = s.c.UDP()
		if err != nil {
			return "udp_unavailable", 0, 0
		}
	}
	if err := s.udp.Send(payload, target); err != nil {
		s.closeUDP()
		return "send_failed", 0, 0
	}
	type completed struct {
		data []byte
		err  error
	}
	ch := make(chan completed, 1)
	u := s.udp
	go func() { data, _, err := u.Receive(); ch <- completed{data, err} }()
	select {
	case done := <-ch:
		if done.err != nil {
			s.closeUDP()
			return "receive_failed", len(payload), 0
		}
		if !bytes.Equal(payload, done.data) {
			return "payload_mismatch", len(payload), len(done.data)
		}
		return "echo_verified", len(payload), len(done.data)
	case <-time.After(s.timeout):
		s.closeUDP() // unblock the pending receiver; QUIC remains authenticated
		return "no_response", len(payload), 0
	}
}

func echo(args []string) {
	fs := flag.NewFlagSet("echo", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	listen := fs.String("listen", "127.0.0.1:38080", "Loopback TCP and UDP listener")
	if fs.Parse(args) != nil || !loopbackEndpoint(*listen) {
		fail("echo_requires_loopback_listener")
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		fail("echo_tcp_listen_failed")
	}
	defer listener.Close()
	packet, err := net.ListenPacket("udp", *listen)
	if err != nil {
		fail("echo_udp_listen_failed")
	}
	defer packet.Close()
	var tcpBytes, udpBytes, tcpConnections, udpDatagrams atomic.Int64
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			tcpConnections.Add(1)
			go func() {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(30 * time.Minute))
				n, _ := io.Copy(conn, io.LimitReader(conn, 100<<20))
				tcpBytes.Add(n)
			}()
		}
	}()
	go func() {
		data := make([]byte, 65535)
		for {
			n, addr, err := packet.ReadFrom(data)
			if err != nil {
				return
			}
			udpDatagrams.Add(1)
			written, err := packet.WriteTo(data[:n], addr)
			if err == nil {
				udpBytes.Add(int64(written))
			}
		}
	}()
	emit(map[string]any{"event": "echo_ready", "success": true, "listen": *listen, "transports": []string{"tcp", "udp"}})
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, os.Interrupt)
	<-stop
	emit(map[string]any{"event": "echo_summary", "tcp_connections": tcpConnections.Load(), "tcp_bytes": tcpBytes.Load(), "udp_datagrams": udpDatagrams.Load(), "udp_bytes": udpBytes.Load()})
}
