package node

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/InazumaV/V2bX/securityaudit"
	log "github.com/sirupsen/logrus"
)

const maxLocalRuleFileBytes = 256 << 10

type localRuleState struct {
	report      securityaudit.LocalRuleList
	checkedFile os.FileInfo
	checkedPath string
}

func parseLocalRuleList(data []byte) ([]securityaudit.LocalRule, string, error) {
	if len(data) > maxLocalRuleFileBytes {
		return nil, "", errors.New("file_too_large")
	}
	if !utf8.Valid(data) {
		return nil, "", errors.New("invalid_utf8")
	}
	rules := make([]securityaudit.LocalRule, 0)
	seen := make(map[string]bool)
	for i, line := range strings.Split(strings.TrimPrefix(string(data), "\ufeff"), "\n") {
		value := strings.TrimSpace(line)
		if value == "" || strings.HasPrefix(value, "#") || strings.HasPrefix(value, "//") {
			continue
		}
		if strings.HasPrefix(value, "protocol:") {
			return nil, "", fmt.Errorf("unsupported_prefix:line %d", i+1)
		}
		value = strings.TrimSpace(strings.TrimPrefix(value, "regexp:"))
		if len(value) == 0 || len(value) > 512 {
			return nil, "", fmt.Errorf("invalid_value:line %d", i+1)
		}
		for _, c := range value {
			if unicode.IsControl(c) || unicode.Is(unicode.Cf, c) {
				return nil, "", fmt.Errorf("invalid_value:line %d", i+1)
			}
		}
		if seen[value] {
			continue
		}
		if _, err := regexp.Compile(value); err != nil {
			return nil, "", fmt.Errorf("invalid_regex:line %d", i+1)
		}
		if len(rules) >= 1000 {
			return nil, "", errors.New("too_many_rules")
		}
		seen[value] = true
		rules = append(rules, securityaudit.LocalRule{Type: "domain_regex", Value: value, Action: "block", ReadOnly: true})
	}
	h := sha256.Sum256(data)
	return rules, hex.EncodeToString(h[:]), nil
}

func sameLocalFile(a, b os.FileInfo) bool {
	return a != nil && b != nil && os.SameFile(a, b) && a.Size() == b.Size() && a.ModTime().Equal(b.ModTime()) && a.Mode() == b.Mode()
}

func readLocalRuleFile(path string, before os.FileInfo) ([]securityaudit.LocalRule, string, error) {
	if !before.Mode().IsRegular() {
		return nil, "", errors.New("not_regular_file")
	}
	if before.Size() > maxLocalRuleFileBytes {
		return nil, "", errors.New("file_too_large")
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, "", errors.New("open_failed")
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil || !sameLocalFile(before, opened) {
		return nil, "", errors.New("file_changed_during_read")
	}
	data, err := io.ReadAll(io.LimitReader(f, maxLocalRuleFileBytes+1))
	if err != nil {
		return nil, "", errors.New("read_failed")
	}
	after, err := f.Stat()
	if err != nil || !sameLocalFile(before, after) {
		return nil, "", errors.New("file_changed_during_read")
	}
	current, err := os.Lstat(path)
	if err != nil || !sameLocalFile(before, current) {
		return nil, "", errors.New("file_changed_during_read")
	}
	return parseLocalRuleList(data)
}

func (c *Controller) localEnforcementSupported() bool {
	coreType := ""
	if c.Options != nil {
		coreType = c.Options.Core
	}
	if coreType == "" && c.server != nil {
		coreType = c.server.Type()
	}
	return coreType == "xray" || coreType == "sing" || coreType == "hysteria2"
}

func (c *Controller) activeLocalPatterns() []string {
	if c.localRules == nil || !c.localRules.report.Enabled {
		return nil
	}
	values := make([]string, len(c.localRules.report.Rules))
	for i, r := range c.localRules.report.Rules {
		values[i] = r.Value
	}
	return values
}

// Called by the existing node poll, even before HTTP304 or a panel outage.
// Unconfigured nodes do no filesystem work. Unchanged regular files only use
// metadata; connections never perform file reads or wait for the panel.
func (c *Controller) refreshLocalRuleList() {
	if c.apiClient == nil || c.info == nil || c.limiter == nil {
		return
	}
	path := c.apiClient.RuleListPath
	if path == "" && c.localRules == nil {
		return
	}
	if c.localRules == nil {
		c.localRules = &localRuleState{report: securityaudit.LocalRuleList{Source: "local_rulelist", ReadOnly: true, Rules: make([]securityaudit.LocalRule, 0)}}
	}
	s := c.localRules
	previous := s.report
	next := previous
	next.Configured = path != ""
	next.EnforcementRequested = c.apiClient.RuleListEnforce
	next.EnforcementSupported = c.localEnforcementSupported()
	next.LastCheckedAt = max(time.Now().Unix(), previous.LastLoadedAt)
	if path == "" {
		next.SHA256, next.Error, next.LastLoadedAt = "", "", 0
		next.Rules = make([]securityaudit.LocalRule, 0)
		s.checkedFile, s.checkedPath = nil, ""
	} else {
		info, err := os.Lstat(path)
		if err != nil {
			next.Error = "open_failed"
			s.checkedFile = nil
		} else if s.checkedPath != path || !sameLocalFile(s.checkedFile, info) {
			rules, sha, readErr := readLocalRuleFile(path, info)
			s.checkedPath, s.checkedFile = path, info
			if readErr != nil {
				next.Error = readErr.Error()
				if next.Error == "file_changed_during_read" || next.Error == "open_failed" || next.Error == "read_failed" {
					s.checkedFile = nil
				}
			} else {
				next.Rules, next.SHA256, next.Error = rules, sha, ""
				if next.SHA256 != previous.SHA256 {
					next.LastLoadedAt = next.LastCheckedAt
				}
			}
		}
	}
	next.Enabled = next.Configured && next.EnforcementRequested && next.EnforcementSupported && next.SHA256 != ""
	// Validate the *whole* serialised inventory before applying any new file.
	// Reserve error/timestamp growth room, so later failures remain reportable.
	probe := next
	probe.Error = "file_changed_during_read"
	probe.LastCheckedAt = 999999999999
	if probe.SHA256 != "" {
		probe.LastLoadedAt = probe.LastCheckedAt
	}
	if securityaudit.ValidateLocalRuleList(probe) != nil {
		next.Rules, next.SHA256, next.LastLoadedAt = previous.Rules, previous.SHA256, previous.LastLoadedAt
		next.Error = "inventory_too_large"
		next.Enabled = next.Configured && next.EnforcementRequested && next.EnforcementSupported && next.SHA256 != ""
	}
	if next.Enabled != previous.Enabled || next.SHA256 != previous.SHA256 {
		var patterns []string
		if next.Enabled {
			for _, r := range next.Rules {
				patterns = append(patterns, r.Value)
			}
		}
		if err := c.limiter.UpdateNativeRules(&c.info.Rules, patterns); err != nil {
			next.Rules, next.SHA256, next.Enabled, next.LastLoadedAt = previous.Rules, previous.SHA256, previous.Enabled, previous.LastLoadedAt
			next.Error = "apply_failed"
			s.checkedFile = nil // allow a transient application failure to recover
		}
	}
	s.report = next
	if next.Error != "" && next.Error != previous.Error {
		log.WithField("tag", c.tag).WithField("code", next.Error).Warn("Local rule file update rejected; retained last valid rules")
	}
	c.refreshSecurityAuditLocalRules()
}

func (c *Controller) refreshSecurityAuditLocalRules() {
	if c.securityAudit != nil && c.localRules != nil {
		_ = c.securityAudit.UpdateLocalRuleList(c.localRules.report)
	}
}
