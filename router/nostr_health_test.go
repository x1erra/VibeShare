package main

import (
	"testing"
	"time"
)

func TestApplyPublishFailure(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	h, wait := applyPublishFailure(relayHealth{}, "msg: banned: too many rate-limit violations", now)
	if wait != 15*time.Minute || !h.failUntil.Equal(now.Add(15*time.Minute)) {
		t.Fatalf("banned wait=%s until=%s", wait, h.failUntil)
	}
	h, wait = applyPublishFailure(relayHealth{}, "unexpected HTTP response status: 403", now)
	if wait != 15*time.Minute {
		t.Fatalf("403 wait=%s", wait)
	}
	h, wait = applyPublishFailure(relayHealth{}, "msg: rate-limited: you are noting too much", now)
	if wait != 2*time.Minute {
		t.Fatalf("rate-limit wait=%s", wait)
	}
	h = relayHealth{}
	if _, wait = applyPublishFailure(h, "context deadline exceeded", now); wait != 0 {
		t.Fatal("first deadline should not cool down")
	}
	h, _ = applyPublishFailure(h, "context deadline exceeded", now)
	h, _ = applyPublishFailure(h, "context deadline exceeded", now)
	h, wait = applyPublishFailure(h, "context deadline exceeded", now)
	if wait != 45*time.Second || h.deadlines != 0 {
		t.Fatalf("third deadline wait=%s deadlines=%d", wait, h.deadlines)
	}
}

func TestPickRelayURLs(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	got := pickRelayURLs(now, []relayCandidate{
		{URL: "wss://a", FailUntil: now.Add(time.Minute)},
		{URL: "wss://b"},
		{URL: "wss://c", FailUntil: now.Add(5 * time.Minute)},
	})
	if len(got) != 1 || got[0] != "wss://b" {
		t.Fatalf("healthy = %v", got)
	}
	got = pickRelayURLs(now, []relayCandidate{
		{URL: "wss://a", FailUntil: now.Add(5 * time.Minute)},
		{URL: "wss://b", FailUntil: now.Add(time.Minute)},
	})
	if len(got) != 0 {
		t.Fatalf("all cooling down = %v, want no publishes", got)
	}
	if pickRelayURLs(now, nil) != nil {
		t.Fatal("empty should be nil")
	}
}
