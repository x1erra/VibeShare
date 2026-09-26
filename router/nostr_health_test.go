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
	h, wait = applyPublishFailure(relayHealth{}, "msg: blocked: spam not permitted", now)
	if wait != 15*time.Minute || h.soft {
		t.Fatalf("spam refusal wait=%s soft=%t", wait, h.soft)
	}
	refused := relayCandidate{URL: "wss://refused", FailUntil: h.failUntil, Soft: h.soft}
	if got := pickRelayURLs(now, []relayCandidate{refused}, true, nil); len(got) != 0 {
		t.Fatalf("signal to refusing relay = %v, want skipped", got)
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
	}, false, nil)
	if len(got) != 1 || got[0] != "wss://b" {
		t.Fatalf("healthy = %v", got)
	}
	got = pickRelayURLs(now, []relayCandidate{
		{URL: "wss://a", FailUntil: now.Add(5 * time.Minute)},
		{URL: "wss://b", FailUntil: now.Add(time.Minute)},
	}, false, nil)
	if len(got) != 0 {
		t.Fatalf("all cooling down = %v, want no publishes", got)
	}
	if pickRelayURLs(now, nil, false, nil) != nil {
		t.Fatal("empty should be nil")
	}
}

func TestSlowRelayStillCarriesSignals(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	h := relayHealth{}
	for i := 0; i < 3; i++ {
		h, _ = applyPublishFailure(h, "context deadline exceeded", now)
	}
	if !h.soft || !h.failUntil.After(now) {
		t.Fatalf("three deadlines should soft-cool: %+v", h)
	}
	slow := relayCandidate{URL: "wss://slow", FailUntil: h.failUntil, Soft: h.soft}
	if got := pickRelayURLs(now, []relayCandidate{slow}, false, nil); len(got) != 0 {
		t.Fatalf("presence to slow relay = %v, want skipped", got)
	}
	// The friend's host may only be listening on this relay; an offer that
	// skips it can never be answered.
	if got := pickRelayURLs(now, []relayCandidate{slow}, true, nil); len(got) != 1 {
		t.Fatalf("signal to slow relay = %v, want sent", got)
	}
	banned := relayCandidate{URL: "wss://banned", FailUntil: now.Add(15 * time.Minute)}
	if got := pickRelayURLs(now, []relayCandidate{banned}, true, nil); len(got) != 0 {
		t.Fatalf("signal to banned relay = %v, want skipped", got)
	}
}

func TestDeadlinesDoNotShortenARefusal(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	h, _ := applyPublishFailure(relayHealth{}, "msg: banned: too many rate-limit violations", now)
	for i := 0; i < 3; i++ {
		h, _ = applyPublishFailure(h, "context deadline exceeded", now)
	}
	if h.soft || !h.failUntil.Equal(now.Add(15*time.Minute)) {
		t.Fatalf("ban was softened or shortened: %+v", h)
	}
}

func TestRateLimitedRelayGetsSampledPresence(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	h, _ := applyPublishFailure(relayHealth{}, "msg: rate-limited: you are noting too much", now)
	after := now.Add(3 * time.Minute) // cooldown over, still throttled
	if h.failUntil.After(after) || !h.throttledUntil.After(after) {
		t.Fatalf("health = %+v", h)
	}
	c := relayCandidate{URL: "wss://strict", FailUntil: h.failUntil, Throttled: h.throttledUntil}
	drop := func() bool { return false }
	if got := pickRelayURLs(after, []relayCandidate{c}, false, drop); len(got) != 0 {
		t.Fatalf("unsampled presence = %v, want skipped", got)
	}
	if got := pickRelayURLs(after, []relayCandidate{c}, true, drop); len(got) != 1 {
		t.Fatalf("signal = %v, want never sampled", got)
	}
	if got := pickRelayURLs(after.Add(throttleWindow), []relayCandidate{c}, false, drop); len(got) != 1 {
		t.Fatalf("presence after throttle window = %v, want sent", got)
	}
}
