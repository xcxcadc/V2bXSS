package panel

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/InazumaV/V2bX/securityaudit"
)

func (c *Client) FetchSecurityAudit(ctx context.Context) (securityaudit.Config, error) {
	var config securityaudit.Config
	r, err := c.client.R().SetContext(ctx).SetHeader("Accept", "application/json").
		Get("/api/v1/server/UniProxy/securityAudit/config")
	if err != nil {
		return config, fmt.Errorf("security audit config request failed")
	}
	if r.StatusCode() == 404 {
		return config, securityaudit.ErrUnavailable
	}
	if r.StatusCode() != 200 {
		return config, fmt.Errorf("security audit config HTTP %d", r.StatusCode())
	}
	if len(r.Body()) > 2<<20 {
		return config, fmt.Errorf("security audit config too large")
	}
	if err := json.Unmarshal(r.Body(), &config); err != nil {
		return config, fmt.Errorf("security audit config invalid JSON")
	}
	return config, nil
}

func (c *Client) ReportSecurityAudit(ctx context.Context, report securityaudit.Report) error {
	r, err := c.client.R().SetContext(ctx).SetBody(report).
		Post("/api/v1/server/UniProxy/securityAudit/events")
	if err != nil {
		return fmt.Errorf("security audit event request failed")
	}
	if r.StatusCode() == 404 {
		return securityaudit.ErrUnavailable
	}
	if r.StatusCode() == 409 {
		return &securityaudit.RejectedReport{Count: len(report.Events), Status: 409}
	}
	if r.StatusCode() < 200 || r.StatusCode() >= 300 {
		return fmt.Errorf("security audit events HTTP %d", r.StatusCode())
	}
	var result struct {
		Data struct {
			Rejected []struct {
				Index int `json:"index"`
			} `json:"rejected"`
		} `json:"data"`
	}
	if err := json.Unmarshal(r.Body(), &result); err != nil {
		return fmt.Errorf("security audit event response invalid JSON")
	}
	if count := len(result.Data.Rejected); count > 0 {
		return &securityaudit.RejectedReport{Count: count, Status: r.StatusCode()}
	}
	return nil
}
