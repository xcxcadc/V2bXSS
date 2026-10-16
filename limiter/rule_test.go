package limiter

import (
	"fmt"
	"sync"
	"testing"

	"github.com/InazumaV/V2bX/api/panel"
)

func TestNativeRulesAtomicValidationAndSourceIsolation(t *testing.T) {
	l := &Limiter{}
	p := &panel.Rules{Regexp: []string{`^panel\.invalid$`}, Protocol: []string{"bittorrent"}}
	local := []string{`^local\.invalid$`}
	if err := l.UpdateNativeRules(p, local); err != nil {
		t.Fatal(err)
	}
	p.Regexp[0], p.Protocol[0], local[0] = "mutated", "mutated", "mutated"
	if !l.CheckDomainRule("panel.invalid") || !l.CheckDomainRule("local.invalid") || !l.CheckProtocolRule("bittorrent") {
		t.Fatal("caller mutation changed applied policy")
	}
	if l.CheckLocalDomainRule("panel.invalid") || !l.CheckLocalDomainRule("local.invalid") {
		t.Fatal("source isolation failed")
	}
	old := l.nativeRules.Load()
	for _, next := range []struct {
		panel *panel.Rules
		local []string
	}{
		{&panel.Rules{Regexp: []string{"["}}, nil},
		{&panel.Rules{Regexp: []string{"new.invalid"}}, []string{"["}},
	} {
		if l.UpdateNativeRules(next.panel, next.local) == nil || l.nativeRules.Load() != old {
			t.Fatal("invalid policy partially replaced last valid snapshot")
		}
	}
	if err := l.UpdateNativeRules(&panel.Rules{Regexp: []string{`^panel\.invalid$`}, Protocol: []string{"bittorrent"}}, nil); err != nil {
		t.Fatal(err)
	}
	if l.CheckDomainRule("local.invalid") || l.LocalRuleVersion() != "" || !l.CheckDomainRule("panel.invalid") || !l.CheckProtocolRule("bittorrent") {
		t.Fatal("local clear removed unrelated panel rules")
	}
}

func TestNativeRulesConcurrentDualSourceSnapshots(t *testing.T) {
	l := &Limiter{}
	apply := func(n int) {
		v := fmt.Sprintf("^generation%d$", n)
		if err := l.UpdateNativeRules(&panel.Rules{Regexp: []string{v}, Protocol: []string{v}}, []string{v}); err != nil {
			t.Error(err)
		}
	}
	apply(0)
	var wg sync.WaitGroup
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 5000; j++ {
				s := l.nativeRules.Load()
				if len(s.panel) != 1 || len(s.local) != 1 || len(s.protocols) != 1 || s.panel[0].String() != s.local[0].String() || s.local[0].String() != s.protocols[0] {
					t.Error("observed mixed-source generation")
					return
				}
				_ = l.CheckDomainRule("allowed.invalid")
				_ = l.CheckLocalDomainRule("allowed.invalid")
				_ = l.CheckProtocolRule("tls")
			}
		}()
	}
	for i := 0; i < 300; i++ {
		apply(i)
	}
	wg.Wait()
}
