package hy2

import (
	"errors"
	"net"
	"strconv"

	"github.com/InazumaV/V2bX/limiter"
	"github.com/InazumaV/V2bX/securityaudit"
	"github.com/apernet/hysteria/core/v2/server"
)

var _ server.RequestFilter = (*auditRequestFilter)(nil)

type auditRequestFilter struct {
	tag        string
	authorized func(string) bool
}

func (f *auditRequestFilter) Version() string {
	version := securityaudit.Version(f.tag)
	if l, err := limiter.GetLimiter(f.tag); err == nil {
		if local := l.LocalRuleVersion(); local != "" {
			return version + ":local:" + local
		}
	}
	return version
}

func (f *auditRequestFilter) ValidateUser(id string) bool {
	return f.authorized == nil || f.authorized(id)
}

func (f *auditRequestFilter) CheckRequest(id, transport, reqAddr string) error {
	if !f.ValidateUser(id) {
		return errors.New("user no longer authorized")
	}
	host, portText, err := net.SplitHostPort(reqAddr)
	if err != nil {
		return nil
	} // keep the existing outbound's validation behavior
	port, err := strconv.ParseUint(portText, 10, 16)
	if err != nil || port == 0 {
		return nil
	}
	// Native Hysteria exposes the requested host/IP and authenticated UUID.
	// It does not supply a detected app protocol; never label UDP as QUIC.
	if securityaudit.Check(f.tag, id, host, uint16(port), "") {
		return errors.New("target rejected by security rule")
	}
	if l, err := limiter.GetLimiter(f.tag); err == nil && l.CheckLocalDomainRule(host) {
		return errors.New("target rejected by local domain rule")
	}
	return nil
}
