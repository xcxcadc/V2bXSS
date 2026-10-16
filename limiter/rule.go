package limiter

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"

	"github.com/InazumaV/V2bX/api/panel"
)

// Every domain check observes one complete, immutable policy across both sources.
type nativeRuleSnapshot struct {
	panel, local []*regexp.Regexp
	protocols    []string
	localVersion string
}

func matches(rules []*regexp.Regexp, destination string) bool {
	for _, r := range rules {
		if r.MatchString(destination) {
			return true
		}
	}
	return false
}

func (l *Limiter) CheckDomainRule(destination string) bool {
	s := l.nativeRules.Load()
	return s != nil && (matches(s.panel, destination) || matches(s.local, destination))
}

// HY2 never supported original panel routes; only explicitly enabled local
// domain rules use its request callback. Do not enable panel rules by accident.
func (l *Limiter) CheckLocalDomainRule(destination string) bool {
	s := l.nativeRules.Load()
	return s != nil && matches(s.local, destination)
}

func (l *Limiter) LocalRuleVersion() string {
	if s := l.nativeRules.Load(); s != nil {
		return s.localVersion
	}
	return ""
}

func (l *Limiter) CheckProtocolRule(protocol string) bool {
	if s := l.nativeRules.Load(); s != nil {
		for _, p := range s.protocols {
			if p == protocol {
				return true
			}
		}
	}
	return false
}

func compileNativeRules(rule *panel.Rules, local []string) (*nativeRuleSnapshot, error) {
	s := &nativeRuleSnapshot{}
	if rule == nil {
		rule = &panel.Rules{}
	}
	for source, values := range [][]string{rule.Regexp, local} {
		for i, value := range values {
			r, err := regexp.Compile(value)
			if err != nil {
				return nil, fmt.Errorf("invalid native rule source %d index %d", source, i)
			}
			if source == 0 {
				s.panel = append(s.panel, r)
			} else {
				s.local = append(s.local, r)
			}
		}
	}
	s.protocols = append([]string(nil), rule.Protocol...)
	if len(local) > 0 {
		h := sha256.Sum256([]byte(strings.Join(local, "\x00")))
		s.localVersion = hex.EncodeToString(h[:])
	}
	return s, nil
}

// Validate before any node/user teardown. An invalid regexp must never panic
// or leave half of a new policy installed.
func ValidateNativeRules(rule *panel.Rules, local []string) error {
	_, err := compileNativeRules(rule, local)
	return err
}

func (l *Limiter) UpdateNativeRules(rule *panel.Rules, local []string) error {
	s, err := compileNativeRules(rule, local)
	if err != nil {
		return err
	}
	l.nativeRules.Store(s)
	return nil
}

func (l *Limiter) UpdateRule(rule *panel.Rules) error {
	return l.UpdateNativeRules(rule, nil)
}
