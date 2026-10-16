package node

import (
	"log"
	"testing"

	"github.com/InazumaV/V2bX/conf"
)

// Creating a Lego client may contact ACME even before a certificate is issued.
// Keep that side effect inside the explicitly selected integration tests.
func newTestLego(t *testing.T) *Lego {
	t.Helper()
	l, err := NewLego(&conf.CertConfig{
		CertMode:   "dns",
		Email:      "test@test.com",
		CertDomain: "test.test.com",
		Provider:   "cloudflare",
		DNSEnv: map[string]string{
			"CF_DNS_API_TOKEN": "123",
		},
		CertFile: "./cert/1.pem",
		KeyFile:  "./cert/1.key",
	})
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func TestLego_CreateCertByDns(t *testing.T) {
	l := newTestLego(t)
	err := l.CreateCert()
	if err != nil {
		t.Error(err)
	}
}

func TestLego_RenewCert(t *testing.T) {
	l := newTestLego(t)
	log.Println(l.RenewCert())
}
