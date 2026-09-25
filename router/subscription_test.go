package main

import (
	"encoding/json"
	"testing"
)

func TestClaudeUsageIncludesEveryAvailableWindow(t *testing.T) {
	var raw map[string]json.RawMessage
	json.Unmarshal([]byte(`{
		"five_hour":{"utilization":11,"resets_at":"2026-09-25T10:00:00Z"},
		"seven_day":{"utilization":22,"resets_at":"2026-09-30T10:00:00Z"},
		"seven_day_fable":{"utilization":33,"resets_at":"2026-09-30T10:00:00Z"},
		"seven_day_opus":{"utilization":44,"resets_at":"2026-09-30T10:00:00Z"},
		"extra_usage":{"is_enabled":true,"monthly_limit":100},
		"unknown":null
	}`), &raw)
	windows := parseClaudeWindows(raw)
	if len(windows) != 4 {
		t.Fatalf("got %d windows: %+v", len(windows), windows)
	}
	for i, want := range []string{"Session (5h)", "Weekly", "Weekly · Fable", "Weekly · Opus"} {
		if windows[i].Label != want {
			t.Errorf("window %d = %q, want %q", i, windows[i].Label, want)
		}
	}
}

func TestSharedUsageOnlyIncludesGrantedProviders(t *testing.T) {
	snaps := map[string]ProviderUsage{
		"claude": {UpdatedAt: 1, Error: "private provider response", Windows: []UsageWindow{{Label: "Weekly", Utilization: 50}}},
		"codex":  {UpdatedAt: 1, Windows: []UsageWindow{{Label: "Weekly", Utilization: 75}}},
	}
	for _, tc := range []struct {
		grant Grant
		want  int
		key   string
	}{
		{Grant{}, 2, ""},
		{Grant{Providers: []string{"claude"}}, 1, "claude"},
		{Grant{Models: []string{"claude-fable-5"}}, 1, "claude"},
	} {
		got := sharedUsageForGrant(tc.grant, snaps)
		if len(got) != tc.want {
			t.Errorf("grant %+v got %+v", tc.grant, got)
		}
		if tc.key != "" {
			if _, ok := got[tc.key]; !ok {
				t.Errorf("missing %s", tc.key)
			}
		}
		if got["claude"].Error != "" {
			t.Error("provider error leaked to a shared grant")
		}
	}
}

func TestCodexUsagePrefersPerLimitWindows(t *testing.T) {
	var raw map[string]json.RawMessage
	json.Unmarshal([]byte(`{
		"rate_limit":{"primary_window":{"used_percent":10},"secondary_window":{"used_percent":20}},
		"rate_limits_by_limit_id":{
			"codex":{"rate_limit":{"primary_window":{"used_percent":10},"secondary_window":{"used_percent":20}}},
			"code_review":{"rate_limit":{"primary_window":{"used_percent":30}}}
		}
	}`), &raw)
	windows := parseCodexWindows(raw)
	if len(windows) != 3 {
		t.Fatalf("got %d windows: %+v", len(windows), windows)
	}
}
