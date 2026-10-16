package node

import (
	"github.com/InazumaV/V2bX/common/format"
	"github.com/InazumaV/V2bX/securityaudit"
	log "github.com/sirupsen/logrus"
)

func (c *Controller) startSecurityAudit() {
	coreType := c.Options.Core
	if coreType == "" {
		coreType = c.server.Type()
	}
	c.securityAudit = securityaudit.NewAgent(c.apiClient, securityaudit.Options{
		NodeID: c.apiClient.NodeId, NodeType: c.apiClient.NodeType, Core: coreType,
		CachePath: c.apiClient.SecurityAuditCachePath,
		OnError: func(err error) {
			log.WithField("tag", c.tag).WithError(err).Warn("Optional security audit sync failed; existing node service continues")
		},
	})
	c.refreshSecurityAuditUsers()
	c.refreshSecurityAuditLegacyRules()
	c.refreshSecurityAuditLocalRules()
	c.securityAudit.Start()
}

func (c *Controller) refreshSecurityAuditLegacyRules() {
	if c.securityAudit == nil || c.info == nil {
		return
	}
	rules := make([]securityaudit.LegacyRule, 0, len(c.info.Rules.Regexp)+len(c.info.Rules.Protocol))
	for _, value := range c.info.Rules.Regexp {
		rules = append(rules, securityaudit.LegacyRule{Type: "domain_regex", Value: value, Action: "block", Source: "panel_routes"})
	}
	for _, value := range c.info.Rules.Protocol {
		rules = append(rules, securityaudit.LegacyRule{Type: "protocol", Value: value, Action: "block", Source: "panel_routes"})
	}
	c.securityAudit.UpdateLegacyRules(rules)
}

func (c *Controller) refreshSecurityAuditUsers() {
	if c.securityAudit == nil {
		return
	}
	users := make(map[string]int, len(c.userList)*2)
	for _, u := range c.userList {
		users[u.Uuid] = u.Id                        // sing passes the authenticated UUID
		users[format.UserTag(c.tag, u.Uuid)] = u.Id // Xray stores its internal user tag in Email
	}
	c.securityAudit.UpdateUsers(users)
	if c.securityAuditTag != c.tag {
		securityaudit.Unregister(c.securityAuditTag)
		securityaudit.Register(c.tag, c.securityAudit)
		c.securityAuditTag = c.tag
	}
}
