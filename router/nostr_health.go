package main

import (
	"strings"
	"time"
)

// relayCandidate is one connected relay considered for a publish.
type relayCandidate struct {
	URL       string
	FailUntil time.Time
}

// applyPublishFailure records a refused publish. A non-zero duration means this
// relay should be skipped until then. Ordinary single timeouts only count
// toward a cooldown so one slow relay does not silence the room.
func applyPublishFailure(h relayHealth, reason string, now time.Time) (relayHealth, time.Duration) {
	switch {
	case strings.Contains(reason, "banned"), strings.Contains(reason, "403"):
		h.deadlines = 0
		h.failUntil = now.Add(15 * time.Minute)
		return h, 15 * time.Minute
	case strings.Contains(reason, "rate-limited") || strings.Contains(reason, "rate limited"):
		h.deadlines = 0
		h.failUntil = now.Add(2 * time.Minute)
		return h, 2 * time.Minute
	case strings.Contains(reason, "deadline"):
		h.deadlines++
		if h.deadlines >= 3 {
			h.deadlines = 0
			h.failUntil = now.Add(45 * time.Second)
			return h, 45 * time.Second
		}
	}
	return h, 0
}

// pickRelayURLs returns relays that are allowed to accept a publish now.
// Sending to a banned relay during its cooldown only extends the ban and can
// keep this host unreachable. If all relays are cooling down, wait for one.
func pickRelayURLs(now time.Time, items []relayCandidate) []string {
	healthy := make([]string, 0, len(items))
	for _, it := range items {
		if it.URL == "" {
			continue
		}
		if !it.FailUntil.After(now) {
			healthy = append(healthy, it.URL)
			continue
		}
	}
	if len(healthy) == 0 {
		return nil
	}
	return healthy
}
