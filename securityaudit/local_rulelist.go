package securityaudit

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"regexp"
	"strings"
	"unicode"
	"unicode/utf8"
)

// Leave room in the panel's existing 64 KiB capability column; no migration.
const MaxLocalRuleListBytes = 60 << 10

type LocalRule struct {
	Type     string `json:"type"`
	Value    string `json:"value"`
	Action   string `json:"action"`
	ReadOnly bool   `json:"read_only"`
}

// This independent, read-only inventory never merges into panel_routes or the
// panel-managed security rule set. Deliberately excludes the local file path.
type LocalRuleList struct {
	Source               string      `json:"source"`
	Configured           bool        `json:"configured"`
	Enabled              bool        `json:"enabled"`
	EnforcementRequested bool        `json:"enforcement_requested"`
	EnforcementSupported bool        `json:"enforcement_supported"`
	ReadOnly             bool        `json:"read_only"`
	SHA256               string      `json:"sha256"`
	LastCheckedAt        int64       `json:"last_checked_at"`
	LastLoadedAt         int64       `json:"last_loaded_at"`
	Error                string      `json:"error"`
	Rules                []LocalRule `json:"rules"`
}

var localErrorPattern = regexp.MustCompile(`^(?:open_failed|not_regular_file|read_failed|file_changed_during_read|file_too_large|invalid_utf8|too_many_rules|inventory_too_large|apply_failed|(?:invalid_regex|invalid_value|unsupported_prefix):line [1-9][0-9]{0,6})$`)

func ValidateLocalRuleList(s LocalRuleList) error {
	bad := errors.New("invalid local rule inventory")
	if s.Source != "local_rulelist" || !s.ReadOnly || s.LastCheckedAt < 0 || s.LastLoadedAt < 0 || s.LastLoadedAt > s.LastCheckedAt || len(s.Rules) > 1000 {
		return bad
	}
	if s.Error != "" && !localErrorPattern.MatchString(s.Error) {
		return bad
	}
	if s.SHA256 != "" {
		if len(s.SHA256) != 64 || strings.ToLower(s.SHA256) != s.SHA256 {
			return bad
		}
		if _, err := hex.DecodeString(s.SHA256); err != nil {
			return bad
		}
	} else if s.Enabled || len(s.Rules) != 0 || s.LastLoadedAt != 0 {
		return bad
	}
	if s.Enabled && !(s.Configured && s.EnforcementRequested && s.EnforcementSupported) {
		return bad
	}
	for _, r := range s.Rules {
		if r.Type != "domain_regex" || r.Action != "block" || !r.ReadOnly || len(r.Value) == 0 || len(r.Value) > 512 || !utf8.ValidString(r.Value) {
			return bad
		}
		for _, c := range r.Value {
			if unicode.IsControl(c) || unicode.Is(unicode.Cf, c) {
				return bad
			}
		}
	}
	b, err := json.Marshal(s)
	if err != nil || len(b) > MaxLocalRuleListBytes {
		return bad
	}
	return nil
}

func cloneLocalRuleList(s LocalRuleList) LocalRuleList {
	s.Rules = append(make([]LocalRule, 0, len(s.Rules)), s.Rules...)
	return s
}

// Reject invalid inventory wholesale and keep the previous valid report.
func (a *Agent) UpdateLocalRuleList(s LocalRuleList) error {
	if err := ValidateLocalRuleList(s); err != nil {
		return err
	}
	next := cloneLocalRuleList(s)
	a.localRules.Store(&next)
	return nil
}
