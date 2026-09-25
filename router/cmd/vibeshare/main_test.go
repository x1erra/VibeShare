package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDestructiveCommandsRequireYes(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	if err := os.MkdirAll(filepath.Join(os.Getenv("HOME"), ".cli-proxy-api"), 0o700); err != nil {
		t.Fatal(err)
	}
	credential := filepath.Join(os.Getenv("HOME"), ".cli-proxy-api", "claude-test.json")
	if err := os.WriteFile(credential, []byte("test credential"), 0o600); err != nil {
		t.Fatal(err)
	}

	for _, args := range [][]string{
		{"grants", "revoke", "id"},
		{"connections", "drop", "id"},
		{"providers", "disconnect", "claude"},
	} {
		if err := dispatch(nil, args, false); err == nil {
			t.Errorf("%v did not require --yes", args)
		}
	}
	if _, err := os.Stat(credential); err != nil {
		t.Fatalf("provider credential changed without --yes: %v", err)
	}
}
