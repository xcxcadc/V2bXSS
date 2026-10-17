package cmd

import (
	"path/filepath"
	"testing"
)

func TestServerReturnsStartupFailure(t *testing.T) {
	previous := config
	t.Cleanup(func() { config = previous })
	config = filepath.Join(t.TempDir(), "missing.json")
	if err := serverHandle(nil, nil); err == nil {
		t.Fatal("a startup failure must reach Cobra and produce a nonzero process exit")
	}
}
