package main

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"time"

	"github.com/apernet/hysteria/core/v2/client"
	coreerrors "github.com/apernet/hysteria/core/v2/errors"
	"github.com/apernet/quic-go"
)

type revocationResult struct {
	Event               string         `json:"event"`
	Phase               string         `json:"phase"`
	Success             bool           `json:"success"`
	Code                string         `json:"code,omitempty"`
	ExistingTCPRevoked  bool           `json:"existing_tcp_revoked"`
	ExistingUDPRevoked  bool           `json:"existing_udp_revoked"`
	ExistingQUICRevoked bool           `json:"existing_quic_revoked"`
	FreshAuthRejected   bool           `json:"fresh_auth_rejected"`
	FreshAuthRestored   bool           `json:"fresh_auth_restored"`
	TCPDetail           *closureDetail `json:"tcp_detail,omitempty"`
	UDPDetail           *closureDetail `json:"udp_detail,omitempty"`
	QUICDetail          *closureDetail `json:"quic_detail,omitempty"`
	AuthDetail          string         `json:"auth_detail,omitempty"`
	SentBytes           int            `json:"sent_bytes"`
	ReceivedBytes       int            `json:"received_bytes"`
	ElapsedMS           int64          `json:"elapsed_ms"`
}

type revocationState struct {
	cfg                      config
	target                   string
	cli                      client.Client
	tcp                      net.Conn
	udp                      client.HyUDPConn
	ready, revoked, restored bool
	udpPending               chan error
	udpClosure               error
}

func (s *revocationState) close() {
	if s.tcp != nil {
		_ = s.tcp.Close()
	}
	if s.udp != nil {
		_ = s.udp.Close()
	}
	if s.cli != nil {
		_ = s.cli.Close()
	}
}

func runRevocation(cfg config, target string, input io.Reader, output func(any)) bool {
	s := &revocationState{cfg: cfg, target: target}
	defer s.close()
	output(map[string]any{"event": "revocation_ready", "success": true, "stages": []string{"baseline", "revoked", "restored"}})
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 1024), 4096)
	failed := false
	for scanner.Scan() {
		if strings.TrimSpace(scanner.Text()) == "" {
			continue
		}
		var command struct {
			Phase string `json:"phase"`
		}
		if json.Unmarshal(scanner.Bytes(), &command) != nil {
			output(revocationResult{Event: "revocation", Code: "invalid_command_json"})
			failed = true
			continue
		}
		if command.Phase == "finish" {
			break
		}
		r := s.execute(command.Phase)
		output(r)
		failed = failed || !r.Success
	}
	if scanner.Err() != nil {
		output(revocationResult{Event: "revocation", Code: "command_read_failed"})
		return false
	}
	complete := !failed && s.ready && s.revoked && s.restored
	output(map[string]any{"event": "revocation_summary", "success": complete, "baseline_passed": s.ready, "revocation_passed": s.revoked, "restoration_passed": s.restored})
	return complete
}

func (s *revocationState) execute(phase string) revocationResult {
	started := time.Now()
	r := revocationResult{Event: "revocation", Phase: phase}
	switch phase {
	case "baseline":
		if s.revoked || s.restored {
			r.Code = "invalid_stage_order"
			break
		}
		if s.cli == nil {
			cli, udp, err := connect(s.cfg)
			if err != nil {
				r.Code = err.Error()
				break
			}
			s.cli = cli
			if !udp {
				r.Code = "udp_not_enabled"
				break
			}
			tcp, err := cli.TCP(s.target)
			if err != nil {
				r.Code = "baseline_tcp_connect_failed"
				break
			}
			s.tcp = tcp
			u, err := cli.UDP()
			if err != nil {
				r.Code = "baseline_udp_open_failed"
				break
			}
			s.udp = u
		}
		if s.tcp == nil || s.udp == nil {
			r.Code = "baseline_incomplete_restart_required"
			break
		}
		if !s.echoHeld(&r) {
			break
		}
		s.ready = true
		r.Success = true
	case "revoked":
		if !s.ready || s.revoked || s.restored {
			r.Code = "working_baseline_required"
			break
		}
		timeout := time.Duration(s.cfg.TimeoutMS) * time.Millisecond
		// A timeout or audit target rejection is never proof of account
		// revocation. Require the remote native account-close code 0x107.
		_ = s.tcp.SetReadDeadline(time.Now().Add(timeout))
		_, err := s.tcp.Read(make([]byte, 1))
		r.ExistingTCPRevoked = accountClosure(err)
		r.TCPDetail = describeClosure(err)
		_ = s.tcp.SetReadDeadline(time.Time{})
		if s.udpClosure == nil {
			if s.udpPending == nil {
				s.udpPending = make(chan error, 1)
				go func(ch chan error) { _, _, err := s.udp.Receive(); ch <- err }(s.udpPending)
			}
			select {
			case err = <-s.udpPending:
				s.udpPending = nil
				s.udpClosure = err
				r.UDPDetail = describeClosure(err)
			case <-time.After(timeout):
				r.UDPDetail = &closureDetail{Category: "timeout_waiting_udp_close"}
			}
		} else {
			r.UDPDetail = describeClosure(s.udpClosure)
		}
		r.ExistingUDPRevoked = s.udpClosure != nil
		type attempt struct {
			conn net.Conn
			err  error
		}
		newStream := make(chan attempt, 1)
		go func() { c, err := s.cli.TCP(s.target); newStream <- attempt{c, err} }()
		select {
		case a := <-newStream:
			if a.conn != nil {
				_ = a.conn.Close()
			}
			r.ExistingQUICRevoked = accountClosure(a.err)
			r.QUICDetail = describeClosure(a.err)
		case <-time.After(timeout):
			r.QUICDetail = &closureDetail{Category: "timeout_opening_old_quic_stream"}
		}
		fresh, _, authErr := connect(s.cfg)
		if fresh != nil {
			_ = fresh.Close()
		}
		r.FreshAuthRejected = authErr != nil && authErr.Error() == "authentication_rejected"
		if authErr == nil {
			r.AuthDetail = "authentication_succeeded"
		} else {
			r.AuthDetail = authErr.Error()
		}
		r.Success = r.ExistingTCPRevoked && r.ExistingUDPRevoked && r.ExistingQUICRevoked && r.FreshAuthRejected
		if !r.Success {
			r.Code = "revocation_not_proven_restart_baseline_after_sync"
		} else {
			s.revoked = true
		}
	case "restored":
		if !s.revoked || s.restored {
			r.Code = "proven_revocation_required"
			break
		}
		cli, udp, err := connect(s.cfg)
		if err != nil {
			r.Code = err.Error()
			break
		}
		defer cli.Close()
		if !udp {
			r.Code = "udp_not_enabled"
			break
		}
		state := &probeState{c: cli, timeout: time.Duration(s.cfg.TimeoutMS) * time.Millisecond}
		defer state.closeUDP()
		for _, proto := range []string{"tcp", "udp"} {
			n := 4096
			if proto == "udp" {
				n = 1000
			}
			echo := state.execute(action{Phase: "restore", Transport: proto, Target: s.target, Expect: "allow", Bytes: n})
			r.SentBytes += echo.SentBytes
			r.ReceivedBytes += echo.ReceivedBytes
			if !echo.Success {
				r.Code = "restored_" + proto + "_echo_failed"
				break
			}
		}
		if r.Code == "" {
			r.Success = true
			r.FreshAuthRestored = true
			s.restored = true
		}
	default:
		r.Code = "stage_must_be_baseline_revoked_or_restored"
	}
	r.ElapsedMS = time.Since(started).Milliseconds()
	return r
}

func (s *revocationState) echoHeld(r *revocationResult) bool {
	payload := make([]byte, 4096)
	if _, err := rand.Read(payload); err != nil {
		r.Code = "random_failed"
		return false
	}
	_ = s.tcp.SetDeadline(time.Now().Add(time.Duration(s.cfg.TimeoutMS) * time.Millisecond))
	n, err := io.Copy(s.tcp, bytes.NewReader(payload))
	r.SentBytes += int(n)
	if err != nil {
		r.Code = "baseline_tcp_write_failed"
		return false
	}
	reply := make([]byte, len(payload))
	received, err := io.ReadFull(s.tcp, reply)
	r.ReceivedBytes += received
	if err != nil || !bytes.Equal(payload, reply) {
		r.Code = "baseline_tcp_echo_failed"
		return false
	}
	_ = s.tcp.SetDeadline(time.Time{})
	payload = payload[:1000]
	if err = s.udp.Send(payload, s.target); err != nil {
		r.Code = "baseline_udp_send_failed"
		return false
	}
	r.SentBytes += len(payload)
	type response struct {
		data []byte
		err  error
	}
	done := make(chan response, 1)
	go func() { data, _, err := s.udp.Receive(); done <- response{data, err} }()
	select {
	case got := <-done:
		r.ReceivedBytes += len(got.data)
		if got.err != nil || !bytes.Equal(payload, got.data) {
			r.Code = "baseline_udp_echo_failed"
			return false
		}
	case <-time.After(time.Duration(s.cfg.TimeoutMS) * time.Millisecond):
		r.Code = "baseline_udp_timeout"
		return false
	}
	return true
}

func accountClosure(err error) bool {
	var application *quic.ApplicationError
	return err != nil && errors.As(err, &application) && application.Remote && application.ErrorCode == 0x107
}

type closureDetail struct {
	Category        string `json:"category"`
	Remote          bool   `json:"remote"`
	ApplicationCode uint64 `json:"application_code"`
	StreamCode      uint64 `json:"stream_code"`
}

// Return only known categories/codes; raw errors may contain hostnames or auth.
func describeClosure(err error) *closureDetail {
	d := &closureDetail{Category: "no_error"}
	if err == nil {
		return d
	}
	var application *quic.ApplicationError
	if errors.As(err, &application) {
		d.Category = "quic_application_close"
		d.Remote = application.Remote
		d.ApplicationCode = uint64(application.ErrorCode)
		return d
	}
	var stream *quic.StreamError
	if errors.As(err, &stream) {
		d.Category = "quic_stream_reset"
		d.Remote = stream.Remote
		d.StreamCode = uint64(stream.ErrorCode)
		return d
	}
	var network net.Error
	if errors.As(err, &network) && network.Timeout() {
		d.Category = "timeout"
		return d
	}
	if errors.Is(err, io.EOF) {
		d.Category = "eof"
		return d
	}
	if errors.Is(err, net.ErrClosed) {
		d.Category = "local_socket_closed"
		return d
	}
	var dial coreerrors.DialError
	if errors.As(err, &dial) {
		d.Category = "target_dial_rejected"
		if dial.Message == "target rejected by security rule" {
			d.Category = "target_audit_rejected"
		}
		return d
	}
	var closed coreerrors.ClosedError
	if errors.As(err, &closed) {
		d.Category = "hy2_connection_closed"
		return d
	}
	d.Category = "other_error"
	return d
}
