// Package securityaudit implements optional, defensive rule-match auditing.
// It never records unmatched connections and does not modify account state.
package securityaudit

import (
	"fmt"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
)

const MaxRules = 1024

type Rule struct {
	ID      string `json:"id"`
	Type    string `json:"type"`
	Value   string `json:"value"`
	Action  string `json:"action"`
	Enabled *bool  `json:"enabled,omitempty"`
}

type Config struct {
	Version string `json:"version"`
	Enabled bool   `json:"enabled"`
	Rules   []Rule `json:"rules"`
}

type compiledRule struct {
	Rule
	re      *regexp.Regexp
	prefix  netip.Prefix
	port    uint16
	portEnd uint16
}

type snapshot struct {
	version string
	rules   []compiledRule
}

// Engine publishes complete immutable configurations. A rejected update leaves
// the last valid configuration active, without affecting ordinary node service.
type Engine struct{ active atomic.Pointer[snapshot] }

func (e *Engine) Apply(c Config) error {
	if len(c.Version) > 128 || (c.Enabled && strings.TrimSpace(c.Version) == "") {
		return fmt.Errorf("audit config needs a version of 1-128 bytes")
	}
	if len(c.Rules) > MaxRules {
		return fmt.Errorf("audit config exceeds %d rules", MaxRules)
	}
	next := &snapshot{version: c.Version}
	ids := make(map[string]bool, len(c.Rules))
	for _, r := range c.Rules {
		if !validID(r.ID) || ids[r.ID] {
			return fmt.Errorf("audit rule has invalid or duplicate id")
		}
		ids[r.ID] = true
		if r.Enabled != nil && !*r.Enabled {
			continue
		}
		if r.Action != "observe" && r.Action != "block" {
			return fmt.Errorf("audit rule %s: unsupported action", r.ID)
		}
		if len(r.Value) == 0 || len(r.Value) > 2048 {
			return fmt.Errorf("audit rule %s: invalid value length", r.ID)
		}
		cr := compiledRule{Rule: r}
		var err error
		switch r.Type {
		case "domain_exact", "domain_suffix":
			cr.Value = normalizeTarget(r.Value)
			if !validDomain(cr.Value) {
				return fmt.Errorf("audit rule %s: expected a domain, without URL or wildcard", r.ID)
			}
		case "domain_regex":
			if portableRegex(r.Value) {
				cr.re, err = regexp.Compile(r.Value)
			} else {
				err = fmt.Errorf("outside portable regex subset")
			}
		case "ip_cidr":
			if ip, ipErr := netip.ParseAddr(r.Value); ipErr == nil {
				ip = ip.Unmap()
				cr.prefix = netip.PrefixFrom(ip, ip.BitLen())
			} else {
				cr.prefix, err = netip.ParsePrefix(r.Value)
			}
			if err == nil && cr.prefix.Addr().Is4In6() {
				if cr.prefix.Bits() < 96 {
					err = fmt.Errorf("mapped IPv4 prefix must be /96 or narrower")
				} else {
					cr.prefix = netip.PrefixFrom(cr.prefix.Addr().Unmap(), cr.prefix.Bits()-96)
				}
			}
			cr.prefix = cr.prefix.Masked()
		case "port":
			start, end, hasEnd := strings.Cut(r.Value, "-")
			var p, pEnd uint64
			p, err = strconv.ParseUint(start, 10, 16)
			if hasEnd && err == nil {
				pEnd, err = strconv.ParseUint(end, 10, 16)
			} else {
				pEnd = p
			}
			if (p == 0 || pEnd < p) && err == nil {
				err = fmt.Errorf("invalid port range")
			}
			cr.port, cr.portEnd = uint16(p), uint16(pEnd)
		case "protocol":
			cr.Value = strings.ToLower(strings.TrimSpace(r.Value))
			switch cr.Value {
			case "http", "tls", "quic", "bittorrent", "stun", "ssh":
			default:
				err = fmt.Errorf("invalid protocol")
			}
		default:
			err = fmt.Errorf("unsupported rule type")
		}
		if err != nil {
			// Do not echo rule content, targets, credentials or raw server responses.
			return fmt.Errorf("audit rule %s: invalid %s value", r.ID, r.Type)
		}
		if c.Enabled {
			next.rules = append(next.rules, cr)
		}
	}
	e.active.Store(next)
	return nil
}

type Connection struct {
	UserID int
	Target string
	// Domain is an optional sniffed host. Keep Target as the original literal
	// destination when available so domain inspection does not lose CIDR checks.
	Domain   string
	Port     uint16
	Protocol string
}

type Match struct {
	RuleID string
	Action string
	Target string
}

// Evaluate matches only validated host/IP targets. A domain suffix has a label
// boundary: example.test matches a.example.test, never notexample.test.
func (e *Engine) Evaluate(c Connection) (version string, matches []Match, block bool) {
	s := e.active.Load()
	if s == nil {
		return "", nil, false
	}
	version = s.version
	if len(s.rules) == 0 {
		return version, nil, false
	}
	target := normalizeTarget(c.Target)
	if c.UserID <= 0 || c.Port == 0 || !validTarget(target) {
		return version, nil, false
	}
	ip, isIP := targetIP(target)
	domain := target
	if isIP {
		domain = normalizeTarget(c.Domain)
		if !validDomain(domain) {
			domain = ""
		}
	}
	protocol := strings.ToLower(c.Protocol)
	for _, r := range s.rules {
		matched := false
		evidenceTarget := target
		switch r.Type {
		case "domain_exact":
			matched = domain != "" && domain == r.Value
			evidenceTarget = domain
		case "domain_suffix":
			matched = domain != "" && (domain == r.Value || len(domain) > len(r.Value) && domain[len(domain)-len(r.Value)-1] == '.' && strings.HasSuffix(domain, r.Value))
			evidenceTarget = domain
		case "domain_regex":
			matched = domain != "" && r.re.MatchString(domain)
			evidenceTarget = domain
		case "ip_cidr":
			matched = isIP && r.prefix.Contains(ip.Unmap())
		case "port":
			matched = c.Port >= r.port && c.Port <= r.portEnd
		case "protocol":
			matched = protocol == r.Value
		}
		if matched {
			matches = append(matches, Match{RuleID: r.ID, Action: r.Action, Target: evidenceTarget})
			block = block || r.Action == "block"
		}
	}
	return
}

func (e *Engine) Version() string {
	if s := e.active.Load(); s != nil {
		return s.version
	}
	return ""
}

func normalizeTarget(s string) string {
	s = strings.ToLower(strings.TrimSuffix(strings.TrimSpace(s), "."))
	if ip, ok := targetIP(s); ok {
		return ip.Unmap().String()
	}
	return s
}

func validTarget(s string) bool {
	if len(s) > 253 || len(s) == 0 {
		return false
	}
	if _, ok := targetIP(s); ok {
		return true
	}
	return validDomain(s)
}

func validDomain(s string) bool {
	if len(s) == 0 || len(s) > 253 {
		return false
	}
	if !strings.Contains(s, ".") {
		return false
	}
	if _, ok := targetIP(s); ok {
		return false
	}
	for label := range strings.SplitSeq(s, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, r := range label {
			if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
				return false
			}
		}
	}
	return true
}

// Skip ParseAddr's allocated error objects for normal DNS names on the hot path.
func targetIP(s string) (netip.Addr, bool) {
	if !strings.Contains(s, ":") {
		for _, c := range s {
			if c != '.' && (c < '0' || c > '9') {
				return netip.Addr{}, false
			}
		}
	}
	ip, err := netip.ParseAddr(s)
	return ip, err == nil
}

func validID(s string) bool {
	if len(s) == 0 || len(s) > 80 {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-') {
			return false
		}
	}
	return true
}

// The panel rechecks evidence with PCRE. Use a deliberately smaller common
// subset than RE2 to keep both engines consistent and bounded.
func portableRegex(s string) bool {
	if len(s) > 512 || strings.Contains(s, "(?") || strings.Contains(s, "[[:") {
		return false
	}
	inClass := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < 0x20 || c > 0x7e {
			return false
		}
		if c == '\\' {
			i++
			if i >= len(s) {
				return false
			}
			c = s[i]
			if (c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9') && !strings.ContainsRune("dDsSwWtnr", rune(c)) {
				return false
			}
			continue
		}
		if c == '[' && !inClass {
			inClass = true
			continue
		}
		if c == ']' && inClass {
			inClass = false
			continue
		}
		if !inClass && c == ')' && i+1 < len(s) && strings.ContainsRune("*+?{", rune(s[i+1])) {
			return false
		}
		if strings.ContainsRune("*+?}", rune(c)) && i+1 < len(s) && strings.ContainsRune("+?", rune(s[i+1])) {
			return false
		}
	}
	return true
}
