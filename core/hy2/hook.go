package hy2

import (
	"sync"

	"github.com/InazumaV/V2bX/common/counter"
	"github.com/InazumaV/V2bX/common/format"
	"github.com/InazumaV/V2bX/limiter"
	"github.com/apernet/hysteria/core/v2/server"
	"go.uber.org/zap"
)

var _ server.TrafficLogger = (*HookServer)(nil)

type HookServer struct {
	Tag                   string
	logger                *zap.Logger
	Counter               sync.Map
	ReportMinTrafficBytes int64
}

func (h *HookServer) TraceStream(stream server.HyStream, stats *server.StreamStats) {
}

func (h *HookServer) UntraceStream(stream server.HyStream) {
}

func (h *HookServer) LogTraffic(id string, tx, rx uint64) (ok bool) {
	var c interface{}
	var exists bool

	limiterinfo, err := limiter.GetLimiter(h.Tag)
	if err != nil {
		h.logger.Error("Get limiter error", zap.String("tag", h.Tag), zap.Error(err))
		return false
	}

	userLimit, ok := limiterinfo.UserLimitInfo.Load(format.UserTag(h.Tag, id))
	if !ok {
		// The panel revoked this user (quota exhausted, expired or removed).
		// Returning false makes the native core close the authenticated QUIC
		// connection, including all already-established TCP/UDP streams.
		return false
	} else {
		userlimitInfo := userLimit.(*limiter.UserLimitInfo)
		if userlimitInfo.OverLimit {
			userlimitInfo.OverLimit = false
			return false
		}
	}

	if c, exists = h.Counter.Load(h.Tag); !exists {
		c, _ = h.Counter.LoadOrStore(h.Tag, counter.NewTrafficCounter())
	}

	if tc, ok := c.(*counter.TrafficCounter); ok {
		tc.Rx(id, int(rx))
		tc.Tx(id, int(tx))
		return true
	}

	return false
}

func (s *HookServer) LogOnlineState(id string, online bool) {
}
