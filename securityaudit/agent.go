package securityaudit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

var ErrUnavailable = errors.New("optional security audit endpoint unavailable")

// RejectedReport is a permanent per-event validation rejection. Retrying such
// events forever would prevent valid newer events from leaving the queue.
type RejectedReport struct {
	Count  int
	Status int
}

func (e *RejectedReport) Error() string {
	return fmt.Sprintf("security audit report rejected %d event(s), HTTP %d", e.Count, e.Status)
}

type Event struct {
	configVersion string
	EventID       string `json:"event_id"`
	UserID        int    `json:"user_id"`
	NodeID        int    `json:"node_id"`
	NodeType      string `json:"node_type"`
	Timestamp     int64  `json:"timestamp"`
	Target        string `json:"target"`
	Port          uint16 `json:"port"`
	Protocol      string `json:"protocol"`
	RuleID        string `json:"rule_id"`
	Action        string `json:"action"`
}

type Report struct {
	Version        string          `json:"version"`
	AppliedVersion string          `json:"applied_version"`
	Events         []Event         `json:"events"`
	Capabilities   map[string]bool `json:"capabilities"`
	Dropped        uint64          `json:"dropped"`
	SyncError      string          `json:"sync_error,omitempty"`
	LegacyRules    *[]LegacyRule   `json:"legacy_rules,omitempty"`
}

// LegacyRule inventories existing panel route blocks without changing them or
// automatically importing their content into the new security rule set.
type LegacyRule struct {
	Type   string `json:"type"`
	Value  string `json:"value"`
	Action string `json:"action"`
	Source string `json:"source"`
}

type legacySnapshot struct {
	rules []LegacyRule
	error string
}

type Client interface {
	FetchSecurityAudit(context.Context) (Config, error)
	ReportSecurityAudit(context.Context, Report) error
}

type Options struct {
	NodeID         int
	NodeType       string
	Core           string
	CachePath      string
	QueueSize      int
	PollInterval   time.Duration
	ReportInterval time.Duration
	OnError        func(error)
}

type userSnapshot map[string]int

// Agent owns an independent worker/queue; connection hooks never wait for disk
// or HTTP. When the queue is full, auditing drops events, not node traffic.
type Agent struct {
	engine    Engine
	client    Client
	options   Options
	users     atomic.Pointer[userSnapshot]
	legacy    atomic.Pointer[legacySnapshot]
	mu        sync.Mutex
	queue     []Event
	dropped   atomic.Uint64
	sequence  atomic.Uint64
	prefix    string
	lastError atomic.Pointer[string]
	cancel    context.CancelFunc
	wg        sync.WaitGroup
}

func NewAgent(client Client, o Options) *Agent {
	if o.QueueSize <= 0 || o.QueueSize > 65536 {
		o.QueueSize = 2048
	}
	if o.PollInterval < time.Second {
		o.PollInterval = 30 * time.Second
	}
	if o.ReportInterval < time.Second {
		o.ReportInterval = 5 * time.Second
	}
	var nonce [12]byte
	_, _ = rand.Read(nonce[:])
	a := &Agent{client: client, options: o, prefix: hex.EncodeToString(nonce[:]), queue: make([]Event, 0, o.QueueSize)}
	return a
}

func (a *Agent) UpdateUsers(users map[string]int) {
	next := make(userSnapshot, len(users))
	for key, id := range users {
		if id > 0 {
			next[key] = id
		}
	}
	a.users.Store(&next)
}

func (a *Agent) UpdateLegacyRules(rules []LegacyRule) {
	// Bound inventory separately so 100 regular evidence events and JSON
	// escaping still fit comfortably under the panel's 256 KiB body limit.
	next := &legacySnapshot{rules: make([]LegacyRule, 0)}
	seen := make(map[string]bool)
	size := 0
	for _, rule := range rules {
		valid := (rule.Type == "domain_regex" || rule.Type == "protocol") && rule.Action == "block" && rule.Source == "panel_routes" && len(rule.Value) > 0 && len(rule.Value) <= 512
		for _, c := range rule.Value {
			valid = valid && c >= 0x20 && c != 0x7f
		}
		if !valid {
			next.error = "legacy inventory omitted unsupported or oversized route entries; existing routes remain active"
			continue
		}
		key := rule.Type + "\x00" + rule.Value
		if seen[key] {
			continue
		}
		encoded, _ := json.Marshal(rule)
		if len(next.rules) >= 1000 || size+len(encoded)+1 > 80<<10 {
			next.error = "legacy inventory truncated at 1000 entries or 80 KiB; existing routes remain active"
			break
		}
		seen[key] = true
		size += len(encoded) + 1
		next.rules = append(next.rules, rule)
	}
	a.legacy.Store(next)
}

func (a *Agent) Start() {
	if err := a.loadCache(); err != nil {
		a.setError(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	a.cancel = cancel
	a.wg.Add(2)
	go func() {
		defer a.wg.Done()
		a.syncConfig(ctx)
		t := time.NewTicker(a.options.PollInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				a.syncConfig(ctx)
			}
		}
	}()
	go func() {
		defer a.wg.Done()
		t := time.NewTicker(a.options.ReportInterval)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				a.flush(ctx)
			}
		}
	}()
}

func (a *Agent) Close() {
	if a.cancel != nil {
		a.cancel()
		a.wg.Wait()
	}
}

func (a *Agent) Check(userKey, target string, port uint16, protocol string) bool {
	return a.CheckEndpoint(userKey, target, "", port, protocol)
}

func (a *Agent) CheckEndpoint(userKey, target, domain string, port uint16, protocol string) bool {
	users := a.users.Load()
	if users == nil {
		return false
	}
	uid := (*users)[userKey]
	version, matches, block := a.engine.Evaluate(Connection{UserID: uid, Target: target, Domain: domain, Port: port, Protocol: protocol})
	for _, match := range matches {
		event := Event{configVersion: version, EventID: fmt.Sprintf("%s_%d", a.prefix, a.sequence.Add(1)), UserID: uid,
			NodeID: a.options.NodeID, NodeType: a.options.NodeType, Timestamp: time.Now().Unix(),
			Target: match.Target, Port: port, Protocol: protocol, RuleID: match.RuleID, Action: match.Action}
		a.mu.Lock()
		if len(a.queue) < a.options.QueueSize {
			a.queue = append(a.queue, event)
		} else {
			a.dropped.Add(1)
		}
		a.mu.Unlock()
	}
	return block
}

func (a *Agent) syncConfig(parent context.Context) {
	ctx, cancel := context.WithTimeout(parent, 8*time.Second)
	defer cancel()
	c, err := a.client.FetchSecurityAudit(ctx)
	if errors.Is(err, ErrUnavailable) {
		// An older/unextended panel starts with this optional engine inactive.
		// If an enabled panel temporarily loses its endpoint, preserve its last
		// valid policy. Only explicit enabled:false disables an applied policy.
		if a.engine.Version() != "" {
			a.setError(ErrUnavailable)
		}
		return
	}
	if err != nil {
		a.setError(err)
		return
	}
	if err = a.engine.Apply(c); err != nil {
		a.setError(err)
		return
	}
	if err = a.saveCache(c); err != nil {
		a.setError(err)
		return
	}
	a.lastError.Store(nil)
}

func (a *Agent) capabilities() map[string]bool {
	return map[string]bool{
		"xray_match_events":               a.options.Core == "xray",
		"xray_connection_block":           a.options.Core == "xray",
		"sing_match_events":               a.options.Core == "sing",
		"sing_connection_block":           a.options.Core == "sing",
		"native_hy2_match_events":         a.options.Core == "hysteria2",
		"native_hy2_connection_block":     a.options.Core == "hysteria2",
		"native_hy2_application_protocol": false,
		"native_hy2_hostname":             a.options.Core == "hysteria2",
		"native_hy2_literal_ip_cidr":      a.options.Core == "hysteria2",
		"native_hy2_port":                 a.options.Core == "hysteria2",
		"account_punishment":              false,
		"legacy_rule_inventory":           true,
	}
}

func (a *Agent) flush(parent context.Context) {
	a.mu.Lock()
	n := min(100, len(a.queue))
	version := a.engine.Version()
	if n > 0 {
		version = a.queue[0].configVersion
		for i := 1; i < n; i++ {
			if a.queue[i].configVersion != version {
				n = i
				break
			}
		}
	}
	events := append(make([]Event, 0, n), a.queue[:n]...)
	a.mu.Unlock()
	r := Report{Version: version, AppliedVersion: a.engine.Version(), Events: events, Capabilities: a.capabilities(), Dropped: a.dropped.Load()}
	if last := a.lastError.Load(); last != nil {
		r.SyncError = *last
	}
	if legacy := a.legacy.Load(); legacy != nil {
		r.LegacyRules = &legacy.rules
		if legacy.error != "" {
			r.SyncError = strings.TrimSpace(r.SyncError + " " + legacy.error)
		}
	}
	ctx, cancel := context.WithTimeout(parent, 8*time.Second)
	defer cancel()
	if err := a.client.ReportSecurityAudit(ctx, r); err != nil {
		var rejected *RejectedReport
		if errors.As(err, &rejected) {
			a.dropped.Add(uint64(max(0, rejected.Count)))
			a.setError(err)
		} else {
			if !errors.Is(err, ErrUnavailable) {
				a.setError(err)
			}
			return // retry identical event IDs; the panel must deduplicate them
		}
	}
	a.mu.Lock()
	copy(a.queue, a.queue[n:])
	clear(a.queue[len(a.queue)-n:])
	a.queue = a.queue[:len(a.queue)-n]
	a.mu.Unlock()
}

func (a *Agent) setError(err error) {
	msg := err.Error()
	a.lastError.Store(&msg)
	if a.options.OnError != nil {
		a.options.OnError(err)
	}
}

func (a *Agent) loadCache() error {
	if a.options.CachePath == "" {
		return nil
	}
	f, err := os.Open(a.options.CachePath)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("open audit cache failed")
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, 2<<20))
	if err != nil || len(data) >= 2<<20 {
		return fmt.Errorf("read audit cache failed or too large")
	}
	var c Config
	if err := json.Unmarshal(data, &c); err != nil {
		return fmt.Errorf("invalid audit cache JSON")
	}
	return a.engine.Apply(c)
}

func (a *Agent) saveCache(c Config) error {
	if a.options.CachePath == "" {
		return nil
	}
	data, err := json.Marshal(c)
	if err != nil {
		return fmt.Errorf("encode audit cache failed")
	}
	dir := filepath.Dir(a.options.CachePath)
	if err := os.MkdirAll(dir, 0700); err != nil {
		return fmt.Errorf("create audit cache directory failed")
	}
	f, err := os.CreateTemp(dir, ".audit-*.tmp")
	if err != nil {
		return fmt.Errorf("create audit cache failed")
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if err = f.Chmod(0600); err == nil {
		_, err = f.Write(data)
	}
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp, a.options.CachePath)
	}
	if err != nil {
		return fmt.Errorf("persist audit cache failed")
	}
	return nil
}

var agents sync.Map

func Register(tag string, a *Agent) { agents.Store(tag, a) }
func Unregister(tag string)         { agents.Delete(tag) }

func Version(tag string) string {
	if a, ok := agents.Load(tag); ok {
		return a.(*Agent).engine.Version()
	}
	return ""
}

// Check is a no-op for nodes without the optional extension and for users whose
// authenticated key is not present in the panel's assigned-user snapshot.
func Check(tag, userKey, target string, port uint16, protocol string) bool {
	return CheckEndpoint(tag, userKey, target, "", port, protocol)
}

func CheckEndpoint(tag, userKey, target, domain string, port uint16, protocol string) bool {
	if a, ok := agents.Load(tag); ok {
		return a.(*Agent).CheckEndpoint(userKey, target, domain, port, protocol)
	}
	return false
}
