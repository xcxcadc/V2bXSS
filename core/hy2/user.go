package hy2

import (
	"fmt"
	"net"
	"sync"

	"github.com/InazumaV/V2bX/api/panel"
	"github.com/InazumaV/V2bX/common/counter"
	vCore "github.com/InazumaV/V2bX/core"
	"github.com/apernet/hysteria/core/v2/server"
)

var _ server.Authenticator = &V2bX{}

type V2bX struct {
	usersMap map[string]int
	mutex    sync.RWMutex
}

func (v *V2bX) Authenticate(addr net.Addr, auth string, tx uint64) (ok bool, id string) {
	v.mutex.RLock()
	defer v.mutex.RUnlock()
	if _, exists := v.usersMap[auth]; exists {
		return true, auth
	}
	return false, ""
}

func (h *Hysteria2) AddUsers(p *vCore.AddUsersParams) (added int, err error) {
	node, ok := h.Hy2nodes[p.Tag]
	if !ok || node.Auth == nil {
		return 0, fmt.Errorf("native hy2 node not found")
	}
	var wg sync.WaitGroup
	for _, user := range p.Users {
		wg.Add(1)
		go func(u panel.UserInfo) {
			defer wg.Done()
			node.Auth.mutex.Lock()
			node.Auth.usersMap[u.Uuid] = u.Id
			node.Auth.mutex.Unlock()
		}(user)
	}
	wg.Wait()
	return len(p.Users), nil
}

func (h *Hysteria2) DelUsers(users []panel.UserInfo, tag string, _ *panel.NodeInfo) error {
	node, ok := h.Hy2nodes[tag]
	if !ok || node.Auth == nil {
		return fmt.Errorf("native hy2 node not found")
	}
	var wg sync.WaitGroup
	for _, user := range users {
		wg.Add(1)
		if v, ok := h.Hy2nodes[tag].TrafficLogger.(*HookServer).Counter.Load(tag); ok {
			c := v.(*counter.TrafficCounter)
			c.Delete(user.Uuid)
		}
		go func(u panel.UserInfo) {
			defer wg.Done()
			node.Auth.mutex.Lock()
			delete(node.Auth.usersMap, u.Uuid)
			node.Auth.mutex.Unlock()
			if revoker, ok := node.Hy2server.(interface{ DisconnectUser(string) }); ok {
				revoker.DisconnectUser(u.Uuid)
			}
		}(user)
	}
	wg.Wait()
	return nil
}

func (h *Hysteria2) GetUserTrafficSlice(tag string, reset bool) ([]panel.UserTraffic, error) {
	trafficSlice := make([]panel.UserTraffic, 0)
	node, ok := h.Hy2nodes[tag]
	if !ok || node.Auth == nil {
		return nil, nil
	}
	node.Auth.mutex.RLock()
	defer node.Auth.mutex.RUnlock()
	hook := h.Hy2nodes[tag].TrafficLogger.(*HookServer)
	if v, ok := hook.Counter.Load(tag); ok {
		c := v.(*counter.TrafficCounter)
		c.Counters.Range(func(key, value interface{}) bool {
			uuid := key.(string)
			traffic := value.(*counter.TrafficStorage)
			up := traffic.UpCounter.Load()
			down := traffic.DownCounter.Load()
			if up+down > hook.ReportMinTrafficBytes {
				if reset {
					up = traffic.UpCounter.Swap(0)
					down = traffic.DownCounter.Swap(0)
				}
				if node.Auth.usersMap[uuid] == 0 {
					c.Delete(uuid)
					return true
				}
				trafficSlice = append(trafficSlice, panel.UserTraffic{
					UID:      node.Auth.usersMap[uuid],
					Upload:   up,
					Download: down,
				})
			}
			return true
		})
		if len(trafficSlice) == 0 {
			return nil, nil
		}
		return trafficSlice, nil
	}
	return nil, nil
}
